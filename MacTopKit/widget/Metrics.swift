import Foundation
import Darwin
import IOKit

// MARK: - Sysctl helpers

enum SysctlHelpers {
    static func sysctlInt(_ name: String) -> Int? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard name.withCString({ sysctlbyname($0, &v, &size, nil, 0) }) == 0 else { return nil }
        return Int(v)
    }

    static func hwNCPU() -> UInt32 {
        var v: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &v, &size, nil, 0)
        return UInt32(max(1, v))
    }
}

// MARK: - CPU (per core, via host_processor_info)

final class CPUSampler {
    private var prev: [processor_cpu_load_info_data_t] = []
    let pCoreCount: Int
    let eCoreCount: Int
    var lastPerCore: [Double] = []

    init() {
        var pcount = 0, ecount = 0
        if let c = SysctlHelpers.sysctlInt("hw.perflevel0.physicalcpu") { pcount = c }
        if let c = SysctlHelpers.sysctlInt("hw.perflevel1.physicalcpu") { ecount = c }
        let total = Int(SysctlHelpers.hwNCPU())
        if pcount + ecount != total { pcount = total; ecount = 0 }
        pCoreCount = pcount
        eCoreCount = ecount
    }

    func sample() -> (total: Double, perCore: [Double]) {
        var count = mach_msg_type_number_t(0)
        var infoType: integer_t = 0
        var info: processor_info_array_t?
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &infoType, &info, &count) == KERN_SUCCESS,
              let info = info else { return (lastPerCore.reduce(0, +) / Double(max(1, lastPerCore.count)), lastPerCore) }

        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        let nCPU = Int(count) / Int(CPU_STATE_MAX)
        var curSamples: [processor_cpu_load_info_data_t] = []
        curSamples.reserveCapacity(nCPU)
        for i in 0..<nCPU {
            let base = i * Int(CPU_STATE_MAX)
            let u = UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
            let s = UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
            let id = UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            let n = UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            curSamples.append(processor_cpu_load_info_data_t(cpu_ticks: (u, s, id, n)))
        }

        var perCore = [Double](repeating: 0, count: nCPU)
        var sumBusy = 0.0
        var sumTot = 0.0
        let havePrev = (prev.count == nCPU)
        if havePrev {
            for i in 0..<nCPU {
                let p = prev[i], cur = curSamples[i]
                let userD = Double(cur.cpu_ticks.0 &- p.cpu_ticks.0)
                let sysD  = Double(cur.cpu_ticks.1 &- p.cpu_ticks.1)
                let idleD = Double(cur.cpu_ticks.2 &- p.cpu_ticks.2)
                let niceD = Double(cur.cpu_ticks.3 &- p.cpu_ticks.3)
                let busy = userD + sysD + niceD
                let tot = busy + idleD
                sumBusy += busy
                sumTot += tot
                if tot > 0 { perCore[i] = busy / tot * 100 }
            }
        }
        prev = curSamples   // ersetzen, nicht anhängen (alter Bug: alternierende 0-Ticks)
        guard havePrev else {
            return (lastPerCore.reduce(0, +) / Double(max(1, lastPerCore.count)), lastPerCore)
        }

        // Im Widget (alle ~30s ein Sample) keine träge EMA-Verschleppung alter Peaks
        lastPerCore = perCore
        let total = sumTot > 0 ? (sumBusy / sumTot * 100.0) : (perCore.reduce(0, +) / Double(max(1, nCPU)))
        return (total, perCore)
    }
}

// MARK: - Memory

struct MemInfo {
    var appUsed = 0.0      // GB
    var wired = 0.0
    var compressed = 0.0
    var usedPct = 0.0      // Activity-Monitor-artig: (app+wired+compressed)/total
    var totalGB = 0.0
    var freeGB = 0.0       // physikalisch frei (inactive+speculative+free)
    var swapTotal = 0.0
    var swapUsed = 0.0
}

func sampleMemory() -> MemInfo {
    var m = MemInfo()
    m.totalGB = Double(SysctlHelpers.sysctlInt("hw.memsize") ?? 0) / 1_073_741_824

    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    if kr == KERN_SUCCESS {
        let pageSize = Double(vm_kernel_page_size)
        let G = 1_073_741_824.0
        let wired = Double(stats.wire_count) * pageSize / G
        let compressed = Double(stats.compressor_page_count) * pageSize / G
        let appUsed = Double(stats.internal_page_count) * pageSize / G
        let freePhys = (Double(stats.free_count) + Double(stats.inactive_count) + Double(stats.speculative_count)) * pageSize / G
        m.wired = wired
        m.compressed = compressed
        m.appUsed = max(0, appUsed)
        m.freeGB = freePhys
        let denom = appUsed + wired + compressed
        if denom > 0 && m.totalGB > 0 { m.usedPct = min(100, denom / m.totalGB * 100) }
    }

    var xsw = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 {
        m.swapTotal = Double(xsw.xsu_total) / 1_073_741_824
        m.swapUsed = Double(xsw.xsu_used) / 1_073_741_824
    }
    return m
}

