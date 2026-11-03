import AppKit
import Network

/// One command language shared by the CLI, `lucent://` URLs, the local HTTP server,
/// Shortcuts and event scripts.
///
///     lucent list
///     lucent get  -n "DELL*" [--brightness|--resolution|--volume|--contrast|--info]
///     lucent set  -n builtin --brightness 40% --resolution 2560x1440 --hidpi on --refresh 60
///                 --rotation 90 --volume 30% --contrast 50% --input 0x11 --xdr 50% --main
///                 --mirror <name|off> --notch <on|off> --connected <on|off>
///     lucent toggle -n <name> --connected|--protect|--hidpi|--nightshift|--mirror
///     lucent virtual create --name Desk --size 3840x2160 [--hidpi off] [--refresh 60]
///     lucent virtual <connect|disconnect|remove> <name>
///     lucent pip <display-name|off>
///     lucent reconnect
@MainActor
enum Command {
    static func run(_ args: [String]) -> String {
        guard let verb = args.first?.lowercased() else { return help }
        let options = parse(Array(args.dropFirst()))
        let model = AppModel.shared
        model.log("cli", args.joined(separator: " "))
        let targets = model.display(matching: options.value("n", "name", "display") ?? (verb == "list" ? "all" : "main"))

        switch verb {
        case "list":
            return model.displays.map { d in
                "\(d.id)\t\(d.name)\t\(d.current?.sizeLabel ?? "?")\(d.current?.isHiDPI == true ? " HiDPI" : "")\t\(d.isMain ? "main" : "")"
            }.joined(separator: "\n")

        case "get":
            guard !targets.isEmpty else { return "error: no display matches" }
            return targets.map { get($0, options) }.joined(separator: "\n")

        case "set":
            guard !targets.isEmpty else { return "error: no display matches" }
            return targets.map { set($0, options) }.joined(separator: "\n")

        case "toggle":
            guard let d = targets.first else { return "error: no display matches" }
            if options.has("connected") { model.disconnect(d); return "ok" }
            if options.has("protect") { model.setProtect(d, !model.settings(d).protect); return "ok" }
            if options.has("hidpi") { model.setFlexibleHiDPI(d, !model.settings(d).flexibleHiDPI); return "ok" }
            if options.has("nightshift") { model.setNightShift(!model.nightShift); return "ok" }
            if options.has("mirror") { model.setMirrorAll(!model.isMirroring); return "ok" }
            return "error: nothing to toggle"

        case "virtual":
            return virtualCommand(options)

        case "pip":
            let name = options.positional.first ?? "main"
            if name == "off" { PiP.shared.closeAll(); return "ok" }
            guard let d = model.display(matching: name).first else { return "error: no display matches" }
            PiP.shared.open(display: d.id)
            return "ok"

        case "reconnect":
            model.reconnectAll()
            return "ok"

        case "http":
            let on = ["on", "true", "1"].contains(options.positional.first?.lowercased() ?? "")
            model.config.automation.httpServer = on
            Automation.shared.setHTTP(on)
            return "ok"

        case "help", "-h", "--help":
            return help

        default:
            return "error: unknown command \(verb)\n" + help
        }
    }

    private static func get(_ d: Display, _ o: Options) -> String {
        let model = AppModel.shared
        if o.has("brightness") { return percent(model.brightness[d.id]) }
        if o.has("volume") { return percent(model.hardware[d.id]?.volume) }
        if o.has("contrast") { return percent(model.hardware[d.id]?.contrast) }
        if o.has("resolution") { return "\(d.current?.width ?? 0)x\(d.current?.height ?? 0)" + (d.current?.isHiDPI == true ? " HiDPI" : "") }
        if o.has("refresh") { return d.current?.refreshLabel ?? "?" }
        return """
        name: \(d.name)
        id: \(d.id)  uuid: \(d.uuid)
        resolution: \(d.current?.sizeLabel ?? "?")\(d.current?.isHiDPI == true ? " HiDPI" : "") @ \(d.current?.refreshLabel ?? "?") Hz
        brightness: \(percent(model.brightness[d.id])) (\(model.method(d).rawValue))
        rotation: \(d.rotation)°  main: \(d.isMain)  virtual: \(d.isVirtual)
        """
    }

