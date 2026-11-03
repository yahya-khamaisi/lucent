import Foundation

enum TVAction { case volumeUp, volumeDown, mute, powerOff, powerOn, input(String) }

/// Network control of TVs and AV receivers. Discovery is SSDP; control is each maker's
/// local API (LG webOS SSAP, Samsung Tizen remote, Philips JointSpace, Yamaha YXC).
@MainActor
final class TVs: ObservableObject {
    static let shared = TVs()
    @Published private(set) var scanning = false
    @Published private(set) var found: [TVDevice] = []
    @Published var status: [UUID: String] = [:]

    private var sockets: [UUID: TVSocket] = [:]

    // MARK: Discovery

    func scan() {
        guard !scanning else { return }
        scanning = true
        found = []
        Task.detached {
            let hits = SSDP.search(timeout: 3)
            var devices: [TVDevice] = []
            for hit in hits {
                guard let kind = await SSDP.classify(hit) else { continue }
                devices.append(TVDevice(kind: kind.0, name: kind.1, host: hit.host))
            }
            let unique = Dictionary(devices.map { ("\($0.kind.rawValue)-\($0.host)", $0) }, uniquingKeysWith: { a, _ in a }).values
            await MainActor.run {
                let known = Set(AppModel.shared.config.tvs.map(\.host))
                self.found = unique.filter { !known.contains($0.host) }.sorted { $0.name < $1.name }
                self.scanning = false
            }
        }
    }

    func add(_ device: TVDevice) {
        AppModel.shared.config.tvs.append(device)
        found.removeAll { $0.host == device.host }
    }

    func remove(_ device: TVDevice) {
        AppModel.shared.config.tvs.removeAll { $0.id == device.id }
        sockets.removeValue(forKey: device.id)
    }

    // MARK: Control

    func send(_ action: TVAction, to device: TVDevice) {
        switch device.kind {
        case .yamaha: yamaha(action, device)
        case .philips: philips(action, device)
        case .lg: lg(action, device)
        case .samsung: samsung(action, device)
        }
    }

    private func get(_ url: String) {
        guard let u = URL(string: url) else { return }
        URLSession.shared.dataTask(with: u).resume()
    }

    private func yamaha(_ a: TVAction, _ d: TVDevice) {
        let base = "http://\(d.host)/YamahaExtendedControl/v1/main/"
        switch a {
        case .volumeUp: get(base + "setVolume?volume=up&step=2")
        case .volumeDown: get(base + "setVolume?volume=down&step=2")
        case .mute: get(base + "setMute?enable=true")
        case .powerOff: get(base + "setPower?power=standby")
        case .powerOn: get(base + "setPower?power=on")
        case .input(let i): get(base + "setInput?input=\(i.lowercased())")
        }
    }

    private func philips(_ a: TVAction, _ d: TVDevice) {
        let key: String
        switch a {
        case .volumeUp: key = "VolumeUp"
        case .volumeDown: key = "VolumeDown"
        case .mute: key = "Mute"
        case .powerOff, .powerOn: key = "Standby"
        case .input: key = "Source"
        }
        guard let url = URL(string: "http://\(d.host):1925/1/input/key") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["key": key])
        URLSession.shared.dataTask(with: request).resume()
    }

    private func lg(_ a: TVAction, _ d: TVDevice) {
        let uri: String
        var payload: [String: Any] = [:]
        switch a {
        case .volumeUp: uri = "ssap://audio/volumeUp"
        case .volumeDown: uri = "ssap://audio/volumeDown"
        case .mute: uri = "ssap://audio/setMute"; payload = ["mute": true]
        case .powerOff: uri = "ssap://system/turnOff"
        case .powerOn: return   // needs Wake-on-LAN; the TV's network is off when it is
        case .input(let i): uri = "ssap://tv/switchInput"; payload = ["inputId": i.uppercased().replacingOccurrences(of: "HDMI", with: "HDMI_")]
        }
        socket(for: d).send(["type": "request", "id": UUID().uuidString, "uri": uri, "payload": payload])
    }

    private func samsung(_ a: TVAction, _ d: TVDevice) {
        let key: String
        switch a {
        case .volumeUp: key = "KEY_VOLUP"
        case .volumeDown: key = "KEY_VOLDOWN"
        case .mute: key = "KEY_MUTE"
        case .powerOff, .powerOn: key = "KEY_POWER"
        case .input(let i): key = i.lowercased().hasPrefix("hdmi") ? "KEY_HDMI" : "KEY_SOURCE"
        }
        socket(for: d).send(["method": "ms.remote.control",
                             "params": ["Cmd": "Click", "DataOfCmd": key, "Option": "false", "TypeOfRemote": "SendRemoteKey"]])
    }

    private func socket(for d: TVDevice) -> TVSocket {
        if let s = sockets[d.id], s.isOpen { return s }
        let s = TVSocket(device: d) { [weak self] id, message in
            Task { @MainActor in self?.status[id] = message }
        } onToken: { id, token in
            Task { @MainActor in
                if let i = AppModel.shared.config.tvs.firstIndex(where: { $0.id == id }) { AppModel.shared.config.tvs[i].token = token }
            }
        }
        sockets[d.id] = s
        s.connect()
        return s
    }
}

