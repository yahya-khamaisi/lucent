import AppKit
import CoreGraphics
import IOKit

/// Private system functions, all resolved at runtime with `dlsym` so a missing symbol on a
/// future macOS turns a feature off instead of crashing the app at launch.
enum PrivateAPI {
    private static func symbol<T>(_ name: String, in path: String? = nil, as type: T.Type) -> T? {
        let handle = path.map { dlopen($0, RTLD_LAZY) } ?? UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    // MARK: DisplayServices (built-in and Apple displays)

    private static let displayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool

    private static let dsGet = symbol("DisplayServicesGetBrightness", in: displayServices, as: GetBrightness.self)
    private static let dsSet = symbol("DisplayServicesSetBrightness", in: displayServices, as: SetBrightness.self)
    private static let dsCan = symbol("DisplayServicesCanChangeBrightness", in: displayServices, as: CanChange.self)

    static func nativeBrightnessSupported(_ id: CGDirectDisplayID) -> Bool {
        dsCan?(id) ?? false
    }

    static func nativeBrightness(_ id: CGDirectDisplayID) -> Float? {
        var value: Float = 0
        guard let dsGet, dsGet(id, &value) == 0 else { return nil }
        return value
    }

    static func setNativeBrightness(_ id: CGDirectDisplayID, _ value: Float) {
        _ = dsSet?(id, max(0, min(1, value)))
    }

    // MARK: SkyLight display enable / disable

    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private static let configureEnabled = symbol("CGSConfigureDisplayEnabled", as: ConfigureEnabled.self)

    static var canDisconnect: Bool { configureEnabled != nil }

    @discardableResult
    static func setDisplayEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool {
        guard let configureEnabled else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard configureEnabled(config, id, enabled) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    // MARK: IOAVService (DDC/CI on Apple silicon)

    typealias AVService = CFTypeRef
    private typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias AVI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private static let avCreate = symbol("IOAVServiceCreateWithService", as: AVCreate.self)
    private static let avRead = symbol("IOAVServiceReadI2C", as: AVI2C.self)
    private static let avWrite = symbol("IOAVServiceWriteI2C", as: AVI2C.self)

    static func avService(for service: io_service_t) -> AVService? {
        avCreate?(kCFAllocatorDefault, service)?.takeRetainedValue()
    }

    static func i2cWrite(_ service: AVService, chip: UInt32, offset: UInt32, _ data: inout [UInt8]) -> Bool {
        guard let avWrite else { return false }
        let count = UInt32(data.count)
        return data.withUnsafeMutableBytes { avWrite(service, chip, offset, $0.baseAddress!, count) } == KERN_SUCCESS
    }

    static func i2cRead(_ service: AVService, chip: UInt32, offset: UInt32, _ data: inout [UInt8]) -> Bool {
        guard let avRead else { return false }
        let count = UInt32(data.count)
        return data.withUnsafeMutableBytes { avRead(service, chip, offset, $0.baseAddress!, count) } == KERN_SUCCESS
    }

    // MARK: MonitorPanel (rotation, presets)

    private static let monitorPanelLoaded: Bool = {
        dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != nil
    }()

    /// The `MPDisplay` object System Settings uses for a display, if available.
    static func mpDisplay(_ id: CGDirectDisplayID) -> NSObject? {
        guard monitorPanelLoaded, let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type else { return nil }
        let manager = cls.init()
        guard let displays = manager.value(forKey: "displays") as? [NSObject] else { return nil }
        return displays.first { ($0.value(forKey: "displayID") as? NSNumber)?.uint32Value == id }
    }

    static func setRotation(_ id: CGDirectDisplayID, degrees: Int) -> Bool {
        guard let display = mpDisplay(id) else { return false }
        let sel = NSSelectorFromString("setOrientation:")
        guard display.responds(to: sel), let imp = display.method(for: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, Int32) -> Void
        unsafeBitCast(imp, to: Fn.self)(display, sel, Int32(degrees))
        return true
    }

    /// Reference presets on XDR and Studio displays ("Apple XDR Display (P3-1600 nits)" …).
    static func presets(_ id: CGDirectDisplayID) -> (names: [String], active: String?) {
        guard let display = mpDisplay(id),
              display.responds(to: NSSelectorFromString("presets")),
              let presets = display.value(forKey: "presets") as? [NSObject] else { return ([], nil) }
        let names = presets.compactMap { $0.value(forKey: "presetName") as? String }
        let active = (display.value(forKey: "activePreset") as? NSObject)?.value(forKey: "presetName") as? String
        return (names, active)
    }

    static func setPreset(_ id: CGDirectDisplayID, name: String) -> Bool {
        guard let display = mpDisplay(id),
              let presets = display.value(forKey: "presets") as? [NSObject],
              let preset = presets.first(where: { $0.value(forKey: "presetName") as? String == name }) else { return false }
        let sel = NSSelectorFromString("setActivePreset:")
        guard display.responds(to: sel) else { return false }
        display.perform(sel, with: preset)
        return true
    }

    // MARK: CoreBrightness (Night Shift)

    private static let blueLight: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    static var nightShiftAvailable: Bool { blueLight != nil }

    static func setNightShift(_ on: Bool) {
        guard let client = blueLight else { return }
        let sel = NSSelectorFromString("setEnabled:")
        guard client.responds(to: sel), let imp = client.method(for: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(imp, to: Fn.self)(client, sel, on)
    }

    static var nightShiftEnabled: Bool {
        guard let client = blueLight else { return false }
        // getBlueLightStatus: fills a struct whose second byte is "enabled".
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard client.responds(to: sel), let imp = client.method(for: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        var status = [UInt8](repeating: 0, count: 64)
        _ = status.withUnsafeMutableBytes { unsafeBitCast(imp, to: Fn.self)(client, sel, $0.baseAddress!) }
        return status[1] != 0
    }
}
