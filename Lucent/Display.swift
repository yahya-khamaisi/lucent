import AppKit
import CoreGraphics

/// One usable mode of a display. HiDPI modes draw at `width`×`height` points from
/// `pixelWidth`×`pixelHeight` pixels.
struct DisplayMode: Identifiable, Hashable {
    let mode: CGDisplayMode
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refresh: Double
    let isNative: Bool

    init(_ mode: CGDisplayMode) {
        self.mode = mode
        width = mode.width
        height = mode.height
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refresh = mode.refreshRate
        isNative = mode.ioFlags & 0x0200_0000 != 0   // kDisplayModeNativeFlag
    }

    var isHiDPI: Bool { pixelWidth > width }
    /// Size + scale, ignoring refresh rate: what favourites and protection store.
    var key: String { "\(width)x\(height)" + (isHiDPI ? "@2x" : "") }
    var id: String { key + "@\(refreshLabel)" }
    var sizeLabel: String { "\(width) × \(height)" }
    var refreshLabel: String { refresh == 0 ? "60" : String(format: refresh.rounded() == refresh ? "%.0f" : "%.2f", refresh) }

    static func == (a: DisplayMode, b: DisplayMode) -> Bool { a.id == b.id && a.pixelWidth == b.pixelWidth }
    func hash(into h: inout Hasher) { h.combine(id); h.combine(pixelWidth) }
}

struct Display: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var uuid: String
    var name: String
    var isBuiltin: Bool
    var isVirtual: Bool
    var isMain: Bool
    var mirrorOf: CGDirectDisplayID?
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32
    var bounds: CGRect
    var rotation: Int
    var current: DisplayMode?
    var allModes: [DisplayMode]

    static func == (a: Display, b: Display) -> Bool {
        a.id == b.id && a.name == b.name && a.current == b.current && a.bounds == b.bounds
            && a.rotation == b.rotation && a.mirrorOf == b.mirrorOf && a.isMain == b.isMain && a.allModes.count == b.allModes.count
    }

    var screen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }

    /// Modes for the resolution list: one entry per size and scale, largest first.
    var resolutions: [DisplayMode] {
        var seen = Set<String>()
        let rate = current?.refresh ?? 0
        let sorted = allModes.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI }
            return abs($0.refresh - rate) < abs($1.refresh - rate)
        }
        return sorted.filter { seen.insert($0.key).inserted }
    }

    /// Refresh rates available at the current size and scale.
    var refreshRates: [DisplayMode] {
        guard let current else { return [] }
        var seen = Set<String>()
        return allModes.filter { $0.key == current.key }
            .sorted { $0.refresh < $1.refresh }
            .filter { seen.insert($0.refreshLabel).inserted }
    }

    var hasNotch: Bool {
        guard #available(macOS 12.0, *), let screen else { return false }
        return screen.safeAreaInsets.top > 0
    }

    var edrHeadroom: CGFloat { screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1 }

    /// How far XDR Boost may lift SDR white. Capped at 3.2× (500 → 1600 nits on Apple XDR
    /// panels): the reported headroom is meant for HDR highlights, not the whole desktop.
    var boostHeadroom: CGFloat { min(edrHeadroom, 3.2) }

    /// The panel's physical pixel size.
    var nativePixels: (Int, Int)? {
        let native = allModes.first { $0.isNative } ?? allModes.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
        return native.map { ($0.pixelWidth, $0.pixelHeight) }
    }

    var symbol: String {
        if isVirtual { return "rectangle.dashed" }
        if isBuiltin { return "laptopcomputer" }
        return "display"
    }

    var shortName: String {
        if isBuiltin { return "Built-in" }
        return name
    }
}

enum DisplayEnumerator {
    /// Vendor ID Lucent stamps on its virtual screens ("LU").
    static let virtualVendor: UInt32 = 0x4C55

    static func onlineIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func uuid(_ id: CGDirectDisplayID) -> String {
        guard let ref = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let str = CFUUIDCreateString(nil, ref) as String? else { return "display-\(id)" }
        return str
    }

    static func modes(_ id: CGDirectDisplayID) -> [DisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        return modes.filter { $0.isUsableForDesktopGUI() }.map(DisplayMode.init)
    }

    static func display(_ id: CGDirectDisplayID, virtualNames: [UInt32: String]) -> Display {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        let vendor = CGDisplayVendorNumber(id)
        let serial = CGDisplaySerialNumber(id)
        let isVirtual = vendor == virtualVendor
        let builtin = CGDisplayIsBuiltin(id) != 0
        let mirror = CGDisplayMirrorsDisplay(id)
        var name = screen?.localizedName ?? (builtin ? "Built-in Display" : "Display \(id)")
        if isVirtual, let virtualName = virtualNames[serial] { name = virtualName }
        return Display(
            id: id,
            uuid: uuid(id),
            name: name,
            isBuiltin: builtin,
            isVirtual: isVirtual,
            isMain: CGDisplayIsMain(id) != 0,
            mirrorOf: mirror == kCGNullDirectDisplay ? nil : mirror,
            vendor: vendor,
            model: CGDisplayModelNumber(id),
            serial: serial,
            bounds: CGDisplayBounds(id),
            rotation: Int(CGDisplayRotation(id)),
            current: CGDisplayCopyDisplayMode(id).map(DisplayMode.init),
            allModes: modes(id)
        )
    }
}
