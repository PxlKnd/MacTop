import Cocoa

// MARK: - Formatting helpers

func fmtRate(_ bps: Double) -> String {
    if bps < 1024 { return String(format: "%.0f B/s", bps) }
    let kb = bps / 1024
    if kb < 1024 { return String(format: "%.0f KB/s", kb) }
    let mb = kb / 1024
    if mb < 1024 { return String(format: "%.1f MB/s", mb) }
    return String(format: "%.2f GB/s", mb / 1024)
}

func fmtUptime(_ t: TimeInterval) -> String {
    let d = Int(t) / 86400, h = (Int(t) % 86400) / 3600, m = (Int(t) % 3600) / 60
    return d > 0 ? "\(d)d \(h)h \(m)m" : "\(h)h \(m)m"
}

func eCoreColor(_ pct: Double) -> NSColor {
    let t = max(0.18, min(1, pct / 100))
    return NSColor(srgbRed: 0.25 * t, green: 0.55 * t + 0.15, blue: 0.98 * (0.4 + 0.6 * t), alpha: 1)
}

func loadColor(_ pct: Double) -> NSColor {
    if pct < 50 { return NSColor(srgbRed: 0.30, green: 0.78, blue: 0.47, alpha: 1) }
    if pct < 80 { return NSColor(srgbRed: 0.96, green: 0.78, blue: 0.24, alpha: 1) }
    return NSColor(srgbRed: 0.95, green: 0.36, blue: 0.36, alpha: 1)
}

let cText   = NSColor(srgbRed: 0.93, green: 0.95, blue: 0.98, alpha: 1)
let cDim    = NSColor(srgbRed: 0.60, green: 0.65, blue: 0.73, alpha: 1)
let cAccent = NSColor(srgbRed: 0.38, green: 0.64, blue: 1.00, alpha: 1)
let cDown   = NSColor(srgbRed: 0.36, green: 0.78, blue: 0.95, alpha: 1)
let cUp     = NSColor(srgbRed: 0.72, green: 0.55, blue: 1.00, alpha: 1)
let cApp    = NSColor(srgbRed: 0.36, green: 0.62, blue: 1.00, alpha: 1)
let cWire   = NSColor(srgbRed: 0.72, green: 0.55, blue: 1.00, alpha: 1)
let cComp   = NSColor(srgbRed: 0.95, green: 0.62, blue: 0.35, alpha: 1)
let cBarBg  = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
let cLine   = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.11)

// MARK: - Data model

final class SystemModel {
    let cpu = CPUSampler()
    let aneSampler = ANESampler()
    let net = NetSampler()
    let diskIO = DiskIOSampler()
    let procs = ProcessSampler()

    var cpuTotal = 0.0
    var perCore: [Double] = []
    var mem = MemInfo()
    var gpu = GPUInfo()
    var ane = ANEInfo()
    var netRates = NetRates()
    var diskRates = ThroughputRates()
    var volumes: [VolumeInfo] = []
    var topProcs: [ProcRow] = []
    var uptime: TimeInterval = 0

    var gpuHistory = [Double](repeating: 0, count: 60)
    var aneHistory = [Double](repeating: 0, count: 60)
    var downHistory = [Double](repeating: 0, count: 60)
    var upHistory = [Double](repeating: 0, count: 60)

    private var tickCount = 0

    func tick() {
        let s = cpu.sample()
        cpuTotal = s.total
        perCore = s.perCore
        mem = sampleMemory()
        gpu = sampleGPU()
        ane = aneSampler.sample()
        netRates = net.sample()
        diskRates = diskIO.sample()
        uptime = systemUptime()

        // Volumes & Prozessliste alle 3 Ticks aktualisieren → hält Eigenlast minimal (<0.5%)
        if tickCount % 3 == 0 {
            volumes = sampleVolumes()
            topProcs = procs.sample(top: 6)
        }
        tickCount &+= 1

        gpuHistory.removeFirst(); gpuHistory.append(gpu.available ? gpu.devicePct : 0)
        aneHistory.removeFirst(); aneHistory.append(ane.available ? ane.activePct : 0)
        downHistory.removeFirst(); downHistory.append(netRates.downBps)
        upHistory.removeFirst(); upHistory.append(netRates.upBps)
    }
}

// MARK: - Borderless Desktop Window

final class DesktopWidgetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Custom 2-Column Canvas View (GPU + CPU links | RAM, Netz, Disk, Volumes, Top-Procs rechts)

final class WidgetCanvasView: NSView {
    let model: SystemModel
    weak var controller: AppDelegate?

    // Base design dimensions (at scale = 1.0)
    static let baseWidth: CGFloat = 780
    static let baseHeight: CGFloat = 562

    var uiScale: CGFloat = 1.0

