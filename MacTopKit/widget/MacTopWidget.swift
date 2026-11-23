import SwiftUI
import WidgetKit

struct CoreRow: Identifiable {
    let id: Int
    let pct: Double
    let isP: Bool
}

struct VolRow: Identifiable {
    let id: String
    let name: String
    let usedGB: Double
    let totalGB: Double
    let usedPct: Double
}

struct Snapshot {
    var cpuTotal = 0.0
    var pCoreCount = 12
    var eCoreCount = 4
    var cores: [CoreRow] = []

    var gpuDevice = 0.0
    var gpuRenderer = 0.0
    var gpuTiler = 0.0

    var memUsedPct = 0.0
    var memUsedGB = 0.0
    var memTotalGB = 128.0
    var memAppGB = 0.0
    var memWiredGB = 0.0
    var memCompressedGB = 0.0
    var swapUsedGB = 0.0

    var netDown = "0 B/s"
    var netUp = "0 B/s"

    var diskRead = "0 B/s"
    var diskWrite = "0 B/s"
    var volumes: [VolRow] = []
    var uptime = "0h 0m"

    static let sharedSampler = SystemSampler()

    static func sample(warmupDelay: TimeInterval = 0.5) -> Snapshot {
        if sharedSampler.needsWarmup {
            _ = sharedSampler.sampleAll()
            Thread.sleep(forTimeInterval: warmupDelay)
        }
        let s = sharedSampler.sampleAll()
        var snap = Snapshot()
        snap.cpuTotal = s.cpuTotal
        snap.pCoreCount = s.pCoreCount
        snap.eCoreCount = s.eCoreCount
        snap.cores = s.perCore.enumerated().map { i, v in
            CoreRow(id: i, pct: v, isP: i < s.pCoreCount)
        }
        snap.gpuDevice = s.gpuDevicePct
        snap.gpuRenderer = s.gpuRendererPct
        snap.gpuTiler = s.gpuTilerPct
        snap.memUsedPct = s.memUsedPct
        snap.memUsedGB = s.memUsedGB
        snap.memTotalGB = s.memTotalGB
        snap.memAppGB = s.memAppGB
        snap.memWiredGB = s.memWiredGB
        snap.memCompressedGB = s.memCompressedGB
        snap.swapUsedGB = s.swapUsedGB
        snap.netDown = fmtRate(s.downBps)
        snap.netUp = fmtRate(s.upBps)
        snap.diskRead = fmtRate(s.diskReadBps)
        snap.diskWrite = fmtRate(s.diskWriteBps)
        snap.volumes = s.volumes.prefix(3).map { v in
            let used = max(0, v.totalGB - v.freeGB)
            let pct = v.totalGB > 0 ? min(100, used / v.totalGB * 100) : 0
            return VolRow(id: v.name, name: v.name, usedGB: used, totalGB: v.totalGB, usedPct: pct)
        }
        snap.uptime = fmtUptime(s.uptime)
        return snap
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snap: Snapshot
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(
            date: .now,
            snap: Snapshot(
                cpuTotal: 14,
                pCoreCount: 12,
                eCoreCount: 4,
                cores: (0..<16).map { CoreRow(id: $0, pct: Double((($0 * 19) + 8) % 65), isP: $0 < 12) },
                gpuDevice: 64,
                gpuRenderer: 61,
                gpuTiler: 38,
                memUsedPct: 48,
                memUsedGB: 61.4,
                memTotalGB: 128,
                memAppGB: 44.2,
                memWiredGB: 14.1,
                memCompressedGB: 3.1,
                swapUsedGB: 0.0,
                netDown: "4.2 MB/s",
                netUp: "380 KB/s",
                diskRead: "18.4 MB/s",
                diskWrite: "2.1 MB/s",
                volumes: [
                    VolRow(id: "Macintosh HD", name: "Macintosh HD", usedGB: 1420, totalGB: 2000, usedPct: 71),
                    VolRow(id: "Data", name: "Data", usedGB: 840, totalGB: 2000, usedPct: 42)
                ],
                uptime: "3h 42m"
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        completion(Entry(date: .now, snap: Snapshot.sample()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date()
        let entry = Entry(date: now, snap: Snapshot.sample())
        let nextRefresh = now.addingTimeInterval(30)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

// MARK: - Farben (wie im HUD)

private func loadColor(_ p: Double) -> Color {
    if p < 50 { return Color(red: 0.30, green: 0.78, blue: 0.47) }
    if p < 80 { return Color(red: 0.96, green: 0.78, blue: 0.24) }
    return Color(red: 0.95, green: 0.36, blue: 0.36)
}

private func eColor(_ p: Double) -> Color {
    let t = max(0.18, min(1, p / 100))
    return Color(red: 0.25 * t, green: 0.55 * t + 0.15, blue: 0.98 * (0.4 + 0.6 * t))
}

private let cDown = Color(red: 0.36, green: 0.78, blue: 0.95)
private let cUp   = Color(red: 0.72, green: 0.55, blue: 1.00)
private let cApp  = Color(red: 0.36, green: 0.62, blue: 1.00)
private let cWire = Color(red: 0.72, green: 0.55, blue: 1.00)
private let cComp = Color(red: 0.95, green: 0.62, blue: 0.35)

// MARK: - Bausteine

struct ProgressBar: View {
    let pct: Double
    var height: CGFloat = 8
    var tint: Color? = nil

    var body: some View {
        let clamped = max(0, min(100, pct))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.primary.opacity(0.14))
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(tint ?? loadColor(clamped))
                    .frame(width: clamped > 0 ? max(3, geo.size.width * clamped / 100) : 0)
            }
        }
        .frame(height: height)
    }
}

struct CoreBar: View {
    let pct: Double
    let isP: Bool
    var height: CGFloat = 12
    var corner: CGFloat = 2

    var body: some View {
        let clamped = max(0, min(100, pct))
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: corner)
                    .fill(Color.primary.opacity(0.12))
                RoundedRectangle(cornerRadius: corner)
                    .fill(isP ? loadColor(clamped) : eColor(clamped))
                    .frame(height: max(2, geo.size.height * clamped / 100))
            }
        }
        .frame(height: height)
    }
}

