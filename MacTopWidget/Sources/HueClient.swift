import Foundation

// MARK: - Philips Hue CLIP API v2 Client (local LAN, zero external dependencies)
// Uses /usr/bin/curl for local LAN HTTPS so macOS Local Network privacy does not block bare Swift binaries.

struct HueLight: Identifiable {
    let id: String               // light UUID
    let name: String
    var isOn: Bool
    var brightness: Double       // 0...100
    var supportsDimming: Bool
}

struct HueScene: Identifiable {
    let id: String
    let name: String
    let groupId: String
}

struct HueGroup: Identifiable {
    let id: String               // room/zone UUID
    let groupedLightId: String   // grouped_light UUID used for on/off + dimming
    let name: String
    let isRoom: Bool
    var isOn: Bool
    var brightness: Double       // 0...100
    var lights: [HueLight] = []
    var scenes: [HueScene] = []
}

final class HueClient {
    static let udBridgeHostKey = "hueBridgeHost"
    static let udAppKeyKey     = "hueAppKey"

    private let queue = DispatchQueue(label: "com.soren.mactop.hue", qos: .utility)

    var bridgeHost: String? {
        didSet {
            if let h = bridgeHost, !h.isEmpty {
                UserDefaults.standard.set(h, forKey: Self.udBridgeHostKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.udBridgeHostKey)
            }
        }
    }

    var appKey: String? {
        didSet {
            if let k = appKey, !k.isEmpty {
                UserDefaults.standard.set(k, forKey: Self.udAppKeyKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.udAppKeyKey)
            }
        }
    }

    private(set) var groups: [HueGroup] = []
    private(set) var isReachable: Bool = false
    private(set) var isPairing: Bool = false
    private(set) var statusMessage: String = ""

    var isConfigured: Bool {
        guard let h = bridgeHost, !h.isEmpty, let k = appKey, !k.isEmpty else { return false }
        return true
    }

    var onUpdate: (() -> Void)?
    private var pollTimer: Timer?
    private var lastDiscoverAttempt: TimeInterval = 0

    init() {
        self.bridgeHost = UserDefaults.standard.string(forKey: Self.udBridgeHostKey)
        self.appKey = UserDefaults.standard.string(forKey: Self.udAppKeyKey)
    }

    // MARK: - Shell helpers (curl + dns-sd)

