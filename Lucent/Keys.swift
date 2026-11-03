import AppKit
import Carbon.HIToolbox

/// Brightness keys for displays macOS can't dim itself, plus global shortcuts.
@MainActor
final class Keys {
    static let shared = Keys()
    private var tap: CFMachPort?
    private var hotKeys: [HotKey] = []

    /// The display under the pointer: where keys and shortcuts act.
    static func displayUnderPointer() -> Display? {
        let model = AppModel.shared
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
        let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        return model.displays.first { $0.id == id } ?? model.selected
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        installShortcuts()
        installMediaKeyTap()
    }

    func installShortcuts() {
        hotKeys = []
        guard AppModel.shared.config.keys.shortcutsEnabled else { return }
        let mods = controlKey | optionKey
        hotKeys = [
            HotKey(kVK_UpArrow, mods, id: 1) { if let d = Keys.displayUnderPointer() { AppModel.shared.stepBrightness(d, up: true) } },
            HotKey(kVK_DownArrow, mods, id: 2) { if let d = Keys.displayUnderPointer() { AppModel.shared.stepBrightness(d, up: false) } },
            HotKey(kVK_RightArrow, mods, id: 3) { if let d = Keys.displayUnderPointer() { AppModel.shared.cycleResolution(d) } },
            HotKey(kVK_LeftArrow, mods, id: 4) { if let d = Keys.displayUnderPointer() { AppModel.shared.cycleResolution(d, forward: false) } },
            HotKey(kVK_ANSI_Equal, mods, id: 5) { if let d = Keys.displayUnderPointer() { AppModel.shared.stepVolume(d, up: true) } },
            HotKey(kVK_ANSI_Minus, mods, id: 6) { if let d = Keys.displayUnderPointer() { AppModel.shared.stepVolume(d, up: false) } },
            HotKey(kVK_ANSI_R, mods, id: 7) { AppModel.shared.reconnectAll() },
            HotKey(kVK_ANSI_P, mods, id: 8) { if let d = Keys.displayUnderPointer() { PiP.shared.toggle(display: d.id) } }
        ]
    }

    static let shortcutList: [(String, String)] = [
        ("⌃⌥↑ / ⌃⌥↓", "Brightness"), ("⌃⌥→ / ⌃⌥←", "Next / previous resolution"),
        ("⌃⌥= / ⌃⌥−", "Display volume"), ("⌃⌥R", "Reconnect all displays"), ("⌃⌥P", "Picture in Picture")
    ]

    /// Swallows brightness keys aimed at an external display and handles them over DDC
    /// or software dimming. Built-in and Apple displays keep the system's own handling.
    private func installMediaKeyTap() {
        guard tap == nil, AppModel.shared.config.keys.mediaKeys, Self.accessibilityGranted else { return }
        let mask = CGEventMask(1 << 14)   // NSEventTypeSystemDefined
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { Keys.shared.reenable() }
                return Unmanaged.passUnretained(event)
            }
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
            let key = Int((ns.data1 & 0xFFFF_0000) >> 16)
            let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
            // NX_KEYTYPE_BRIGHTNESS_UP = 2, _DOWN = 3
            guard key == 2 || key == 3 else { return Unmanaged.passUnretained(event) }
            let handled = MainActor.assumeIsolated { Keys.shared.brightnessKey(up: key == 2, down: down) }
            return handled ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil)
        guard let tap else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func brightnessKey(up: Bool, down: Bool) -> Bool {
        guard let d = Self.displayUnderPointer(), AppModel.shared.method(d) != .native else { return false }
        if down { AppModel.shared.stepBrightness(d, up: up) }
        return true
    }

    func restart() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        start()
    }
}

/// Global hotkey via Carbon.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private let id: UInt32

    init(_ keyCode: Int, _ modifiers: Int, id: UInt32, action: @escaping @MainActor () -> Void) {
        self.id = id
        self.action = { MainActor.assumeIsolated { action() } }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let me = Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue()
            guard hotKeyID.id == me.id else { return OSStatus(eventNotHandledErr) }
            me.action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4C43_4E54), id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