// MARK: - Network (en*/bridge interfaces, like Activity Monitor default)

struct NetRates { var downBps = 0.0; var upBps = 0.0 }

final class NetSampler {
    private var prevIn: [String: UInt64] = [:]
    private var prevOut: [String: UInt64] = [:]
    private var prevTime = CFAbsoluteTimeGetCurrent()

    func sample() -> NetRates {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, ifaddrPtr != nil else { return NetRates() }
        defer { freeifaddrs(ifaddrPtr) }

        var curIn: [String: UInt64] = [:]
        var curOut: [String: UInt64] = [:]
        var ptr: UnsafeMutablePointer<ifaddrs>? = ifaddrPtr
        while let p = ptr {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: ifa.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    if let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                        curIn[name] = UInt64(data.pointee.ifi_ibytes)
                        curOut[name] = UInt64(data.pointee.ifi_obytes)
                    }
                }
            }
            ptr = ifa.ifa_next
        }

        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(0.2, now - prevTime)
        var rates = NetRates()
        for (k, v) in curIn {
            if let p = prevIn[k], v >= p { rates.downBps += Double(v - p) / dt }
        }
        for (k, v) in curOut {
            if let p = prevOut[k], v >= p { rates.upBps += Double(v - p) / dt }
        }
        prevIn = curIn
        prevOut = curOut
        prevTime = now
        return rates
    }
}

// MARK: - GPU (IOAccelerator PerformanceStatistics)

struct GPUInfo {
    var devicePct = 0.0
    var rendererPct = 0.0
    var tilerPct = 0.0
    var available = false
}

func sampleGPU() -> GPUInfo {
    var g = GPUInfo()
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return g }
    defer { IOObjectRelease(iter) }
    var svc = IOIteratorNext(iter)
    while svc != 0 {
        var obj: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(svc, &obj, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let d = obj?.takeRetainedValue() as? [String: Any],
           let ps = d["PerformanceStatistics"] as? [String: Any] {
            func num(_ key: String) -> Double? {
                (ps[key] as? NSNumber)?.doubleValue
            }
            if let dev = num("Device Utilization %") ?? num("gpu-core-utilization") {
                g.devicePct = min(100, max(0, dev))
                g.rendererPct = num("Renderer Utilization %") ?? 0
                g.tilerPct = num("Tiler Utilization %") ?? 0
                g.available = true
            }
        }
        IOObjectRelease(svc)
        svc = IOIteratorNext(iter)
    }
    return g
}

// MARK: - Disk (IOBlockStorageDriver I/O rates + volume capacity)

struct ThroughputRates { var readBps = 0.0; var writeBps = 0.0 }

final class DiskIOSampler {
    private var prevR = 0.0
    private var prevW = 0.0
    private var prevTime = CFAbsoluteTimeGetCurrent()

    func sample() -> ThroughputRates {
        var totalR = 0.0, totalW = 0.0
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS {
            defer { IOObjectRelease(iter) }
            var svc = IOIteratorNext(iter)
            while svc != 0 {
                var obj: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(svc, &obj, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let d = obj?.takeRetainedValue() as? [String: Any],
                   let stats = d["Statistics"] as? [String: Any] {
                    totalR += (stats["Bytes (Read)"] as? NSNumber)?.doubleValue ?? 0
                    totalW += (stats["Bytes (Write)"] as? NSNumber)?.doubleValue ?? 0
                }
                IOObjectRelease(svc)
                svc = IOIteratorNext(iter)
            }
        }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(0.2, now - prevTime)
        var rates = ThroughputRates()
        if prevR > 0, totalR >= prevR { rates.readBps = (totalR - prevR) / dt }
        if prevW > 0, totalW >= prevW { rates.writeBps = (totalW - prevW) / dt }
        prevR = totalR; prevW = totalW; prevTime = now
        return rates
    }
}

struct VolumeInfo { var name: String; var totalGB: Double; var freeGB: Double; var isInternal: Bool }

func sampleVolumes() -> [VolumeInfo] {
    var out: [VolumeInfo] = []
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                  .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey]
    if let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                           options: [.skipHiddenVolumes]) {
        for url in mounts {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)),
                  let name = rv.volumeName, let total = rv.volumeTotalCapacity else { continue }
            guard rv.volumeIsInternal ?? false else { continue }   // nur interne Volumes
            let free = Double(rv.volumeAvailableCapacityForImportantUsage ?? 0) / 1_073_741_824
            out.append(VolumeInfo(name: name, totalGB: Double(total) / 1_073_741_824,
                                  freeGB: free, isInternal: true))
        }
    }
    return out
}

// MARK: - Processes

struct ProcRow { var pid: Int32; var name: String; var cpuPct: Double; var memMB: Double }

