import AppKit
import Combine
import CoreGraphics

struct LogLine: Identifiable {
    let id = UUID()
    let date = Date()
    let category: String
    let text: String
}

/// Live hardware state read over DDC for one display.
struct HardwareState: Equatable {
    var contrast: Double?
    var volume: Double?
    var input: Int?
    var muted = false
}

enum BrightnessMethod: String {
    case native = "Apple native"
    case ddc = "DDC hardware"
    case software = "Software (gamma)"
}

/// The single source of truth: displays, settings and every engine. Views observe it;
/// the CLI, URL scheme, HTTP server and Shortcuts call into it.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var config: Config { didSet { if config != oldValue { scheduleSave() } } }
    @Published private(set) var displays: [Display] = []
    @Published var selectedID: CGDirectDisplayID?
    @Published var brightness: [CGDirectDisplayID: Double] = [:]
    @Published var hardware: [CGDirectDisplayID: HardwareState] = [:]
    @Published private(set) var log: [LogLine] = []
    @Published var nightShift = false
    @Published var antiPWM = false
    /// Displays Lucent switched off, so it can bring them back.
    @Published var disabledByLucent: [CGDirectDisplayID: String] = [:]

    var ddc: [CGDirectDisplayID: DDCChannel] = [:]
    /// Software multiplier per display (1 = no dimming), combined into the gamma table.
    var softwareDim: [CGDirectDisplayID: Double] = [:]
    let virtual = VirtualScreens()
    let xdr = XDRBoost()
    private var saveWork: DispatchWorkItem?
    var protectWorkItem: DispatchWorkItem?
    private var lastOnline = Set<String>()
    private var started = false
    private var autoTimer: Timer?
    private var lastBuiltInBrightness: Float?

    private init() {
        config = Config.load()
    }

    var selected: Display? { displays.first { $0.id == selectedID } ?? displays.first }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { AppModel.shared.displaysChanged() }
        }, nil)

        for screen in config.virtualScreens where screen.enabled && screen.connectAtLogin {
            virtual.connect(screen)
        }
        refreshDisplays()
        lastOnline = Set(displays.map(\.uuid))
        scanDDC()
        readAllBrightness()
        applyImageAll()
        displays.forEach { applyXDR($0) }
        nightShift = PrivateAPI.nightShiftEnabled
        applyFlexibleHiDPI()
        snapshotProtection()
        observeSystem()
        setAutoBrightnessSync(config.autoBrightnessSync)
        Automation.shared.start()
        Keys.shared.start()
        log("app", "Lucent started · \(displays.count) displays")
    }

    func stop() {
        xdr.removeAll()
        CGDisplayRestoreColorSyncSettings()
        // Bring back anything Lucent switched off so the user never ends up with a dark screen.
        for id in disabledByLucent.keys { PrivateAPI.setDisplayEnabled(id, true) }
        config.save()
    }

    func log(_ category: String, _ text: String) {
        log.append(LogLine(category: category, text: text))
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.config.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: Displays

    func refreshDisplays() {
        let names = virtual.names(config.virtualScreens)
        let list = DisplayEnumerator.onlineIDs().map { DisplayEnumerator.display($0, virtualNames: names) }
            .sorted { ($0.isBuiltin ? 0 : $0.isVirtual ? 2 : 1, $0.bounds.minX) < ($1.isBuiltin ? 0 : $1.isVirtual ? 2 : 1, $1.bounds.minX) }
        if list != displays { displays = list }
        if selectedID == nil || !list.contains(where: { $0.id == selectedID }) {
            selectedID = list.first(where: \.isMain)?.id ?? list.first?.id
        }
    }

    func displaysChanged() {
        let before = Set(displays.map(\.uuid))
        refreshDisplays()
        let after = Set(displays.map(\.uuid))
        for uuid in after.subtracting(lastOnline) { runEvent(uuid, \.onConnect, "connect") }
        for uuid in lastOnline.subtracting(after) { runEvent(uuid, \.onDisconnect, "disconnect") }
        lastOnline = after
        if before != after {
            scanDDC()
            readAllBrightness()
            applyConnectionRules()
        }
        // Mode changes reset gamma tables and EDR windows.
        applyImageAll()
        displays.forEach { applyXDR($0) }
        scheduleProtection()
    }

    func display(_ id: CGDirectDisplayID) -> Display? { displays.first { $0.id == id } }

    func display(matching query: String) -> [Display] {
        let q = query.lowercased()
        if q.isEmpty || q == "all" || q == "*" { return displays }
        if q == "main" { return displays.filter(\.isMain) }
        if q == "builtin" || q == "built-in" { return displays.filter(\.isBuiltin) }
        if let n = UInt32(q) { return displays.filter { $0.id == n } }
        if q.hasSuffix("*") { return displays.filter { $0.name.lowercased().hasPrefix(String(q.dropLast())) } }
        return displays.filter { $0.name.lowercased() == q || $0.uuid.lowercased() == q || $0.name.lowercased().contains(q) }
    }

    // MARK: Per-display settings

    func settings(_ d: Display) -> DisplaySettings { config.displays[d.uuid] ?? DisplaySettings() }

    func update(_ d: Display, _ change: (inout DisplaySettings) -> Void) {
        var s = settings(d)
        change(&s)
        config.displays[d.uuid] = s
    }

    func scanDDC() {
        ddc = DDCDiscovery.match(DDCDiscovery.scan(), to: displays)
        for (id, channel) in ddc {
            log("ddc", "\(channel.productName) → display \(id)")
            channel.readAsync(.contrast) { [weak self] r in
                guard let r else { return }
                self?.hardware[id, default: .init()].contrast = Double(r.value) / Double(r.max)
            }
            channel.readAsync(.volume) { [weak self] r in
                guard let r else { return }
                self?.hardware[id, default: .init()].volume = Double(r.value) / Double(r.max)
            }
            channel.readAsync(.inputSource) { [weak self] r in
                guard let r else { return }
                self?.hardware[id, default: .init()].input = r.value & 0xFF
            }
        }
    }

    // MARK: System events

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                if model.config.rules.reconnectOnWake { model.reconnectAll() }
                model.displays.forEach { model.runEvent($0.uuid, \.onWake, "wake") }
            }
        }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                model.displays.forEach { model.runEvent($0.uuid, \.onSleep, "sleep") }
            }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AppModel.shared.applyImageAll()
            }
        }
    }

    func runEvent(_ uuid: String, _ key: KeyPath<DisplayEvents, String>, _ name: String) {
        let command = (config.displays[uuid]?.events[keyPath: key] ?? "").trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        log("event", "\(name): \(command)")
        Automation.shared.runEventCommand(command)
    }

    // MARK: Auto brightness sync (externals follow the built-in ambient sensor)

    func setAutoBrightnessSync(_ on: Bool) {
        config.autoBrightnessSync = on
        autoTimer?.invalidate()
        autoTimer = nil
        guard on else { return }
        autoTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.followBuiltIn() }
        }
    }

    private func followBuiltIn() {
        guard let builtin = displays.first(where: \.isBuiltin), let value = PrivateAPI.nativeBrightness(builtin.id) else { return }
        defer { lastBuiltInBrightness = value }
        guard let last = lastBuiltInBrightness, abs(last - value) > 0.01 else { return }
        brightness[builtin.id] = Double(value)
        for d in displays where !d.isBuiltin { setBrightness(d, Double(value), propagate: false) }
    }
}