struct SegmentedMemBar: View {
    let appGB: Double
    let wiredGB: Double
    let compGB: Double
    let totalGB: Double
    var height: CGFloat = 8

    var body: some View {
        let tot = max(totalGB, 1)
        GeometryReader { geo in
            let w = geo.size.width
            let appW = w * min(1, max(0, appGB / tot))
            let wirW = w * min(1, max(0, wiredGB / tot))
            let cmpW = w * min(1, max(0, compGB / tot))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.primary.opacity(0.14))
                HStack(spacing: 0) {
                    Rectangle().fill(cApp).frame(width: appW)
                    Rectangle().fill(cWire).frame(width: wirW)
                    Rectangle().fill(cComp).frame(width: cmpW)
                }
                .clipShape(RoundedRectangle(cornerRadius: height / 2))
            }
        }
        .frame(height: height)
    }
}

struct MonoText: View {
    let text: String
    var size: CGFloat = 10
    var weight: Font.Weight = .regular
    var color: Color = .primary

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

// MARK: - 1. Medium Layout (kompakt)

struct MediumWidgetView: View {
    let s: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    MonoText(text: "GPU", size: 11, weight: .bold, color: .secondary)
                    MonoText(text: String(format: "%.0f%%", s.gpuDevice), size: 18, weight: .bold, color: loadColor(s.gpuDevice))
                    Spacer(minLength: 4)
                    MonoText(text: String(format: "Ren %.0f%% · Til %.0f%%", s.gpuRenderer, s.gpuTiler),
                             size: 9.5, weight: .medium, color: .secondary)
                }
                ProgressBar(pct: s.gpuDevice, height: 10)
            }

            HStack(spacing: 6) {
                MonoText(text: "CPU", size: 10, weight: .bold, color: .secondary)
                MonoText(text: String(format: "%3.0f%%", s.cpuTotal), size: 12, weight: .bold, color: loadColor(s.cpuTotal))
                HStack(spacing: 2) {
                    ForEach(s.cores) { c in
                        CoreBar(pct: c.pct, isP: c.isP, height: 13)
                    }
                }
            }

            HStack(spacing: 6) {
                MonoText(text: "RAM", size: 10, weight: .bold, color: .secondary)
                SegmentedMemBar(appGB: s.memAppGB, wiredGB: s.memWiredGB, compGB: s.memCompressedGB, totalGB: s.memTotalGB, height: 7)
                MonoText(text: String(format: "%.0f/%.0fG (%.0f%%)", s.memUsedGB, s.memTotalGB, s.memUsedPct),
                         size: 9.5, weight: .semibold, color: loadColor(s.memUsedPct))
            }

            Divider().opacity(0.35)

            HStack(spacing: 6) {
                MonoText(text: "↓ \(s.netDown)", size: 10, weight: .semibold, color: cDown)
                MonoText(text: "↑ \(s.netUp)", size: 10, weight: .semibold, color: cUp)
                Spacer(minLength: 4)
                MonoText(text: "R \(s.diskRead) · W \(s.diskWrite)", size: 9.5, weight: .regular, color: .secondary)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - 2. Large Layout (quadratisch)

struct LargeWidgetView: View {
    let s: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MonoText(text: "● MACTOP", size: 11.5, weight: .bold, color: cApp)
                Spacer()
                MonoText(text: "UP \(s.uptime)", size: 10, color: .secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    MonoText(text: "GPU", size: 11.5, weight: .bold, color: .secondary)
                    MonoText(text: String(format: "%.0f%%", s.gpuDevice), size: 23, weight: .bold, color: loadColor(s.gpuDevice))
                    Spacer()
                    MonoText(text: "Device / Renderer / Tiler", size: 9.5, color: .secondary)
                }
                ProgressBar(pct: s.gpuDevice, height: 11)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        MonoText(text: String(format: "Renderer %3.0f%%", s.gpuRenderer), size: 10, color: .secondary)
                        ProgressBar(pct: s.gpuRenderer, height: 6)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        MonoText(text: String(format: "Tiler %3.0f%%", s.gpuTiler), size: 10, color: .secondary)
                        ProgressBar(pct: s.gpuTiler, height: 6)
                    }
                }
            }

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    MonoText(text: "CPU", size: 11, weight: .bold, color: .secondary)
                    MonoText(text: String(format: "%4.1f%%", s.cpuTotal), size: 14, weight: .bold, color: loadColor(s.cpuTotal))
                    Spacer()
                    MonoText(text: "P\(s.pCoreCount) / E\(s.eCoreCount)", size: 10, color: .secondary)
                }
                HStack(spacing: 2.5) {
                    ForEach(s.cores) { c in
                        CoreBar(pct: c.pct, isP: c.isP, height: 22)
                    }
                }
            }

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    MonoText(text: "RAM", size: 11, weight: .bold, color: .secondary)
                    MonoText(text: String(format: "%.1f / %.0f GB (%.0f%%)", s.memUsedGB, s.memTotalGB, s.memUsedPct),
                             size: 11.5, weight: .semibold, color: loadColor(s.memUsedPct))
                    Spacer()
                    MonoText(text: String(format: "Swap %.1fG", s.swapUsedGB), size: 10, color: .secondary)
                }
                SegmentedMemBar(appGB: s.memAppGB, wiredGB: s.memWiredGB, compGB: s.memCompressedGB, totalGB: s.memTotalGB, height: 9)
                MonoText(text: String(format: "App %.1fG  ·  Wired %.1fG  ·  Comp %.1fG", s.memAppGB, s.memWiredGB, s.memCompressedGB),
                         size: 9.5, color: .secondary)
            }

            Divider().opacity(0.35)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    MonoText(text: "NETZWERK", size: 10, weight: .bold, color: .secondary)
                    MonoText(text: "↓ \(s.netDown)", size: 11.5, weight: .semibold, color: cDown)
                    MonoText(text: "↑ \(s.netUp)", size: 11.5, weight: .semibold, color: cUp)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    MonoText(text: "DISK I/O", size: 10, weight: .bold, color: .secondary)
                    MonoText(text: "R \(s.diskRead)", size: 11.5, weight: .semibold, color: .primary)
                    MonoText(text: "W \(s.diskWrite)", size: 11.5, weight: .semibold, color: .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !s.volumes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(s.volumes.prefix(2)) { v in
                        HStack(spacing: 6) {
                            MonoText(text: v.name, size: 10, weight: .medium, color: .primary)
                                .frame(width: 58, alignment: .leading)
                            ProgressBar(pct: v.usedPct, height: 6)
                            MonoText(text: String(format: "%.0f%% (%.0fG frei)", v.usedPct, max(0, v.totalGB - v.usedGB)),
                                     size: 9.5, color: .secondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - 3. Extra Large Landscape (Breites Dashboard: GPU + CPU links | RAM, Netz, Disk, Volumes rechts — sehr große Schrift für 55")

struct ExtraLargeLandscapeView: View {
    let s: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Kompakter Header mit größerer Schrift
            HStack(alignment: .firstTextBaseline) {
                MonoText(text: "● MACTOP", size: 16.5, weight: .bold, color: cApp)
                Spacer()
                MonoText(text: "UP \(s.uptime)", size: 15, weight: .semibold, color: .secondary)
            }

            Divider().opacity(0.4)

            // Zweispaltiges Layout: Links GPU + CPU | Rechts Rest
            HStack(alignment: .top, spacing: 20) {
                // LINKE SPALTE: GPU + CPU
                VStack(alignment: .leading, spacing: 14) {
                    // GPU Block
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            MonoText(text: "GPU", size: 18, weight: .bold, color: .secondary)
                            MonoText(text: String(format: "%.0f%%", s.gpuDevice), size: 38, weight: .bold, color: loadColor(s.gpuDevice))
                            Spacer()
                        }
                        ProgressBar(pct: s.gpuDevice, height: 16)

                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    MonoText(text: "Ren", size: 14, weight: .medium, color: .secondary)
                                    Spacer()
                                    MonoText(text: String(format: "%.0f%%", s.gpuRenderer), size: 16, weight: .bold, color: loadColor(s.gpuRenderer))
                                }
                                ProgressBar(pct: s.gpuRenderer, height: 9)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    MonoText(text: "Til", size: 14, weight: .medium, color: .secondary)
                                    Spacer()
                                    MonoText(text: String(format: "%.0f%%", s.gpuTiler), size: 16, weight: .bold, color: loadColor(s.gpuTiler))
                                }
                                ProgressBar(pct: s.gpuTiler, height: 9)
                            }
                        }
                    }

                    Spacer(minLength: 2)
                    Divider().opacity(0.35)
                    Spacer(minLength: 2)

                    // CPU Block
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            MonoText(text: "CPU", size: 18, weight: .bold, color: .secondary)
                            MonoText(text: String(format: "%.1f%%", s.cpuTotal), size: 34, weight: .bold, color: loadColor(s.cpuTotal))
                            Spacer()
                            MonoText(text: "\(s.pCoreCount)P·\(s.eCoreCount)E", size: 14.5, weight: .semibold, color: .secondary)
                        }
                        HStack(spacing: 4) {
                            ForEach(s.cores) { c in
                                CoreBar(pct: c.pct, isP: c.isP, height: 42, corner: 3)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // Vertikale Trennlinie
                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 1.5)

                // RECHTE SPALTE: RAM, Netzwerk, Disk I/O, Volumes
                VStack(alignment: .leading, spacing: 11) {
                    // RAM Block
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            MonoText(text: "RAM", size: 17, weight: .bold, color: .secondary)
                            MonoText(text: String(format: "%.0f/%.0f GB", s.memUsedGB, s.memTotalGB),
                                     size: 17, weight: .bold, color: .primary)
                            Spacer()
                            MonoText(text: String(format: "%.0f%%", s.memUsedPct), size: 26, weight: .bold, color: loadColor(s.memUsedPct))
                        }
                        SegmentedMemBar(appGB: s.memAppGB, wiredGB: s.memWiredGB, compGB: s.memCompressedGB, totalGB: s.memTotalGB, height: 13)
                        HStack(spacing: 8) {
                            MonoText(text: String(format: "App %.0fG", s.memAppGB), size: 13.5, weight: .semibold, color: cApp)
                            MonoText(text: String(format: "Wir %.0fG", s.memWiredGB), size: 13.5, weight: .semibold, color: cWire)
                            MonoText(text: String(format: "Swp %.1fG", s.swapUsedGB), size: 13.5, weight: .medium, color: .secondary)
                        }
                    }

                    Divider().opacity(0.35)

                    // Netzwerk & Disk I/O
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            MonoText(text: "NETZ", size: 14, weight: .bold, color: .secondary)
                            MonoText(text: "↓ \(s.netDown)", size: 18.5, weight: .bold, color: cDown)
                            MonoText(text: "↑ \(s.netUp)", size: 18.5, weight: .bold, color: cUp)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            MonoText(text: "DISK", size: 14, weight: .bold, color: .secondary)
                            MonoText(text: "R \(s.diskRead)", size: 18.5, weight: .bold, color: .primary)
                            MonoText(text: "W \(s.diskWrite)", size: 18.5, weight: .bold, color: .secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Volumes
                    if !s.volumes.isEmpty {
                        Divider().opacity(0.35)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(s.volumes.prefix(2)) { v in
                                HStack(spacing: 8) {
                                    MonoText(text: v.name, size: 14.5, weight: .bold, color: .primary)
                                        .frame(width: 72, alignment: .leading)
                                    ProgressBar(pct: v.usedPct, height: 9)
                                    MonoText(text: String(format: "%.0fG frei", max(0, v.totalGB - v.usedGB)),
                                             size: 14, weight: .semibold, color: .secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - 4. Extra Large Portrait / Mega-Größe (4. Widget-Größe unter macOS 27: GPU + CPU links | Rest rechts, maximale Schriftgröße)

struct ExtraLargePortraitView: View {
    let s: Snapshot
    private var halfCoreCount: Int { max(1, (s.cores.count + 1) / 2) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Großer Header
            HStack(alignment: .firstTextBaseline) {
                MonoText(text: "● MACTOP XL", size: 20, weight: .bold, color: cApp)
                Spacer()
                MonoText(text: "UPTIME \(s.uptime)", size: 17, weight: .semibold, color: .secondary)
            }

            Divider().opacity(0.45)

            // Zweispaltig: GPU & CPU links | RAM, Netzwerk, Disk, Volumes rechts
            HStack(alignment: .top, spacing: 22) {
                // LINKE SPALTE: GPU + CPU (XL-Schrift)
                VStack(alignment: .leading, spacing: 20) {
                    // GPU Block
                    VStack(alignment: .leading, spacing: 10) {
                        MonoText(text: "GPU AUSLASTUNG", size: 16, weight: .bold, color: .secondary)
                        MonoText(text: String(format: "%.0f%%", s.gpuDevice), size: 48, weight: .bold, color: loadColor(s.gpuDevice))
                        ProgressBar(pct: s.gpuDevice, height: 20)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                MonoText(text: "Renderer", size: 16, weight: .medium, color: .secondary)
                                Spacer()
                                MonoText(text: String(format: "%.0f%%", s.gpuRenderer), size: 18, weight: .bold, color: loadColor(s.gpuRenderer))
                            }
                            ProgressBar(pct: s.gpuRenderer, height: 11)

                            HStack {
                                MonoText(text: "Tiler", size: 16, weight: .medium, color: .secondary)
                                Spacer()
                                MonoText(text: String(format: "%.0f%%", s.gpuTiler), size: 18, weight: .bold, color: loadColor(s.gpuTiler))
                            }
                            ProgressBar(pct: s.gpuTiler, height: 11)
                        }
                        .padding(.top, 4)
                    }

                    Divider().opacity(0.4)

                    // CPU Block (2 Reihen à 8 dicke Balken für beste Erkennbarkeit auf 55")
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            MonoText(text: "CPU", size: 18, weight: .bold, color: .secondary)
                            Spacer()
                            MonoText(text: "\(s.pCoreCount)P · \(s.eCoreCount)E", size: 15.5, weight: .semibold, color: .secondary)
                        }
                        MonoText(text: String(format: "%.1f%%", s.cpuTotal), size: 44, weight: .bold, color: loadColor(s.cpuTotal))

                        VStack(spacing: 6) {
                            HStack(spacing: 5) {
                                ForEach(Array(s.cores.prefix(halfCoreCount))) { c in
                                    CoreBar(pct: c.pct, isP: c.isP, height: 48, corner: 4)
                                }
                            }
                            if s.cores.count > halfCoreCount {
                                HStack(spacing: 5) {
                                    ForEach(Array(s.cores.dropFirst(halfCoreCount))) { c in
                                        CoreBar(pct: c.pct, isP: c.isP, height: 48, corner: 4)
                                    }
                                }
                            }
                        }

                        HStack {
                            MonoText(text: "■ P-Cores", size: 14, weight: .semibold, color: Color(red: 0.30, green: 0.78, blue: 0.47))
                            Spacer()
                            MonoText(text: "■ E-Cores", size: 14, weight: .semibold, color: Color(red: 0.40, green: 0.68, blue: 1.0))
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // Vertikale Trennlinie
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 2)

                // RECHTE SPALTE: RAM + Netzwerk + Disk I/O + Volumes (XL-Schrift)
                VStack(alignment: .leading, spacing: 18) {
                    // RAM Block
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            MonoText(text: "RAM", size: 18, weight: .bold, color: .secondary)
                            Spacer()
                            MonoText(text: String(format: "%.0f%%", s.memUsedPct), size: 36, weight: .bold, color: loadColor(s.memUsedPct))
                        }
                        MonoText(text: String(format: "%.1f / %.0f GB", s.memUsedGB, s.memTotalGB),
                                 size: 19, weight: .bold, color: .primary)
                        SegmentedMemBar(appGB: s.memAppGB, wiredGB: s.memWiredGB, compGB: s.memCompressedGB, totalGB: s.memTotalGB, height: 16)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                MonoText(text: String(format: "App %.1fG", s.memAppGB), size: 15, weight: .semibold, color: cApp)
                                Spacer()
                                MonoText(text: String(format: "Wired %.1fG", s.memWiredGB), size: 15, weight: .semibold, color: cWire)
                            }
                            HStack {
                                MonoText(text: String(format: "Comp %.1fG", s.memCompressedGB), size: 15, weight: .semibold, color: cComp)
                                Spacer()
                                MonoText(text: String(format: "Swap %.1fG", s.swapUsedGB), size: 15, weight: .medium, color: .secondary)
                            }
                        }
                    }

                    Divider().opacity(0.4)

                    // Netzwerk Block
                    VStack(alignment: .leading, spacing: 6) {
                        MonoText(text: "NETZWERK", size: 16, weight: .bold, color: .secondary)
                        MonoText(text: "↓ \(s.netDown)", size: 22, weight: .bold, color: cDown)
                        MonoText(text: "↑ \(s.netUp)", size: 22, weight: .bold, color: cUp)
                    }

                    Divider().opacity(0.4)

                    // Disk I/O Block
                    VStack(alignment: .leading, spacing: 6) {
                        MonoText(text: "DISK I/O", size: 16, weight: .bold, color: .secondary)
                        MonoText(text: "R \(s.diskRead)", size: 22, weight: .bold, color: .primary)
                        MonoText(text: "W \(s.diskWrite)", size: 22, weight: .bold, color: .secondary)
                    }

                    // Volumes Block
                    if !s.volumes.isEmpty {
                        Divider().opacity(0.4)
                        VStack(alignment: .leading, spacing: 10) {
                            MonoText(text: "LAUFWERKE", size: 16, weight: .bold, color: .secondary)
                            ForEach(s.volumes.prefix(3)) { v in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        MonoText(text: v.name, size: 16.5, weight: .bold, color: .primary)
                                        Spacer()
                                        MonoText(text: String(format: "%.0fG frei (%.0f%%)", max(0, v.totalGB - v.usedGB), v.usedPct),
                                                 size: 15.5, weight: .semibold, color: .secondary)
                                    }
                                    ProgressBar(pct: v.usedPct, height: 11)
                                }
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Root View & Widget Definition

struct MacTopWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        Group {
            switch family {
            case .systemExtraLargePortrait:
                ExtraLargePortraitView(s: entry.snap)
            case .systemExtraLarge:
                ExtraLargeLandscapeView(s: entry.snap)
            case .systemLarge:
                LargeWidgetView(s: entry.snap)
            default:
                MediumWidgetView(s: entry.snap)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct MacTopWidget: Widget {
    let kind = "MacTopWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            MacTopWidgetView(entry: entry)
        }
        .configurationDisplayName("MacTop Monitor")
        .description("GPU & CPU links, System-Infos rechts — in 4 Größen inkl. XXL für große Monitore.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge, .systemExtraLargePortrait])
    }
}

@main
struct MacTopWidgetBundle: WidgetBundle {
    var body: some Widget {
        MacTopWidget()
    }
}