    private static func set(_ d: Display, _ o: Options) -> String {
        let model = AppModel.shared
        var done: [String] = []
        if let v = o.percent("brightness") { model.setBrightness(d, v); done.append("brightness") }
        if let v = o.percent("volume") { model.setVolume(d, v); done.append("volume") }
        if let v = o.percent("contrast") { model.setContrast(d, v); done.append("contrast") }
        if let v = o.percent("xdr") { model.setXDR(d, v); done.append("xdr") }
        if let r = o.value("resolution") {
            let hidpi = o.bool("hidpi") ?? true
            let key = r.lowercased().replacingOccurrences(of: "×", with: "x") + (hidpi ? "@2x" : "")
            let ok = model.setResolution(d, key: key) || model.setResolution(d, key: r.lowercased())
            done.append(ok ? "resolution" : "resolution (not available)")
        }
        if let hz = o.value("refresh").flatMap(Double.init) { done.append(model.setRefresh(d, hz) ? "refresh" : "refresh (not available)") }
        if let deg = o.value("rotation").flatMap(Int.init) { model.setRotation(d, deg); done.append("rotation") }
        if let input = o.value("input") {
            let code = input.hasPrefix("0x") ? Int(input.dropFirst(2), radix: 16) : Int(input)
            if let code { model.setInput(d, code); done.append("input") }
        }
        if o.has("main") { model.setMain(d); done.append("main") }
        if let m = o.value("mirror") {
            if m == "off" { model.setMirror(d, of: nil) } else if let master = model.display(matching: m).first { model.setMirror(d, of: master.id) }
            done.append("mirror")
        }
        if let n = o.bool("notch") { model.setNotchShown(d, n); done.append("notch") }
        if let c = o.bool("connected") {
            if c { model.reconnectAll() } else { model.disconnect(d) }
            done.append("connected")
        }
        if let p = o.bool("protect") { model.setProtect(d, p); done.append("protect") }
        if let n = o.bool("nightshift") { model.setNightShift(n); done.append("nightshift") }
        return done.isEmpty ? "error: nothing to set" : "\(d.name): " + done.joined(separator: ", ")
    }

    private static func virtualCommand(_ o: Options) -> String {
        let model = AppModel.shared
        guard let action = o.positional.first?.lowercased() else { return "error: virtual create|connect|disconnect|remove" }
        if action == "create" {
            let size = (o.value("size") ?? "3840x2160").lowercased().split(separator: "x").compactMap { Int($0) }
            guard size.count == 2 else { return "error: --size WxH" }
            model.addVirtual(name: o.value("name") ?? "Virtual Screen", width: size[0], height: size[1],
                             hiDPI: o.bool("hidpi") ?? true, refresh: o.value("refresh").flatMap(Double.init) ?? 60)
            return "ok"
        }
        let name = o.positional.dropFirst().joined(separator: " ").lowercased()
        guard let c = model.config.virtualScreens.first(where: { $0.name.lowercased() == name || $0.name.lowercased().hasPrefix(name) }) else {
            return "error: no virtual screen named \(name)"
        }
        switch action {
        case "connect": model.setVirtual(c.id, connected: true)
        case "disconnect": model.setVirtual(c.id, connected: false)
        case "remove": model.removeVirtual(c.id)
        default: return "error: unknown action \(action)"
        }
        return "ok"
    }

    private static func percent(_ v: Double?) -> String {
        v.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a"
    }

    // MARK: Options

    struct Options {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []

        func value(_ names: String...) -> String? { names.lazy.compactMap { values[$0] }.first }
        func has(_ name: String) -> Bool { flags.contains(name) || values[name] != nil }
        func bool(_ name: String) -> Bool? {
            guard let v = values[name]?.lowercased() else { return flags.contains(name) ? true : nil }
            return ["on", "true", "yes", "1"].contains(v)
        }
        /// "40%", "40" and "0.4" all mean 40%.
        func percent(_ name: String) -> Double? {
            guard let raw = values[name] else { return nil }
            let trimmed = raw.replacingOccurrences(of: "%", with: "")
            guard let n = Double(trimmed) else { return nil }
            return raw.hasSuffix("%") || n > 1 ? n / 100 : n
        }
    }

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("-") {
                var name = a.drop { $0 == "-" }.lowercased()
                var value: String?
                if let eq = name.firstIndex(of: "=") {
                    value = String(name[name.index(after: eq)...])
                    name = String(name[..<eq])
                } else if i + 1 < args.count, !args[i + 1].hasPrefix("--"), !(args[i + 1].hasPrefix("-") && Double(args[i + 1]) == nil) {
                    value = args[i + 1]
                    i += 1
                }
                if let value { o.values[name] = value } else { o.flags.insert(name) }
            } else {
                o.positional.append(a)
            }
            i += 1
        }
        return o
    }

    /// `lucent://set?display=builtin&brightness=40%` → ["set", "--display", "builtin", "--brightness", "40%"]
    static func args(fromPath path: String, query: [URLQueryItem]) -> [String] {
        var args = path.split(separator: "/").map(String.init)
        for item in query {
            args.append("--" + item.name)
            if let v = item.value, !v.isEmpty { args.append(v) }
        }
        return args
    }

    static let help = """
    lucent list
    lucent get -n <display> [--brightness|--resolution|--refresh|--volume|--contrast]
    lucent set -n <display> [--brightness 40%] [--resolution 2560x1440 [--hidpi off]] [--refresh 60]
               [--rotation 0|90|180|270] [--volume 30%] [--contrast 50%] [--input 0x11] [--xdr 50%]
               [--main] [--mirror <display>|off] [--notch on|off] [--connected on|off] [--protect on|off]
    lucent toggle -n <display> --connected|--protect|--hidpi|--nightshift|--mirror
    lucent virtual create --name <name> --size 3840x2160 [--hidpi off] [--refresh 60]
    lucent virtual connect|disconnect|remove <name>
    lucent pip <display>|off
    lucent reconnect
    lucent http on|off
    Display can be: main, builtin, all, an id, a name, or a prefix ending in *.
    """
}