    init(model: SystemModel, scale: CGFloat) {
        self.model = model
        self.uiScale = scale
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: Self.baseWidth * scale,
                                 height: Self.baseHeight * scale))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Scaled helpers
    private func S(_ v: CGFloat) -> CGFloat { v * uiScale }

    private func attrs(_ size: CGFloat, _ color: NSColor, weight: NSFont.Weight = .regular) -> [NSAttributedString.Key: Any] {
        let f = NSFont.monospacedSystemFont(ofSize: S(size), weight: weight)
        return [.font: f, .foregroundColor: color]
    }

    private func drawText(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat,
                          color: NSColor = cText, weight: NSFont.Weight = .regular, maxWidth: CGFloat? = nil) {
        let a = attrs(size, color, weight: weight)
        if let mw = maxWidth {
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byTruncatingTail
            var a2 = a
            a2[.paragraphStyle] = p
            (s as NSString).draw(in: NSRect(x: S(x), y: S(y), width: S(mw), height: S(size * 1.4)), withAttributes: a2)
        } else {
            (s as NSString).draw(at: NSPoint(x: S(x), y: S(y)), withAttributes: a)
        }
    }

    private func drawTextRight(_ s: String, rightX: CGFloat, y: CGFloat, size: CGFloat,
                               color: NSColor = cText, weight: NSFont.Weight = .regular) {
        let a = attrs(size, color, weight: weight)
        let w = (s as NSString).size(withAttributes: a).width
        (s as NSString).draw(at: NSPoint(x: S(rightX) - w, y: S(y)), withAttributes: a)
    }

    private func hBar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, pct: Double, color: NSColor) {
        let rect = NSRect(x: S(x), y: S(y), width: S(w), height: S(h))
        let r = S(h / 2)
        let bg = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        cBarBg.setFill(); bg.fill()

        let clamped = max(0, min(100, pct))
        if clamped > 0 {
            let fw = max(S(4), rect.width * CGFloat(clamped / 100.0))
            let fg = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: min(rect.width, fw), height: rect.height),
                                  xRadius: r, yRadius: r)
            color.setFill(); fg.fill()
        }
    }

    private func vBar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, pct: Double, color: NSColor, radius: CGFloat = 3.5) {
        let rect = NSRect(x: S(x), y: S(y), width: S(w), height: S(h))
        let r = S(radius)
        let bg = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        cBarBg.setFill(); bg.fill()

        let clamped = max(0, min(100, pct))
        let fh = max(S(2.5), rect.height * CGFloat(clamped / 100.0))
        let fg = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.maxY - fh, width: rect.width, height: fh),
                              xRadius: r, yRadius: r)
        color.setFill(); fg.fill()
    }

    private func hLine(x1: CGFloat, x2: CGFloat, y: CGFloat) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: S(x1), y: S(y)))
        p.line(to: NSPoint(x: S(x2), y: S(y)))
        p.lineWidth = max(1, S(1))
        cLine.setStroke()
        p.stroke()
    }

    private func sparkline(_ history: [Double], x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                           minScale: Double, color: NSColor, fillAlpha: CGFloat = 0.16) {
        let rect = NSRect(x: S(x), y: S(y), width: S(w), height: S(h))
        let bg = NSBezierPath(roundedRect: rect, xRadius: S(5), yRadius: S(5))
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05).setFill()
        bg.fill()

        guard history.count > 1 else { return }
        let maxV = max(history.max() ?? minScale, minScale)

        let linePath = NSBezierPath()
        linePath.lineWidth = max(1.2, S(1.6))
        let fillPath = NSBezierPath()

        for (i, v) in history.enumerated() {
            let px = rect.minX + rect.width * CGFloat(i) / CGFloat(history.count - 1)
            let py = rect.maxY - (rect.height - S(4)) * min(1, CGFloat(v / maxV)) - S(2)
            let pt = NSPoint(x: px, y: py)
            if i == 0 {
                linePath.move(to: pt)
                fillPath.move(to: NSPoint(x: px, y: rect.maxY))
                fillPath.line(to: pt)
            } else {
                linePath.line(to: pt)
                fillPath.line(to: pt)
            }
        }
        fillPath.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        fillPath.close()

        NSGraphicsContext.saveGraphicsState()
        bg.addClip()
        color.withAlphaComponent(fillAlpha).setFill()
        fillPath.fill()
        color.setStroke()
        linePath.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func draw(_ dirtyRect: NSRect) {
        let W = Self.baseWidth
        let H = Self.baseHeight
        let pad: CGFloat = 22

        // Dezent abgedunkelter Rahmen über dem echten macOS Blur-Material für optimalen Kontrast
        let cardRadius = S(22)
        let fillPath = NSBezierPath(roundedRect: bounds, xRadius: cardRadius, yRadius: cardRadius)
        NSColor(srgbRed: 0.06, green: 0.075, blue: 0.10, alpha: 0.62).setFill()
        fillPath.fill()

        let strokeW = max(1, S(1))
        let strokeRect = bounds.insetBy(dx: strokeW / 2, dy: strokeW / 2)
        let strokePath = NSBezierPath(roundedRect: strokeRect, xRadius: cardRadius - strokeW / 2, yRadius: cardRadius - strokeW / 2)
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16).setStroke()
        strokePath.lineWidth = strokeW
        strokePath.stroke()

        // ── HEADER
        let headerY: CGFloat = 16
        drawText("● MACTOP LIVE", x: pad, y: headerY, size: 15.5, color: cAccent, weight: .bold)

        let modeTag = (controller?.pinnedToDesktop ?? true) ? "DESKTOP" : "FLOAT"
        let profileTag: String = {
            guard let ctrl = controller else { return "" }
            return ctrl.autoDisplayProfile ? (ctrl.activeProfile == .external ? " · AUTO:EXT" : " · AUTO:14\"") : ""
        }()
        drawTextRight("UP \(fmtUptime(model.uptime))   ·   \(modeTag)\(profileTag)   ·   Rechtsklick: Menü",
                      rightX: W - pad, y: headerY + 1.5, size: 12.5, color: cDim, weight: .medium)

        hLine(x1: pad, x2: W - pad, y: 44)

        // Spalten-Geometrie
        let colGap: CGFloat = 34
        let colW: CGFloat = (W - 2 * pad - colGap) / 2   // 351 pt
        let leftX: CGFloat = pad
        let leftRight: CGFloat = leftX + colW
        let divX: CGFloat = leftRight + colGap / 2
        let rightX: CGFloat = divX + colGap / 2
        let rightRight: CGFloat = W - pad

        // Vertikale Trennlinie
        let vLine = NSBezierPath()
        vLine.move(to: NSPoint(x: S(divX), y: S(54)))
        vLine.line(to: NSPoint(x: S(divX), y: S(H - 18)))
        vLine.lineWidth = max(1, S(1.2))
        cLine.setStroke()
        vLine.stroke()

        // ════════════════════════════════════════════════════════════════
        // LINKE SPALTE: GPU (oben) + ANE (Mitte) + CPU (unten, 2x8 Cores)
        // ════════════════════════════════════════════════════════════════
        var ly: CGFloat = 56

        // 1. GPU
        let gpuPct = model.gpu.available ? model.gpu.devicePct : 0
        drawText("GPU", x: leftX, y: ly + 10, size: 17, color: cDim, weight: .bold)
        drawText(String(format: "%.0f%%", gpuPct), x: leftX + 52, y: ly - 4, size: 40, color: loadColor(gpuPct), weight: .bold)

        // Live GPU-Sparkline oben rechts neben der großen Zahl
        sparkline(model.gpuHistory, x: leftX + 185, y: ly + 2, w: colW - 185, h: 38,
                  minScale: 100, color: loadColor(gpuPct), fillAlpha: 0.22)
        ly += 50

        hBar(x: leftX, y: ly, w: colW, h: 15, pct: gpuPct, color: loadColor(gpuPct))
        ly += 25

        // Renderer & Tiler nebeneinander
        let subW = (colW - 16) / 2
        let ren = model.gpu.rendererPct
        let til = model.gpu.tilerPct

        drawText("Renderer", x: leftX, y: ly, size: 13.5, color: cDim, weight: .medium)
        drawTextRight(String(format: "%.0f%%", ren), rightX: leftX + subW, y: ly - 1, size: 15, color: loadColor(ren), weight: .bold)
        hBar(x: leftX, y: ly + 20, w: subW, h: 8.5, pct: ren, color: loadColor(ren))

        let tilX = leftX + subW + 16
        drawText("Tiler", x: tilX, y: ly, size: 13.5, color: cDim, weight: .medium)
        drawTextRight(String(format: "%.0f%%", til), rightX: leftRight, y: ly - 1, size: 15, color: loadColor(til), weight: .bold)
        hBar(x: tilX, y: ly + 20, w: subW, h: 8.5, pct: til, color: loadColor(til))
        ly += 40

        hLine(x1: leftX, x2: leftRight, y: ly)
        ly += 14

        // 2. ANE (Apple Neural Engine — Auslastung %, Sparkline, Balken & Fabric-Bandbreite)
        let anePct = model.ane.available ? model.ane.activePct : 0
        let cANEIdle = NSColor(srgbRed: 0.28, green: 0.82, blue: 0.76, alpha: 1) // Türkis/Teal im Leerlauf, Ampel unter Last
        let aneCol = anePct >= 50 ? loadColor(anePct) : cANEIdle

        drawText("ANE", x: leftX, y: ly + 9, size: 17, color: cDim, weight: .bold)
        drawText(String(format: "%.0f%%", anePct), x: leftX + 52, y: ly - 4, size: 36, color: anePct > 0.4 ? loadColor(anePct) : cANEIdle, weight: .bold)
        sparkline(model.aneHistory, x: leftX + 185, y: ly + 1, w: colW - 185, h: 36,
                  minScale: 100, color: aneCol, fillAlpha: 0.22)
        ly += 46

        hBar(x: leftX, y: ly, w: colW, h: 13, pct: anePct, color: aneCol)
        ly += 20

        let aneLeftDetail = String(format: "%dC Neural · BW %.1f GB/s", model.ane.coreCount, model.ane.combinedGBs)
        let aneRightDetail = model.ane.powerW > 0.01
            ? String(format: "%.2f W · R %.1f / W %.1fG", model.ane.powerW, model.ane.readGBs, model.ane.writeGBs)
            : String(format: "R %.1f  ·  W %.1f GB/s", model.ane.readGBs, model.ane.writeGBs)
        drawText(aneLeftDetail, x: leftX, y: ly, size: 12.5, color: cDim, weight: .semibold)
        drawTextRight(aneRightDetail, rightX: leftRight, y: ly, size: 12.5,
                      color: model.ane.combinedGBs > 0.05 ? cText : cDim, weight: .medium)
        ly += 24

        hLine(x1: leftX, x2: leftRight, y: ly)
        ly += 14

        // 3. CPU
        drawText("CPU", x: leftX, y: ly + 10, size: 17, color: cDim, weight: .bold)
        drawText(String(format: "%.1f%%", model.cpuTotal), x: leftX + 52, y: ly - 4, size: 36, color: loadColor(model.cpuTotal), weight: .bold)
        drawTextRight("\(model.cpu.pCoreCount)P · \(model.cpu.eCoreCount)E", rightX: leftRight, y: ly + 11, size: 14, color: cDim, weight: .semibold)
        ly += 48

        // 16 Cores in 2 Reihen à 8 dicken vertikalen Balken
        let nCores = max(model.perCore.count, 16)
        let cols = 8
        let rows = (nCores + cols - 1) / cols
        let cGap: CGFloat = 7
        let barW = (colW - CGFloat(cols - 1) * cGap) / CGFloat(cols)
        let barH: CGFloat = 60

        for i in 0..<model.perCore.count {
            let r = i / cols
            let c = i % cols
            let bx = leftX + CGFloat(c) * (barW + cGap)
            let by = ly + CGFloat(r) * (barH + 9)
            let pct = model.perCore[i]
            let isE = model.cpu.eCoreCount > 0 && i >= model.cpu.pCoreCount
            vBar(x: bx, y: by, w: barW, h: barH, pct: pct, color: isE ? eCoreColor(pct) : loadColor(pct), radius: 4)
        }
        ly += CGFloat(rows) * (barH + 9) + 3

        drawText("■ P-Cores (Ampel)", x: leftX, y: ly, size: 12.5, color: loadColor(25), weight: .semibold)
        drawTextRight("■ E-Cores (Blau)", rightX: leftRight, y: ly, size: 12.5, color: NSColor(srgbRed: 0.42, green: 0.70, blue: 1.0, alpha: 1), weight: .semibold)

        // ════════════════════════════════════════════════════════════════
        // RECHTE SPALTE: RAM + NETZ/DISK + VOLUMES + LIVE TOP PROCESSES
        // ════════════════════════════════════════════════════════════════
        var ry: CGFloat = 56

        // 1. RAM
        let m = model.mem
        let memUsed = m.appUsed + m.wired + m.compressed
        drawText("RAM", x: rightX, y: ry + 4, size: 16.5, color: cDim, weight: .bold)
        drawText(String(format: "%.1f / %.0f GB", memUsed, m.totalGB), x: rightX + 52, y: ry + 3, size: 17.5, color: cText, weight: .bold)
        drawTextRight(String(format: "%.0f%%", m.usedPct), rightX: rightRight, y: ry - 4, size: 30, color: loadColor(m.usedPct), weight: .bold)
        ry += 34

        // Segmentierter RAM-Balken
        let segRect = NSRect(x: S(rightX), y: S(ry), width: S(colW), height: S(14))
        let segPath = NSBezierPath(roundedRect: segRect, xRadius: S(7), yRadius: S(7))
        cBarBg.setFill(); segPath.fill()
        let totM = max(m.totalGB, 1)
        NSGraphicsContext.saveGraphicsState()
        segPath.addClip()
        var sx = segRect.minX
        let appW = segRect.width * CGFloat(min(1, max(0, m.appUsed / totM)))
        let wirW = segRect.width * CGFloat(min(1, max(0, m.wired / totM)))
        let cmpW = segRect.width * CGFloat(min(1, max(0, m.compressed / totM)))
        cApp.setFill();  NSBezierPath(rect: NSRect(x: sx, y: segRect.minY, width: appW, height: segRect.height)).fill(); sx += appW
        cWire.setFill(); NSBezierPath(rect: NSRect(x: sx, y: segRect.minY, width: wirW, height: segRect.height)).fill(); sx += wirW
        cComp.setFill(); NSBezierPath(rect: NSRect(x: sx, y: segRect.minY, width: cmpW, height: segRect.height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        ry += 20

        drawText(String(format: "App %.1fG", m.appUsed), x: rightX, y: ry, size: 12.5, color: cApp, weight: .semibold)
        drawText(String(format: "Wired %.1fG", m.wired), x: rightX + 94, y: ry, size: 12.5, color: cWire, weight: .semibold)
        drawText(String(format: "Comp %.1fG", m.compressed), x: rightX + 198, y: ry, size: 12.5, color: cComp, weight: .semibold)
        drawTextRight(String(format: "Swap %.1fG", m.swapUsed), rightX: rightRight, y: ry, size: 12.5, color: cDim, weight: .medium)
        ry += 24

        hLine(x1: rightX, x2: rightRight, y: ry)
        ry += 12

        // 2. NETZWERK & DISK I/O nebeneinander + Live-Netzwerk-Sparkline
        let halfR = (colW - 16) / 2
        drawText("NETZWERK", x: rightX, y: ry, size: 12.5, color: cDim, weight: .bold)
        drawText("DISK I/O", x: rightX + halfR + 16, y: ry, size: 12.5, color: cDim, weight: .bold)
        ry += 18

        drawText("↓ " + fmtRate(model.netRates.downBps), x: rightX, y: ry, size: 17.5, color: cDown, weight: .bold)
        drawText("R " + fmtRate(model.diskRates.readBps), x: rightX + halfR + 16, y: ry, size: 17.5, color: cText, weight: .bold)
        ry += 23

        drawText("↑ " + fmtRate(model.netRates.upBps), x: rightX, y: ry, size: 17.5, color: cUp, weight: .bold)
        drawText("W " + fmtRate(model.diskRates.writeBps), x: rightX + halfR + 16, y: ry, size: 17.5, color: cDim, weight: .bold)
        ry += 25

        // Live Netzwerk-Sparkline (letzte 60 Sekunden)
        let netRect = NSRect(x: S(rightX), y: S(ry), width: S(colW), height: S(28))
        let netBg = NSBezierPath(roundedRect: netRect, xRadius: S(5), yRadius: S(5))
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05).setFill()
        netBg.fill()
        let netMax = max(max(model.downHistory.max() ?? 0, model.upHistory.max() ?? 0), 32 * 1024)
        for (hist, col) in [(model.downHistory, cDown), (model.upHistory, cUp)] {
            let p = NSBezierPath()
            p.lineWidth = max(1.2, S(1.5))
            for (i, v) in hist.enumerated() {
                let px = netRect.minX + netRect.width * CGFloat(i) / CGFloat(max(1, hist.count - 1))
                let py = netRect.maxY - (netRect.height - S(4)) * min(1, CGFloat(v / netMax)) - S(2)
                if i == 0 { p.move(to: NSPoint(x: px, y: py)) } else { p.line(to: NSPoint(x: px, y: py)) }
            }
            col.setStroke(); p.stroke()
        }
        ry += 38

        hLine(x1: rightX, x2: rightRight, y: ry)
        ry += 12

        // 3. LAUFWERKE (Volumes)
        for v in model.volumes.prefix(2) {
            let used = max(0, v.totalGB - v.freeGB)
            let pct = v.totalGB > 0 ? min(100, used / v.totalGB * 100) : 0
            drawText(v.name, x: rightX, y: ry, size: 14, color: cText, weight: .bold, maxWidth: 92)
            hBar(x: rightX + 94, y: ry + 4, w: colW - 208, h: 9, pct: pct, color: loadColor(pct))
            drawTextRight(String(format: "%.0fG frei (%.0f%%)", v.freeGB, pct),
                          rightX: rightRight, y: ry + 0.5, size: 13, color: cDim, weight: .semibold)
            ry += 23
        }
        ry += 5

        hLine(x1: rightX, x2: rightRight, y: ry)
        ry += 12

        // 4. TOP PROZESSE (Bonus gegenüber WidgetKit — live ohne Sandbox-Sperre!)
        drawText("TOP PROZESSE", x: rightX, y: ry, size: 12.5, color: cDim, weight: .bold)
        drawTextRight("CPU       RAM", rightX: rightRight, y: ry, size: 12, color: cDim, weight: .semibold)
        ry += 20

        for p in model.topProcs.prefix(6) {
            drawText(p.name, x: rightX, y: ry, size: 13.5, color: cText, weight: .medium, maxWidth: colW - 135)
            drawTextRight(String(format: "%5.1f%%", p.cpuPct), rightX: rightRight - 66, y: ry, size: 13.5,
                          color: loadColor(p.cpuPct), weight: .bold)
            let memStr = p.memMB >= 1024 ? String(format: "%.1fG", p.memMB / 1024) : String(format: "%.0fM", p.memMB)
            drawTextRight(memStr, rightX: rightRight, y: ry, size: 13, color: cDim, weight: .medium)
            ry += 21.5
        }
    }

    // MARK: - Dragging & Context Menu

    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        if !(controller?.positionLocked ?? false), let win = window {
            dragStartMouse = NSEvent.mouseLocation
            dragStartOrigin = win.frame.origin
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !(controller?.positionLocked ?? false),
              let win = window,
              let sm = dragStartMouse,
              let so = dragStartOrigin else { return }
        let cur = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(x: so.x + (cur.x - sm.x), y: so.y + (cur.y - sm.y)))
    }

    override func mouseUp(with event: NSEvent) {
        if dragStartOrigin != nil, let win = window {
            controller?.saveCurrentPosition(win.frame.origin)
        }
        dragStartMouse = nil
        dragStartOrigin = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let ctrl = controller else { return }
        let menu = NSMenu(title: "MacTop")

        // Automatische Monitor-Anpassung (55" vs. 14" MacBook)
        let autoTitle = ctrl.activeProfile == .external
            ? "Auto-Profil nach Monitor (aktiv: Extern / 55\")"
            : "Auto-Profil nach Monitor (aktiv: 14\" Laptop)"
        let autoItem = NSMenuItem(title: autoTitle, action: #selector(AppDelegate.toggleAutoDisplayProfile), keyEquivalent: "")
        autoItem.target = ctrl
        autoItem.state = ctrl.autoDisplayProfile ? .on : .off
        menu.addItem(autoItem)

        menu.addItem(.separator())

        // Skalierung / Schriftgröße (gilt bei aktivem Auto-Modus gezielt für den aktuellen Monitor-Typ!)
        let profileSuffix = ctrl.autoDisplayProfile
            ? (ctrl.activeProfile == .external ? " — für Extern / 55\"" : " — für 14\" Laptop")
            : ""
        let scaleHeader = NSMenuItem(title: "Größe / Schrift\(profileSuffix)", action: nil, keyEquivalent: "")
        scaleHeader.isEnabled = false
        menu.addItem(scaleHeader)

        let scales: [(String, CGFloat)] = [
            ("S · Kompakt (75 %)", 0.75),
            ("M · Laptop 14\" (85 %)", 0.85),
            ("L · Groß (100 %)", 1.00),
            ("XL · Extra Groß (115 %)", 1.15),
            ("XXL · 55\" Ultrawide (130 %)", 1.30),
            ("Mega XXL (145 %)", 1.45),
        ]
        for (label, sc) in scales {
            let item = NSMenuItem(title: label, action: #selector(AppDelegate.selectScale(_:)), keyEquivalent: "")
            item.target = ctrl
            item.representedObject = NSNumber(value: Double(sc))
            item.state = abs(uiScale - sc) < 0.03 ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Update-Intervall
        let rateHeader = NSMenuItem(title: "Aktualisierungsrate", action: nil, keyEquivalent: "")
        rateHeader.isEnabled = false
        menu.addItem(rateHeader)

        for (label, sec) in [("Schnell (0,5 s)", 0.5), ("Live Standard (1,0 s)", 1.0), ("Ruhig (2,0 s)", 2.0)] {
            let item = NSMenuItem(title: label, action: #selector(AppDelegate.selectInterval(_:)), keyEquivalent: "")
            item.target = ctrl
            item.representedObject = NSNumber(value: sec)
            item.state = abs(ctrl.refreshInterval - sec) < 0.05 ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let deskItem = NSMenuItem(title: "Fest auf Schreibtisch-Ebene (hinter Fenstern)", action: #selector(AppDelegate.toggleDesktopPin), keyEquivalent: "")
        deskItem.target = ctrl
        deskItem.state = ctrl.pinnedToDesktop ? .on : .off
        menu.addItem(deskItem)

        let lockItem = NSMenuItem(title: "Position sperren", action: #selector(AppDelegate.togglePositionLock), keyEquivalent: "")
        lockItem.target = ctrl
        lockItem.state = ctrl.positionLocked ? .on : .off
        menu.addItem(lockItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "MacTop beenden", action: #selector(AppDelegate.quitExplicitly), keyEquivalent: "q")
        quitItem.target = ctrl
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

// MARK: - App Controller

enum DisplayProfile: String {
    case external = "external"
    case laptop   = "laptop"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: DesktopWidgetWindow!
    var blurView: NSVisualEffectView!
    var canvas: WidgetCanvasView!
    let model = SystemModel()
    var timer: Timer?

    var autoDisplayProfile: Bool = true
    var activeProfile: DisplayProfile = .external
    var externalScale: CGFloat = 1.15   // XL für großen Monitor (55")
    var laptopScale: CGFloat = 0.85     // Passend proportioniert für 14" MacBook Solo
    var uiScale: CGFloat = 1.15

    var refreshInterval: TimeInterval = 1.0
    var pinnedToDesktop: Bool = true
    var positionLocked: Bool = false

    /// Erkennt, ob ein externer/großer Monitor angeschlossen ist (.external) oder nur das eingebaute MacBook-Display läuft (.laptop).
    static func detectDisplayProfile() -> (profile: DisplayProfile, targetScreen: NSScreen?) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return (.laptop, nil) }

        var externalCandidate: NSScreen?
        for s in screens {
            if let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let did = CGDirectDisplayID(num.uint32Value)
                if CGDisplayIsBuiltin(did) == 0 {
                    if let cur = externalCandidate {
                        if s.frame.width * s.frame.height > cur.frame.width * cur.frame.height {
                            externalCandidate = s
                        }
                    } else {
                        externalCandidate = s
                    }
                }
            } else if s.frame.width >= 2200 {
                externalCandidate = s
            }
        }
        if let ext = externalCandidate {
            return (.external, ext)
        }
        return (.laptop, NSScreen.main ?? screens.first)
    }

    private func posKey(for profile: DisplayProfile) -> String {
        profile == .external ? "desktopWidgetPos_external" : "desktopWidgetPos_laptop"
    }

    func saveCurrentPosition(_ origin: NSPoint) {
        let ud = UserDefaults.standard
        let dict: [String: CGFloat] = ["x": origin.x, "y": origin.y]
        ud.set(dict, forKey: posKey(for: activeProfile))
        ud.set(dict, forKey: "desktopWidgetPos")
    }

    private func resolvedOrigin(for size: NSSize, profile: DisplayProfile, preferredScreen: NSScreen?) -> NSPoint {
        let ud = UserDefaults.standard
        let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens.first

        let candidateDict = (ud.dictionary(forKey: posKey(for: profile)) as? [String: CGFloat])
            ?? (profile == .external ? (ud.dictionary(forKey: "desktopWidgetPos") as? [String: CGFloat]) : nil)

        if let pos = candidateDict, let x = pos["x"], let y = pos["y"] {
            let rect = NSRect(x: x, y: y, width: size.width, height: size.height)
            if let s = NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) }) {
                let vf = s.visibleFrame
                let cx = max(vf.minX + 8, min(x, vf.maxX - size.width - 8))
                let cy = max(vf.minY + 8, min(y, vf.maxY - size.height - 8))
                return NSPoint(x: cx, y: cy)
            }
        }

        if let s = screen {
            let vf = s.visibleFrame
            let margin: CGFloat = profile == .laptop ? 18 : 36
            let topMargin: CGFloat = profile == .laptop ? 16 : 28
            return NSPoint(
                x: max(vf.minX + 8, vf.maxX - size.width - margin),
                y: max(vf.minY + 8, vf.maxY - size.height - topMargin)
            )
        }
        return NSPoint(x: 40, y: 40)
    }

    static func roundedMaskImage(size: NSSize, radius: CGFloat) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    var screenshotPath: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--screenshot"), idx + 1 < args.count {
            screenshotPath = args[idx + 1]
        }

        // Einzelinstanz über PID-Lockdatei (im --screenshot-Modus überspringen)
        if screenshotPath == nil {
            let lockURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mactopwidget.lock")
            if let existing = try? String(contentsOf: lockURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(existing), pid != getpid(), kill(pid, 0) == 0 {
                NSApp.terminate(nil)
                return
            }
            try? String(getpid()).write(to: lockURL, atomically: true, encoding: .utf8)
        }

        let ud = UserDefaults.standard
        if let a = ud.object(forKey: "autoDisplayProfile") as? Bool { autoDisplayProfile = a }
        if let es = ud.object(forKey: "externalScale") as? Double, es >= 0.65, es <= 2.0 {
            externalScale = CGFloat(es)
        } else {
            externalScale = 1.15
            ud.set(Double(externalScale), forKey: "externalScale")
        }
        if let ls = ud.object(forKey: "laptopScale") as? Double, ls >= 0.65, ls <= 2.0 {
            laptopScale = CGFloat(ls)
        } else {
            laptopScale = 0.85
            ud.set(Double(laptopScale), forKey: "laptopScale")
        }
        if let r = ud.object(forKey: "refreshInterval") as? Double, r >= 0.25, r <= 10.0 { refreshInterval = r }
        if let p = ud.object(forKey: "pinnedToDesktop") as? Bool { pinnedToDesktop = p }
        if let l = ud.object(forKey: "positionLocked") as? Bool { positionLocked = l }

        if ud.dictionary(forKey: "desktopWidgetPos_external") == nil,
           let legacyPos = ud.dictionary(forKey: "desktopWidgetPos") {
            ud.set(legacyPos, forKey: "desktopWidgetPos_external")
        }

        let detected = Self.detectDisplayProfile()
        activeProfile = detected.profile
        if autoDisplayProfile {
            uiScale = (activeProfile == .external) ? externalScale : laptopScale
        } else if let s = ud.object(forKey: "uiScale") as? Double, s >= 0.65, s <= 2.0 {
            uiScale = CGFloat(s)
        }

        let size = NSSize(width: WidgetCanvasView.baseWidth * uiScale,
                          height: WidgetCanvasView.baseHeight * uiScale)

        window = DesktopWidgetWindow(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.borderless],
                                     backing: .buffered,
                                     defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        applyWindowLevel()

        let radius = 22 * uiScale
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true

        blurView = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.maskImage = Self.roundedMaskImage(size: size, radius: radius)
        blurView.autoresizingMask = [.width, .height]

        canvas = WidgetCanvasView(model: model, scale: uiScale)
        canvas.controller = self
        canvas.autoresizingMask = [.width, .height]

        container.addSubview(blurView)
        container.addSubview(canvas)
        window.contentView = container

        let initialOrigin = resolvedOrigin(for: size, profile: activeProfile, preferredScreen: detected.targetScreen)
        window.setFrameOrigin(initialOrigin)
        if let shotOut = screenshotPath {
            uiScale = 1.15
            canvas.uiScale = 1.15
            let shotSize = NSSize(width: WidgetCanvasView.baseWidth * uiScale, height: WidgetCanvasView.baseHeight * uiScale)
            window.setFrame(NSRect(origin: window.frame.origin, size: shotSize), display: false)
            blurView.frame = NSRect(origin: .zero, size: shotSize)
            blurView.maskImage = Self.roundedMaskImage(size: shotSize, radius: 22 * uiScale)
            canvas.frame = NSRect(origin: .zero, size: shotSize)

            // 8 Ticks à 0,3 s sammeln, damit Sparklines und echte Live-Deltas sichtbar sind
            var step = 0
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                self.model.tick()
                step += 1
                if step >= 8 {
                    t.invalidate()
                    // Neutrale Laufwerksnamen für saubere Repo-Screenshots
                    for i in self.model.volumes.indices {
                        self.model.volumes[i].name = (i == 0) ? "Macintosh HD" : "Vault SSD \(i)"
                    }
                    self.exportPNG(to: shotOut)
                    NSApp.terminate(nil)
                }
            }
            return
        }

        window.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        model.tick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.model.tick()
            self?.canvas.needsDisplay = true
        }
        startTimer()
    }

    private func exportPNG(to path: String) {
        let scaleFactor: CGFloat = 2.0 // Retina 2x
        let bounds = canvas.bounds
        let pxW = Int(bounds.width * scaleFactor)
        let pxH = Int(bounds.height * scaleFactor)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW,
            pixelsHigh: pxH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            // Dunkler Glas-Basisgrund für den transparenten PNG-Export
            let rad = 22 * uiScale
            let bgPath = NSBezierPath(roundedRect: bounds, xRadius: rad, yRadius: rad)
            NSColor(srgbRed: 0.08, green: 0.10, blue: 0.14, alpha: 0.94).setFill()
            bgPath.fill()
            canvas.displayIgnoringOpacity(bounds, in: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()

        if let png = rep.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: url)
        }
    }

    @objc func screensDidChange(_ notification: Notification) {
        let detected = Self.detectDisplayProfile()
        activeProfile = detected.profile
        let targetScale: CGFloat
        if autoDisplayProfile {
            targetScale = (activeProfile == .external) ? externalScale : laptopScale
        } else {
            targetScale = uiScale
        }

        let newSize = NSSize(width: WidgetCanvasView.baseWidth * targetScale,
                             height: WidgetCanvasView.baseHeight * targetScale)
        let newOrigin = resolvedOrigin(for: newSize, profile: activeProfile, preferredScreen: detected.targetScreen)

        uiScale = targetScale
        canvas.uiScale = targetScale
        window.setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: false)
        blurView.frame = NSRect(origin: .zero, size: newSize)
        blurView.maskImage = Self.roundedMaskImage(size: newSize, radius: 22 * targetScale)
        canvas.frame = NSRect(origin: .zero, size: newSize)
        canvas.needsDisplay = true
        window.invalidateShadow()
    }

    func applyWindowLevel() {
        if pinnedToDesktop {
            // Exakt über den Schreibtisch-Icons, aber hinter jedem normalen App-Fenster;
            // bleibt bei Mission Control / Exposé / Spaces-Wechsel fest auf dem Desktop.
            let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
            window.level = NSWindow.Level(rawValue: desktopLevel)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        } else {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }
    }

    func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.model.tick()
            self.canvas.needsDisplay = true
        }
        t.tolerance = refreshInterval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func applyScale(_ newScale: CGFloat, keepTopRightAnchor: Bool) {
        let oldFrame = window.frame
        let newSize = NSSize(width: WidgetCanvasView.baseWidth * newScale,
                             height: WidgetCanvasView.baseHeight * newScale)
        var newOrigin: NSPoint
        if keepTopRightAnchor {
            newOrigin = NSPoint(x: oldFrame.maxX - newSize.width, y: oldFrame.maxY - newSize.height)
            if let screen = window.screen ?? NSScreen.main {
                let vf = screen.visibleFrame
                newOrigin.x = max(vf.minX + 8, min(newOrigin.x, vf.maxX - newSize.width - 8))
                newOrigin.y = max(vf.minY + 8, min(newOrigin.y, vf.maxY - newSize.height - 8))
            }
        } else {
            let detected = Self.detectDisplayProfile()
            newOrigin = resolvedOrigin(for: newSize, profile: activeProfile, preferredScreen: detected.targetScreen)
        }

        uiScale = newScale
        canvas.uiScale = newScale
        window.setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: true)
        blurView.frame = NSRect(origin: .zero, size: newSize)
        blurView.maskImage = Self.roundedMaskImage(size: newSize, radius: 22 * newScale)
        canvas.frame = NSRect(origin: .zero, size: newSize)
        canvas.needsDisplay = true
        window.invalidateShadow()
        saveCurrentPosition(newOrigin)
    }

    @objc func toggleAutoDisplayProfile() {
        autoDisplayProfile.toggle()
        UserDefaults.standard.set(autoDisplayProfile, forKey: "autoDisplayProfile")
        if autoDisplayProfile {
            let detected = Self.detectDisplayProfile()
            activeProfile = detected.profile
            let target = (activeProfile == .external) ? externalScale : laptopScale
            applyScale(target, keepTopRightAnchor: false)
        } else {
            canvas.needsDisplay = true
        }
    }

    @objc func selectScale(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        let newScale = CGFloat(num.doubleValue)
        let ud = UserDefaults.standard
        if autoDisplayProfile {
            if activeProfile == .external {
                externalScale = newScale
                ud.set(Double(newScale), forKey: "externalScale")
            } else {
                laptopScale = newScale
                ud.set(Double(newScale), forKey: "laptopScale")
            }
        }
        ud.set(Double(newScale), forKey: "uiScale")
        applyScale(newScale, keepTopRightAnchor: true)
    }

    @objc func selectInterval(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        refreshInterval = num.doubleValue
        UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
        startTimer()
    }

    @objc func toggleDesktopPin() {
        pinnedToDesktop.toggle()
        UserDefaults.standard.set(pinnedToDesktop, forKey: "pinnedToDesktop")
        applyWindowLevel()
        window.orderFrontRegardless()
        canvas.needsDisplay = true
    }

    @objc func togglePositionLock() {
        positionLocked.toggle()
        UserDefaults.standard.set(positionLocked, forKey: "positionLocked")
    }

    @objc func quitExplicitly() {
        NSApp.terminate(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // Kein Dock-Icon, keine Menüleiste
let delegate = AppDelegate()
app.delegate = delegate
app.run()