    private func runProcess(_ path: String, args: [String], stdinData: Data? = nil, timeout: TimeInterval = 4.0) -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Drain stdout asynchronously so long-running commands like dns-sd return accumulated data on timeout
        var collected = Data()
        let lock = NSLock()
        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if !chunk.isEmpty {
                lock.lock()
                collected.append(chunk)
                lock.unlock()
            }
        }

        if let input = stdinData {
            let inPipe = Pipe()
            p.standardInput = inPipe
            do {
                try p.run()
                inPipe.fileHandleForWriting.write(input)
                try? inPipe.fileHandleForWriting.close()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                return (-1, Data())
            }
        } else {
            do { try p.run() } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                return (-1, Data())
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        var timedOut = false
        if p.isRunning {
            timedOut = true
            p.terminate()
            Thread.sleep(forTimeInterval: 0.08)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        let tail = outPipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        collected.append(tail)
        let result = collected
        lock.unlock()
        return (timedOut ? -2 : p.terminationStatus, result)
    }

    private func clipRequest(method: String = "GET", path: String, body: [String: Any]? = nil, includeKey: Bool = true) -> (ok: Bool, json: [String: Any]?) {
        guard let host = bridgeHost, !host.isEmpty else { return (false, nil) }
        var args = ["-sk", "--connect-timeout", "1.5", "--max-time", "3.0", "-X", method]
        if includeKey, let key = appKey, !key.isEmpty {
            args += ["-H", "hue-application-key: \(key)"]
        }
        var payload: Data? = nil
        if let body = body, let data = try? JSONSerialization.data(withJSONObject: body) {
            args += ["-H", "Content-Type: application/json", "--data-binary", "@-"]
            payload = data
        }
        args.append("https://\(host)\(path)")

        let (rc, data) = runProcess("/usr/bin/curl", args: args, stdinData: payload, timeout: 4.0)
        guard rc == 0, !data.isEmpty else { return (false, nil) }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (true, obj)
        }
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return (true, ["array": arr])
        }
        return (false, nil)
    }

    // MARK: - Discovery (mDNS _hue._tcp → .local hostname + IPv4)

    func discoverBridgeSync() -> String? {
        // 1. Browse _hue._tcp for 1.2s
        let (_, browseData) = runProcess("/usr/bin/dns-sd", args: ["-B", "_hue._tcp", "local."], timeout: 1.2)
        let browseStr = String(data: browseData, encoding: .utf8) ?? ""
        var instanceName: String?
        for line in browseStr.components(separatedBy: "\n") {
            if line.contains("Add") && line.contains("_hue._tcp.") {
                if let range = line.range(of: "_hue._tcp.") {
                    let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !tail.isEmpty { instanceName = tail; break }
                }
            }
        }
        guard let inst = instanceName else { return nil }

        // 2. Lookup target host
        let (_, lookupData) = runProcess("/usr/bin/dns-sd", args: ["-L", inst, "_hue._tcp", "local."], timeout: 1.2)
        let lookupStr = String(data: lookupData, encoding: .utf8) ?? ""
        guard let r1 = lookupStr.range(of: "can be reached at ") else { return nil }
        let rest = lookupStr[r1.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        var host = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
        if host.hasSuffix(".") { host.removeLast() }

        // 3. Prefer IPv4 address (faster than repeated mDNS lookups), fallback to .local hostname
        let (_, ipData) = runProcess("/usr/bin/dns-sd", args: ["-G", "v4", host], timeout: 1.2)
        let ipStr = String(data: ipData, encoding: .utf8) ?? ""
        for token in ipStr.components(separatedBy: .whitespacesAndNewlines) {
            let parts = token.split(separator: ".")
            if parts.count == 4, parts.allSatisfy({ Int($0) != nil }) {
                return token
            }
        }
        return host.isEmpty ? nil : host
    }

    // MARK: - Pairing (press Bridge link button within 30s)

    func startPairing(completion: @escaping (Bool, String) -> Void) {
        guard !isPairing else { return }
        isPairing = true
        statusMessage = "Suche Hue Bridge…"
        notifyUI()

        queue.async { [weak self] in
            guard let self = self else { return }
            let found = self.discoverBridgeSync() ?? self.bridgeHost
            guard let host = found, !host.isEmpty else {
                DispatchQueue.main.async {
                    self.isPairing = false
                    self.statusMessage = "Keine Hue Bridge im LAN gefunden"
                    self.notifyUI()
                    completion(false, self.statusMessage)
                }
                return
            }
            DispatchQueue.main.async {
                self.bridgeHost = host
                self.statusMessage = "Knopf auf der Hue Bridge drücken (30 s)…"
                self.notifyUI()
            }

            let deadline = Date().addingTimeInterval(30.0)
            while Date() < deadline && self.isPairing {
                let res = self.clipRequest(
                    method: "POST",
                    path: "/api",
                    body: ["devicetype": "mactop#macos", "generateclientkey": true],
                    includeKey: false
                )
                if let arr = res.json?["array"] as? [[String: Any]], let first = arr.first {
                    if let success = first["success"] as? [String: Any],
                       let username = success["username"] as? String, !username.isEmpty {
                        DispatchQueue.main.async {
                            self.appKey = username
                            self.isPairing = false
                            self.statusMessage = "Verbunden (\(host))"
                            self.notifyUI()
                            self.refreshNow()
                            completion(true, "Hue Bridge verbunden!")
                        }
                        return
                    }
                }
                Thread.sleep(forTimeInterval: 1.5)
            }

            DispatchQueue.main.async {
                self.isPairing = false
                self.statusMessage = "Zeitüberschreitung beim Koppeln"
                self.notifyUI()
                completion(false, "Bridge-Knopf wurde nicht innerhalb von 30 s gedrückt.")
            }
        }
    }

    func disconnect() {
        isPairing = false
        appKey = nil
        groups = []
        isReachable = false
        statusMessage = ""
        notifyUI()
    }

    // MARK: - Polling & Fetching Rooms / Zones / Scenes

    func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        t.tolerance = 1.5
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        refreshNow()
    }

    func refreshNow() {
        guard isConfigured else {
            if isReachable || !groups.isEmpty {
                DispatchQueue.main.async {
                    self.isReachable = false
                    self.groups = []
                    self.notifyUI()
                }
            }
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }

            // 1. Fetch rooms + zones + grouped_lights + scenes via CLIP v2
            let glRes = self.clipRequest(path: "/clip/v2/resource/grouped_light")
            if !glRes.ok {
                // Bridge IP might have changed via DHCP — retry discovery at most every 60s
                let now = CFAbsoluteTimeGetCurrent()
                if now - self.lastDiscoverAttempt > 60 {
                    self.lastDiscoverAttempt = now
                    if let newHost = self.discoverBridgeSync(), newHost != self.bridgeHost {
                        DispatchQueue.main.async { self.bridgeHost = newHost }
                    }
                }
                DispatchQueue.main.async {
                    if self.isReachable {
                        self.isReachable = false
                        self.notifyUI()
                    }
                }
                return
            }

            let roomRes  = self.clipRequest(path: "/clip/v2/resource/room")
            let zoneRes  = self.clipRequest(path: "/clip/v2/resource/zone")
            let lightRes = self.clipRequest(path: "/clip/v2/resource/light")
            let sceneRes = self.clipRequest(path: "/clip/v2/resource/scene")

            // Map grouped_light id -> (isOn, brightness)
            var glMap: [String: (Bool, Double)] = [:]
            if let glList = glRes.json?["data"] as? [[String: Any]] {
                for item in glList {
                    guard let id = item["id"] as? String else { continue }
                    let on = (item["on"] as? [String: Any])?["on"] as? Bool ?? false
                    let bri = (item["dimming"] as? [String: Any])?["brightness"] as? Double ?? (on ? 100.0 : 0.0)
                    glMap[id] = (on, bri)
                }
            }

            // Map light id & owner device id -> HueLight
            var lightById: [String: HueLight] = [:]
            var lightsByOwner: [String: [HueLight]] = [:]
            if let lList = lightRes.json?["data"] as? [[String: Any]] {
                for item in lList {
                    guard let lid = item["id"] as? String,
                          let meta = item["metadata"] as? [String: Any],
                          let rawName = meta["name"] as? String else { continue }
                    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let on = (item["on"] as? [String: Any])?["on"] as? Bool ?? false
                    let dimDict = item["dimming"] as? [String: Any]
                    let bri = dimDict?["brightness"] as? Double ?? (on ? 100.0 : 0.0)
                    let light = HueLight(id: lid, name: name, isOn: on, brightness: bri, supportsDimming: dimDict != nil)
                    lightById[lid] = light
                    if let owner = item["owner"] as? [String: Any], let oid = owner["rid"] as? String {
                        lightsByOwner[oid, default: []].append(light)
                    }
                }
            }

            // Map group id -> [HueScene]
            var sceneMap: [String: [HueScene]] = [:]
            if let sList = sceneRes.json?["data"] as? [[String: Any]] {
                for item in sList {
                    guard let sid = item["id"] as? String,
                          let meta = item["metadata"] as? [String: Any],
                          let name = meta["name"] as? String,
                          let grp = item["group"] as? [String: Any],
                          let gid = grp["rid"] as? String else { continue }
                    sceneMap[gid, default: []].append(HueScene(id: sid, name: name, groupId: gid))
                }
            }

            func parseGroupList(_ list: [[String: Any]]?, isRoom: Bool) -> [HueGroup] {
                guard let list = list else { return [] }
                var result: [HueGroup] = []
                for item in list {
                    guard let id = item["id"] as? String,
                          let meta = item["metadata"] as? [String: Any],
                          let rawName = meta["name"] as? String,
                          let services = item["services"] as? [[String: Any]] else { continue }
                    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let glSvc = services.first(where: { ($0["rtype"] as? String) == "grouped_light" }),
                          let glId = glSvc["rid"] as? String else { continue }
                    let state = glMap[glId] ?? (false, 0.0)
                    var scenes = sceneMap[id] ?? []
                    scenes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                    var groupLights: [HueLight] = []
                    if let children = item["children"] as? [[String: Any]] {
                        for ch in children {
                            guard let rtype = ch["rtype"] as? String, let rid = ch["rid"] as? String else { continue }
                            if rtype == "device", let ls = lightsByOwner[rid] {
                                groupLights.append(contentsOf: ls)
                            } else if rtype == "light", let l = lightById[rid] {
                                groupLights.append(l)
                            }
                        }
                    }
                    groupLights.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                    result.append(HueGroup(
                        id: id,
                        groupedLightId: glId,
                        name: name,
                        isRoom: isRoom,
                        isOn: state.0,
                        brightness: state.1,
                        lights: groupLights,
                        scenes: scenes
                    ))
                }
                result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return result
            }

            let rooms = parseGroupList(roomRes.json?["data"] as? [[String: Any]], isRoom: true)
            let roomNames = Set(rooms.map { $0.name.lowercased() })
            // Zonen nur hinzufügen, wenn sie nicht bereits 1:1 als gleichnamiger Raum existieren (z. B. doppelter "Flur")
            let zones = parseGroupList(zoneRes.json?["data"] as? [[String: Any]], isRoom: false)
                .filter { !roomNames.contains($0.name.lowercased()) }
            let combined = rooms + zones

            DispatchQueue.main.async {
                self.groups = combined
                self.isReachable = true
                self.notifyUI()
            }
        }
    }

    // MARK: - Controls (optimistic UI update + CLIP v2 PUT)

    func toggleGroup(_ groupId: String) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        let targetOn = !groups[idx].isOn
        let glId = groups[idx].groupedLightId
        groups[idx].isOn = targetOn
        if targetOn && groups[idx].brightness < 5 { groups[idx].brightness = 80 }
        notifyUI()

        queue.async { [weak self] in
            var body: [String: Any] = ["on": ["on": targetOn]]
            if targetOn { body["dynamics"] = ["duration": 200] }
            _ = self?.clipRequest(method: "PUT", path: "/clip/v2/resource/grouped_light/\(glId)", body: body)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refreshNow() }
        }
    }

    func setGroupBrightness(_ groupId: String, brightness: Double) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        let clamped = max(1, min(100, brightness))
        let glId = groups[idx].groupedLightId
        groups[idx].isOn = true
        groups[idx].brightness = clamped
        notifyUI()

        queue.async { [weak self] in
            let body: [String: Any] = [
                "on": ["on": true],
                "dimming": ["brightness": clamped],
                "dynamics": ["duration": 150]
            ]
            _ = self?.clipRequest(method: "PUT", path: "/clip/v2/resource/grouped_light/\(glId)", body: body)
        }
    }

    func adjustGroupBrightness(_ groupId: String, delta: Double) {
        guard let g = groups.first(where: { $0.id == groupId }) else { return }
        let base = g.isOn ? g.brightness : 0
        let next = base + delta
        if next <= 2 {
            setGroupOn(groupId, on: false)
        } else {
            setGroupBrightness(groupId, brightness: next)
        }
    }

    func setGroupOn(_ groupId: String, on: Bool) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        let glId = groups[idx].groupedLightId
        groups[idx].isOn = on
        notifyUI()

        queue.async { [weak self] in
            _ = self?.clipRequest(method: "PUT", path: "/clip/v2/resource/grouped_light/\(glId)", body: ["on": ["on": on]])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refreshNow() }
        }
    }

    func activateScene(_ sceneId: String, inGroup groupId: String) {
        if let idx = groups.firstIndex(where: { $0.id == groupId }) {
            groups[idx].isOn = true
            notifyUI()
        }
        queue.async { [weak self] in
            let body: [String: Any] = ["recall": ["action": "active"]]
            _ = self?.clipRequest(method: "PUT", path: "/clip/v2/resource/scene/\(sceneId)", body: body)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.refreshNow() }
        }
    }

    func toggleLight(_ lightId: String) {
        var targetOn = true
        for gi in groups.indices {
            if let li = groups[gi].lights.firstIndex(where: { $0.id == lightId }) {
                targetOn = !groups[gi].lights[li].isOn
                groups[gi].lights[li].isOn = targetOn
                if targetOn && groups[gi].lights[li].brightness < 5 {
                    groups[gi].lights[li].brightness = 80
                }
                groups[gi].isOn = groups[gi].lights.contains { $0.isOn }
            }
        }
        notifyUI()

        queue.async { [weak self] in
            var body: [String: Any] = ["on": ["on": targetOn]]
            if targetOn { body["dynamics"] = ["duration": 200] }
            _ = self?.clipRequest(method: "PUT", path: "/clip/v2/resource/light/\(lightId)", body: body)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refreshNow() }
        }
    }

    func setLightBrightness(_ lightId: String, brightness: Double) {
        let clamped = max(1, min(100, brightness))
        for gi in groups.indices {
            if let li = groups[gi].lights.firstIndex(where: { $0.id == lightId }) {
                groups[gi].lights[li].isOn = true
                groups[gi].lights[li].brightness = clamped
                groups[gi].isOn = true
            }
        }
        notifyUI()

        queue.async { [weak self] in
            let body: [String: Any] = [
                "on": ["on": true],
                "dimming": ["brightness": clamped],
                "dynamics": ["duration": 150]
            ]
            _ = self?.clipRequest(method: "PUT", path: "/clip/v2/resource/light/\(lightId)", body: body)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refreshNow() }
        }
    }

    func allLightsOff() {
        let targets = groups.filter { $0.isRoom }.map { $0.groupedLightId }
        for i in groups.indices { groups[i].isOn = false }
        notifyUI()

        queue.async { [weak self] in
            for glId in targets {
                _ = self?.clipRequest(method: "PUT", path: "/clip/v2/resource/grouped_light/\(glId)", body: ["on": ["on": false]])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.refreshNow() }
        }
    }

    func loadDemoGroupsForScreenshot() {
        groups = [
            HueGroup(id: "demo-1", groupedLightId: "gl-1", name: "Office", isRoom: true, isOn: true, brightness: 82,
                     lights: [HueLight(id: "l1", name: "Desk Lamp", isOn: true, brightness: 82, supportsDimming: true)]),
            HueGroup(id: "demo-2", groupedLightId: "gl-2", name: "Living Room", isRoom: true, isOn: true, brightness: 56,
                     lights: [
                        HueLight(id: "l2", name: "Floor Lamp", isOn: true, brightness: 60, supportsDimming: true),
                        HueLight(id: "l3", name: "Sofa Light", isOn: true, brightness: 52, supportsDimming: true)
                     ]),
            HueGroup(id: "demo-3", groupedLightId: "gl-3", name: "Studio", isRoom: true, isOn: true, brightness: 68,
                     lights: [HueLight(id: "l4", name: "Key Light", isOn: true, brightness: 68, supportsDimming: true)]),
            HueGroup(id: "demo-4", groupedLightId: "gl-4", name: "Kitchen", isRoom: true, isOn: false, brightness: 0,
                     lights: [
                        HueLight(id: "l5", name: "Counter", isOn: false, brightness: 0, supportsDimming: true),
                        HueLight(id: "l6", name: "Ceiling", isOn: false, brightness: 0, supportsDimming: true)
                     ]),
            HueGroup(id: "demo-5", groupedLightId: "gl-5", name: "Hallway", isRoom: true, isOn: true, brightness: 35,
                     lights: [HueLight(id: "l7", name: "Shelf", isOn: true, brightness: 35, supportsDimming: true)])
        ]
        isReachable = true
        isPairing = false
    }

    private func notifyUI() {
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?()
        }
    }
}