final class ProcessSampler {
    private var prevCPU: [Int32: UInt64] = [:]
    private var prevTime = CFAbsoluteTimeGetCurrent()
    let ncpu = Double(SysctlHelpers.hwNCPU())

    func sample(top: Int) -> [ProcRow] {
        var curCPU: [Int32: UInt64] = [:]
        var rows: [ProcRow] = []
        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(0.2, now - prevTime)

        var count = proc_listallpids(nil, 0)
        if count > 0 {
            var pids = [pid_t](repeating: 0, count: Int(count))
            count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            for i in 0..<Int(count) {
                let pid = pids[i]
                if pid <= 0 { continue }

                var info = rusage_info_current()
                let rc: Int32 = withUnsafeMutablePointer(to: &info) { ptr in
                    ptr.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) { rebound in
                        proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
                    }
                }
                guard rc == 0 else { continue }
                let cpuNow = info.ri_user_time &+ info.ri_system_time
                curCPU[pid] = cpuNow

                var nameBuf = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN + 1))
                let len = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
                var name = len > 0 ? String(cString: nameBuf) : ""
                if name.isEmpty { name = "?" }

                let memBytes = Double(info.ri_phys_footprint)

                let pct: Double
                if let p = prevCPU[pid], cpuNow >= p {
                    pct = Double(cpuNow - p) / (dt * 1e9) / ncpu * 100
                } else {
                    pct = 0
                }
                rows.append(ProcRow(pid: pid, name: name, cpuPct: pct, memMB: memBytes / 1_048_576))
            }
        }
        prevCPU = curCPU
        prevTime = now
        return Array(rows.sorted { $0.cpuPct != $1.cpuPct ? $0.cpuPct > $1.cpuPct : $0.memMB > $1.memMB }.prefix(top))
    }
}

// MARK: - Uptime

func systemUptime() -> TimeInterval {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
    return max(0, Date().timeIntervalSince1970 - Double(tv.tv_sec))
}

// MARK: - Widget-Fassade (ein Sampler für alle Werte)

struct SystemStats {
    var cpuTotal = 0.0
    var perCore: [Double] = []
    var pCoreCount = 0
    var eCoreCount = 0
    var gpuAvailable = false
    var gpuDevicePct = 0.0
    var gpuRendererPct = 0.0
    var gpuTilerPct = 0.0
    var memUsedPct = 0.0
    var memUsedGB = 0.0
    var memTotalGB = 0.0
    var memAppGB = 0.0
    var memWiredGB = 0.0
    var memCompressedGB = 0.0
    var swapUsedGB = 0.0
    var downBps = 0.0
    var upBps = 0.0
    var diskReadBps = 0.0
    var diskWriteBps = 0.0
    var volumes: [VolumeInfo] = []
    var uptime: TimeInterval = 0
}

final class SystemSampler {
    private let cpu = CPUSampler()
    private let net = NetSampler()
    private let disk = DiskIOSampler()
    private(set) var needsWarmup = true

    func sampleAll() -> SystemStats {
        let c = cpu.sample()
        let m = sampleMemory()
        let g = sampleGPU()
        let n = net.sample()
        let d = disk.sample()
        let vols = sampleVolumes()
        let up = systemUptime()
        needsWarmup = false
        return SystemStats(
            cpuTotal: c.total,
            perCore: c.perCore,
            pCoreCount: cpu.pCoreCount,
            eCoreCount: cpu.eCoreCount,
            gpuAvailable: g.available,
            gpuDevicePct: g.available ? g.devicePct : 0,
            gpuRendererPct: g.available ? g.rendererPct : 0,
            gpuTilerPct: g.available ? g.tilerPct : 0,
            memUsedPct: m.usedPct,
            memUsedGB: m.appUsed + m.wired + m.compressed,
            memTotalGB: m.totalGB,
            memAppGB: m.appUsed,
            memWiredGB: m.wired,
            memCompressedGB: m.compressed,
            swapUsedGB: m.swapUsed,
            downBps: n.downBps,
            upBps: n.upBps,
            diskReadBps: d.readBps,
            diskWriteBps: d.writeBps,
            volumes: vols,
            uptime: up
        )
    }
}

func fmtRate(_ bps: Double) -> String {
    if bps < 1024 { return String(format: "%.0f B/s", bps) }
    if bps < 1_048_576 { return String(format: "%.0f KB/s", bps / 1024) }
    if bps < 1_073_741_824 { return String(format: "%.1f MB/s", bps / 1_048_576) }
    return String(format: "%.2f GB/s", bps / 1_073_741_824)
}

func fmtUptime(_ t: TimeInterval) -> String {
    let d = Int(t) / 86400, h = (Int(t) % 86400) / 3600, m = (Int(t) % 3600) / 60
    return d > 0 ? "\(d)d \(h)h \(m)m" : "\(h)h \(m)m"
}