/// WebSocket session for LG (SSAP) and Samsung (remote control channel). Both TVs use
/// self-signed certificates on the local network, which this session accepts for their host only.
final class TVSocket: NSObject, URLSessionWebSocketDelegate, URLSessionDelegate, @unchecked Sendable {
    private let device: TVDevice
    private var task: URLSessionWebSocketTask?
    private var queue: [[String: Any]] = []
    private var ready = false
    private let onStatus: (UUID, String) -> Void
    private let onToken: (UUID, String) -> Void
    var isOpen: Bool { task?.state == .running }

    init(device: TVDevice, onStatus: @escaping (UUID, String) -> Void, onToken: @escaping (UUID, String) -> Void) {
        self.device = device
        self.onStatus = onStatus
        self.onToken = onToken
    }

    func connect() {
        let url: URL?
        switch device.kind {
        case .lg: url = URL(string: "wss://\(device.host):3001")
        case .samsung:
            let name = Data("Lucent".utf8).base64EncodedString()
            url = URL(string: "wss://\(device.host):8002/api/v2/channels/samsung.remote.control?name=\(name)" + (device.token.map { "&token=\($0)" } ?? ""))
        default: url = nil
        }
        guard let url else { return }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task?.resume()
        receive()
        if device.kind == .lg { register() } else { ready = true }
        onStatus(device.id, device.kind == .lg && device.token == nil ? "Accept the prompt on your TV" : "Connected")
    }

    private func register() {
        var payload: [String: Any] = [
            "forcePairing": false, "pairingType": "PROMPT",
            "manifest": ["manifestVersion": 1, "appVersion": "1.0",
                         "signed": ["appId": "com.yahyakhamaisi.lucent", "vendorId": "com.yahyakhamaisi", "localizedAppNames": ["": "Lucent"],
                                    "permissions": ["CONTROL_AUDIO", "CONTROL_POWER", "CONTROL_INPUT_TV", "READ_INPUT_DEVICE_LIST"]],
                         "permissions": ["CONTROL_AUDIO", "CONTROL_POWER", "CONTROL_INPUT_TV", "READ_INPUT_DEVICE_LIST"]]
        ]
        if let token = device.token { payload["client-key"] = token }
        write(["type": "register", "id": "register_0", "payload": payload])
    }

    func send(_ message: [String: Any]) {
        if ready { write(message) } else { queue.append(message) }
    }

    private func write(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            if case .success(.string(let text)) = result,
               let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
                handle(json)
            }
            if case .failure(let error) = result {
                onStatus(device.id, "Disconnected: \(error.localizedDescription)")
                return
            }
            receive()
        }
    }

    private func handle(_ json: [String: Any]) {
        // LG: {"type":"registered","payload":{"client-key":"…"}}
        if json["type"] as? String == "registered" {
            if let key = (json["payload"] as? [String: Any])?["client-key"] as? String { onToken(device.id, key) }
            ready = true
            onStatus(device.id, "Paired")
            queue.forEach(write)
            queue = []
        }
        // Samsung: {"event":"ms.channel.connect","data":{"token":"…"}}
        if json["event"] as? String == "ms.channel.connect" {
            if let token = (json["data"] as? [String: Any])?["token"] as? String { onToken(device.id, token) }
            onStatus(device.id, "Paired")
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host == device.host, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Minimal SSDP M-SEARCH over a UDP socket.
enum SSDP {
    struct Hit { let host: String; let server: String; let location: String }

    static func search(timeout: TimeInterval) -> [Hit] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")
        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n"
        for _ in 0..<2 {
            _ = message.withCString { ptr in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, ptr, strlen(ptr), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        var hits: [String: Hit] = [:]
        let end = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < end {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            let text = String(decoding: buffer.prefix(n), as: UTF8.self)
            let host = String(cString: inet_ntoa(from.sin_addr))
            var headers: [String: String] = [:]
            for line in text.split(separator: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].uppercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let location = headers["LOCATION"] ?? ""
            hits[host + location] = Hit(host: host, server: headers["SERVER"] ?? "", location: location)
        }
        return Array(hits.values)
    }

    /// Reads the UPnP description to tell what kind of device answered.
    static func classify(_ hit: Hit) async -> (TVKind, String)? {
        var name = hit.host
        var manufacturer = hit.server
        if let url = URL(string: hit.location), let (data, _) = try? await URLSession.shared.data(from: url) {
            let xml = String(decoding: data, as: UTF8.self)
            func tag(_ t: String) -> String? {
                guard let a = xml.range(of: "<\(t)>"), let b = xml.range(of: "</\(t)>", range: a.upperBound..<xml.endIndex) else { return nil }
                return String(xml[a.upperBound..<b.lowerBound])
            }
            name = tag("friendlyName") ?? name
            manufacturer += " " + (tag("manufacturer") ?? "")
        }
        let m = manufacturer.lowercased()
        if m.contains("webos") || m.contains("lg electronics") { return (.lg, name) }
        if m.contains("samsung") { return (.samsung, name) }
        if m.contains("philips") || m.contains("tp vision") { return (.philips, name) }
        if m.contains("yamaha") { return (.yamaha, name) }
        return nil
    }
}
