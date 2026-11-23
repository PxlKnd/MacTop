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

        // Leichte EMA-Glättung gegen Flackern im 1s-Takt, bleibt aber reaktiv
        let alpha = 0.55
        var smoothed = [Double](repeating: 0, count: nCPU)
        for i in 0..<nCPU {
            smoothed[i] = lastPerCore.isEmpty ? perCore[i]
                : lastPerCore[i] * (1 - alpha) + perCore[i] * alpha
        }
        lastPerCore = smoothed
        let rawTotal = sumTot > 0 ? (sumBusy / sumTot * 100.0) : (smoothed.reduce(0, +) / Double(max(1, nCPU)))
        return (rawTotal, smoothed)
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
    private var nameCache: [Int32: String] = [:]
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
            rows.reserveCapacity(Int(count))
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

                let pct: Double
                if let p = prevCPU[pid], cpuNow >= p {
                    pct = Double(cpuNow - p) / (dt * 1e9) / ncpu * 100
                } else {
                    pct = 0
                }

                let memMB = Double(info.ri_phys_footprint) / 1_048_576
                let name: String
                if let cached = nameCache[pid] {
                    name = cached
                } else {
                    var nameBuf = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN + 1))
                    let len = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
                    let n = len > 0 ? String(cString: nameBuf) : "?"
                    name = n.isEmpty ? "?" : n
                    nameCache[pid] = name
                }
                rows.append(ProcRow(pid: pid, name: name, cpuPct: pct, memMB: memMB))
            }
        }
        if nameCache.count > 2048 {
            nameCache = nameCache.filter { curCPU[$0.key] != nil }
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

// MARK: - ANE (Apple Neural Engine via libIOReport — PMP residency + AF/DCS fabric bandwidth + Energy Model)

@_silgen_name("IOReportCopyChannelsInGroup")
private func IOReportCopyChannelsInGroup(_ group: CFString?, _ subgroup: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> Unmanaged<CFMutableDictionary>?

@_silgen_name("IOReportMergeChannels")
private func IOReportMergeChannels(_ a: CFMutableDictionary, _ b: CFDictionary, _ nilPtr: CFTypeRef?)

@_silgen_name("IOReportCreateSubscription")
private func IOReportCreateSubscription(_ a: UnsafeRawPointer?, _ desiredChannels: CFMutableDictionary, _ subbedChannels: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, _ channel_id: UInt64, _ nilPtr: CFTypeRef?) -> OpaquePointer?

@_silgen_name("IOReportCreateSamples")
private func IOReportCreateSamples(_ sub: OpaquePointer, _ subbedChannels: CFMutableDictionary, _ nilPtr: CFTypeRef?) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportCreateSamplesDelta")
private func IOReportCreateSamplesDelta(_ s1: CFDictionary, _ s2: CFDictionary, _ nilPtr: CFTypeRef?) -> Unmanaged<CFDictionary>?

@_silgen_name("IOReportChannelGetGroup")
private func IOReportChannelGetGroup(_ item: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportChannelGetSubGroup")
private func IOReportChannelGetSubGroup(_ item: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportChannelGetChannelName")
private func IOReportChannelGetChannelName(_ item: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportChannelGetUnitLabel")
private func IOReportChannelGetUnitLabel(_ item: CFDictionary) -> Unmanaged<CFString>?

@_silgen_name("IOReportSimpleGetIntegerValue")
private func IOReportSimpleGetIntegerValue(_ item: CFDictionary, _ idx: Int32) -> Int64

@_silgen_name("IOReportStateGetCount")
private func IOReportStateGetCount(_ item: CFDictionary) -> Int32

@_silgen_name("IOReportStateGetNameForIndex")
private func IOReportStateGetNameForIndex(_ item: CFDictionary, _ idx: Int32) -> Unmanaged<CFString>?

@_silgen_name("IOReportStateGetResidency")
private func IOReportStateGetResidency(_ item: CFDictionary, _ idx: Int32) -> Int64

struct ANEInfo {
    var available = false
    var coreCount = 16
    var activePct = 0.0
    var readGBs = 0.0
    var writeGBs = 0.0
    var combinedGBs = 0.0
    var powerW = 0.0
}

final class ANESampler {
    private var sub: OpaquePointer?
    private var subbed: CFMutableDictionary?
    private var prevSample: CFDictionary?
    private var prevTime: CFAbsoluteTime = 0
    let coreCount: Int

    init() {
        // ANE-Kernanzahl aus H11ANEIn DeviceProperties lesen (Fallback 16)
        var cores = 16
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("H11ANEIn"), &iter) == KERN_SUCCESS {
            defer { IOObjectRelease(iter) }
            let svc = IOIteratorNext(iter)
            if svc != 0 {
                var obj: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(svc, &obj, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let d = obj?.takeRetainedValue() as? [String: Any],
                   let dp = d["DeviceProperties"] as? [String: Any],
                   let n = (dp["ANEDevicePropertyNumANECores"] as? NSNumber)?.intValue, n > 0 {
                    cores = n
                }
                IOObjectRelease(svc)
            }
        }
        self.coreCount = cores

        // Gezielt nur die ANE-relevanten IOReport-Subgruppen abonnieren (extrem schlank)
        var merged: CFMutableDictionary?
        let wantedSubs: [(String, String?)] = [
            ("PMP", "SOC Floor"),
            ("PMP", "DCS Floor"),
            ("PMP", "Fast-Die CE"),
            ("PMP", "AF BW"),
            ("PMP", "DCS BW"),
            ("Energy Model", nil)
        ]
        for (grp, subgrp) in wantedSubs {
            guard let ch = IOReportCopyChannelsInGroup(grp as CFString, subgrp as CFString?, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let m = merged {
                IOReportMergeChannels(m, ch, nil)
            } else {
                merged = ch
            }
        }
        guard let desired = merged else { return }
        var outSubbed: Unmanaged<CFMutableDictionary>?
        if let s = IOReportCreateSubscription(nil, desired, &outSubbed, 0, nil),
           let sb = outSubbed?.takeRetainedValue() {
            self.sub = s
            self.subbed = sb
        }
    }

    private static func parseBucketGBs(_ rawName: String) -> Double? {
        let s = rawName.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: "GB/s") {
            return Double(s[..<r.lowerBound].trimmingCharacters(in: .whitespaces))
        }
        if let r = s.range(of: "MB/s"), let v = Double(s[..<r.lowerBound].trimmingCharacters(in: .whitespaces)) {
            return v / 1024.0
        }
        return nil
    }

    func sample() -> ANEInfo {
        guard let sub = sub, let subbed = subbed,
              let cur = IOReportCreateSamples(sub, subbed, nil)?.takeRetainedValue() else {
            return ANEInfo(coreCount: coreCount)
        }
        let now = CFAbsoluteTimeGetCurrent()
        defer {
            prevSample = cur
            prevTime = now
        }
        guard let prev = prevSample, now > prevTime else {
            return ANEInfo(available: true, coreCount: coreCount)
        }
        let dt = max(0.05, now - prevTime)
        guard let delta = IOReportCreateSamplesDelta(prev, cur, nil)?.takeRetainedValue() else {
            return ANEInfo(available: true, coreCount: coreCount)
        }
        let key = Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque()
        guard let rawArr = CFDictionaryGetValue(delta, key) else {
            return ANEInfo(available: true, coreCount: coreCount)
        }
        let arr = Unmanaged<CFArray>.fromOpaque(rawArr).takeUnretainedValue()
        let count = CFArrayGetCount(arr)

        var maxFloorActivePct = 0.0
        var directUtilPct: Double? = nil
        var powerWatts = 0.0

        var afReadEvents: Int64 = 0, afWriteEvents: Int64 = 0
        var afReadWeighted = 0.0, afWriteWeighted = 0.0
        var dcsReadEvents: Int64 = 0, dcsWriteEvents: Int64 = 0
        var dcsReadWeighted = 0.0, dcsWriteWeighted = 0.0

        for idx in 0..<count {
            guard let rawItem = CFArrayGetValueAtIndex(arr, idx) else { continue }
            let cf = Unmanaged<CFDictionary>.fromOpaque(rawItem).takeUnretainedValue()
            let grp = (IOReportChannelGetGroup(cf)?.takeUnretainedValue() as String?) ?? ""
            let subg = (IOReportChannelGetSubGroup(cf)?.takeUnretainedValue() as String?) ?? ""
            let name = (IOReportChannelGetChannelName(cf)?.takeUnretainedValue() as String?) ?? ""

            if grp == "Energy Model" && name == "ANE" {
                let rawVal = IOReportSimpleGetIntegerValue(cf, 0)
                if rawVal > 0 {
                    let unit = ((IOReportChannelGetUnitLabel(cf)?.takeUnretainedValue() as String?) ?? "").trimmingCharacters(in: .whitespaces)
                    let joules: Double
                    switch unit {
                    case "nJ": joules = Double(rawVal) * 1e-9
                    case "uJ", "µJ": joules = Double(rawVal) * 1e-6
                    default: joules = Double(rawVal) * 1e-3
                    }
                    powerWatts = joules / dt
                }
                continue
            }

            guard name.hasPrefix("ANE") else { continue }
            let nStates = IOReportStateGetCount(cf)
            guard nStates > 0 else { continue }

            if name == "ANE0" && (subg == "SOC Floor" || subg == "DCS Floor" || subg == "Fast-Die CE") {
                var tot: Int64 = 0, idle: Int64 = 0
                for i in 0..<nStates {
                    let r = IOReportStateGetResidency(cf, i)
                    tot &+= r
                    if r > 0 {
                        let sn = ((IOReportStateGetNameForIndex(cf, i)?.takeUnretainedValue() as String?) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
                        if sn == "OFF" || sn == "IDLE" || sn == "DOWN" || sn == "VMIN" || sn == "SLEEP" || sn == "0" {
                            idle &+= r
                        }
                    }
                }
                if tot > 0 {
                    directUtilPct = max(directUtilPct ?? 0, Double(max(0, tot - idle)) / Double(tot) * 100.0)
                }
            } else if subg == "SOC Floor" && name.hasPrefix("ANE-") {
                var tot: Int64 = 0, idle: Int64 = 0
                for i in 0..<nStates {
                    let r = IOReportStateGetResidency(cf, i)
                    tot &+= r
                    if r > 0 {
                        let sn = ((IOReportStateGetNameForIndex(cf, i)?.takeUnretainedValue() as String?) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
                        if sn == "VMIN" || sn == "OFF" || sn == "IDLE" || sn == "DOWN" || sn == "SLEEP" {
                            idle &+= r
                        }
                    }
                }
                if tot > 0 {
                    maxFloorActivePct = max(maxFloorActivePct, Double(max(0, tot - idle)) / Double(tot) * 100.0)
                }
            } else if (subg == "AF BW" || subg == "DCS BW") && (name.hasSuffix(" RD") || name.hasSuffix(" WR")) {
                var evTot: Int64 = 0
                var wSum = 0.0
                for i in 0..<nStates {
                    let r = IOReportStateGetResidency(cf, i)
                    if r > 0 {
                        evTot &+= r
                        let sn = (IOReportStateGetNameForIndex(cf, i)?.takeUnretainedValue() as String?) ?? ""
                        if let gbs = Self.parseBucketGBs(sn) {
                            wSum += gbs * Double(r)
                        }
                    }
                }
                if subg == "AF BW" {
                    if name.hasSuffix(" RD") { afReadEvents &+= evTot; afReadWeighted += wSum }
                    else { afWriteEvents &+= evTot; afWriteWeighted += wSum }
                } else {
                    if name.hasSuffix(" RD") { dcsReadEvents &+= evTot; dcsReadWeighted += wSum }
                    else { dcsWriteEvents &+= evTot; dcsWriteWeighted += wSum }
                }
            }
        }

        let util = min(100.0, directUtilPct ?? maxFloorActivePct)
        let quantumEvents = 8192.0 * dt
        var rd = 0.0, wr = 0.0
        // Nur Bandbreite ausgeben, wenn tatsächlich Transfers stattfanden (>10 Histogramm-Events oder ANE aktiv)
        let totalBwEvents = max(afReadEvents + afWriteEvents, dcsReadEvents + dcsWriteEvents)
        if util > 0.05 || Double(totalBwEvents) > 20.0 * dt {
            let afR = afReadWeighted / max(quantumEvents, Double(afReadEvents))
            let afW = afWriteWeighted / max(quantumEvents, Double(afWriteEvents))
            let dcsR = dcsReadWeighted / max(quantumEvents, Double(dcsReadEvents))
            let dcsW = dcsWriteWeighted / max(quantumEvents, Double(dcsWriteEvents))
            rd = max(afR, dcsR)
            wr = max(afW, dcsW)
        }

        return ANEInfo(
            available: true,
            coreCount: coreCount,
            activePct: util,
            readGBs: rd,
            writeGBs: wr,
            combinedGBs: rd + wr,
            powerW: powerWatts
        )
    }
}