/// Transport for the command language: CLI bridge, URL scheme, HTTP, event scripts.
@MainActor
final class Automation {
    static let shared = Automation()
    nonisolated static let commandNote = Notification.Name("com.yahyakhamaisi.lucent.command")
    nonisolated static func replyNote(_ token: String) -> Notification.Name { .init("com.yahyakhamaisi.lucent.reply.\(token)") }

    private var listener: NWListener?
    @Published private(set) var httpRunning = false

    func start() {
        DistributedNotificationCenter.default().addObserver(forName: Self.commandNote, object: nil, queue: .main) { note in
            guard let info = note.userInfo, let args = info["args"] as? [String], let token = info["token"] as? String else { return }
            MainActor.assumeIsolated {
                let output = Command.run(args)
                DistributedNotificationCenter.default().postNotificationName(
                    Automation.replyNote(token), object: nil, userInfo: ["output": output], deliverImmediately: true)
            }
        }
        setHTTP(AppModel.shared.config.automation.httpServer)
    }

    // MARK: URL scheme

    func handle(url: URL) {
        guard AppModel.shared.config.automation.urlScheme, url.scheme == "lucent" else { return }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = (url.host ?? "") + (parts?.path ?? "")
        _ = Command.run(Command.args(fromPath: path, query: parts?.queryItems ?? []))
    }

    // MARK: HTTP (127.0.0.1 only)

    func setHTTP(_ on: Bool) {
        listener?.cancel()
        listener = nil
        httpRunning = false
        guard on else { return }
        let port = NWEndpoint.Port(rawValue: UInt16(AppModel.shared.config.automation.httpPort)) ?? 55777
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        guard let listener = try? NWListener(using: params) else {
            AppModel.shared.log("http", "Could not listen on port \(port)")
            return
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let output = MainActor.assumeIsolated { () -> String in
                    let parts = URLComponents(string: "http://localhost" + target)
                    return Command.run(Command.args(fromPath: parts?.path ?? "", query: parts?.queryItems ?? []))
                }
                let body = output + "\n"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                if case .ready = state { Automation.shared.httpRunning = true; AppModel.shared.log("http", "Listening on 127.0.0.1:\(port)") }
                if case .failed(let e) = state { Automation.shared.httpRunning = false; AppModel.shared.log("http", "Failed: \(e)") }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    // MARK: Event scripts

    func runEventCommand(_ command: String) {
        if command.hasPrefix("lucent ") {
            _ = Command.run(Command.split(String(command.dropFirst(7))))
            return
        }
        let shell = command.lowercased().hasPrefix("shortcut:")
            ? "shortcuts run " + shellQuote(command.dropFirst(9).trimmingCharacters(in: .whitespaces))
            : command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", shell]
        try? process.run()
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Command-line tool

    static let cliPath = "/usr/local/bin/lucent"
    var cliInstalled: Bool { FileManager.default.fileExists(atPath: Self.cliPath) }

    func installCLI() {
        let exe = Bundle.main.executablePath ?? "/Applications/Lucent.app/Contents/MacOS/Lucent"
        let script = "#!/bin/sh\\nexec \\\"\(exe)\\\" cli \\\"$@\\\"\\n"
        let source = """
        do shell script "mkdir -p /usr/local/bin && printf '\(script)' > \(Self.cliPath) && chmod 755 \(Self.cliPath)" with administrator privileges
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        AppModel.shared.log("cli", error == nil ? "Installed \(Self.cliPath)" : "Install cancelled")
        objectWillChange.send()
    }
}

extension Automation: ObservableObject {}

extension Command {
    /// Splits a command line on spaces, keeping "quoted strings" together.
    static func split(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == " " {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// `Lucent cli …`: forwards the arguments to the running app and prints its reply.
enum CLIClient {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.count >= 2, args[1] == "cli" else { return }
        let command = Array(args.dropFirst(2))
        let token = UUID().uuidString
        var output: String?
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: Automation.replyNote(token), object: nil, queue: nil) { note in
            output = note.userInfo?["output"] as? String ?? ""
        }
        center.postNotificationName(Automation.commandNote, object: nil,
                                    userInfo: ["args": command.isEmpty ? ["help"] : command, "token": token],
                                    deliverImmediately: true)
        let deadline = Date().addingTimeInterval(5)
        while output == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        center.removeObserver(observer)
        if let output {
            print(output)
            exit(output.hasPrefix("error") ? 1 : 0)
        }
        FileHandle.standardError.write("Lucent isn't running. Open Lucent and try again.\n".data(using: .utf8)!)
        exit(2)
    }
}
