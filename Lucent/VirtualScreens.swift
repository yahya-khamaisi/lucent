import CoreGraphics
import Foundation

/// Creates and holds CGVirtualDisplay objects. A virtual screen exists for as long as
/// its object is retained; releasing it disconnects the screen.
@MainActor
final class VirtualScreens {
    private var live: [UUID: CGVirtualDisplay] = [:]
    private static let queue = DispatchQueue(label: "lucent.virtual")

    func isConnected(_ id: UUID) -> Bool { live[id] != nil }
    func displayID(_ id: UUID) -> CGDirectDisplayID? { live[id]?.displayID }

    /// Serial number → name, so the display list can show the user's name for each screen.
    func names(_ configs: [VirtualScreenConfig]) -> [UInt32: String] {
        Dictionary(configs.map { (Self.serial($0.id), $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    static func serial(_ id: UUID) -> UInt32 {
        let b = id.uuid   // stable across launches, unlike hashValue
        return (UInt32(b.0) << 24 | UInt32(b.1) << 16 | UInt32(b.2) << 8 | UInt32(b.3)) | 1
    }

    @discardableResult
    func connect(_ config: VirtualScreenConfig) -> CGDirectDisplayID? {
        if let existing = live[config.id] { return existing.displayID }
        let scale: UInt32 = config.hiDPI ? 2 : 1
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = Self.queue
        descriptor.name = config.name
        descriptor.vendorID = DisplayEnumerator.virtualVendor
        descriptor.productID = 0x0001
        descriptor.serialNum = Self.serial(config.id)
        descriptor.maxPixelsWide = UInt32(config.width) * scale
        descriptor.maxPixelsHigh = UInt32(config.height) * scale
        // ~110 ppi at 1x keeps the system's default scaling sensible.
        let mmPerPixel = 25.4 / 110
        descriptor.sizeInMillimeters = CGSize(width: Double(config.width) * mmPerPixel, height: Double(config.height) * mmPerPixel)
        // sRGB primaries and D65.
        descriptor.redPrimary = CGPoint(x: 0.64, y: 0.33)
        descriptor.greenPrimary = CGPoint(x: 0.30, y: 0.60)
        descriptor.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        descriptor.terminationHandler = { _, _ in }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = config.hiDPI ? 1 : 0
        settings.modes = Self.modeSizes(width: config.width, height: config.height).map {
            CGVirtualDisplayMode(width: UInt32($0.0), height: UInt32($0.1), refreshRate: config.refreshRate)
        }
        guard display.apply(settings) else { return nil }
        live[config.id] = display
        return display.displayID
    }

    func disconnect(_ id: UUID) {
        live.removeValue(forKey: id)
    }

    func disconnectAll() { live.removeAll() }

    /// Full size and a ladder of smaller sizes with the same aspect ratio.
    static func modeSizes(width: Int, height: Int) -> [(Int, Int)] {
        let factors: [Double] = [1, 0.9, 0.8, 0.75, 0.667, 0.6, 0.5, 0.4, 0.333]
        var seen = Set<Int>()
        return factors.compactMap { f in
            let w = Int((Double(width) * f / 8).rounded()) * 8
            let h = Int((Double(w) * Double(height) / Double(width)).rounded())
            guard w >= 640, seen.insert(w).inserted else { return nil }
            return (w, h)
        }
    }

    static let presets: [(String, Int, Int)] = [
        ("4K 16:9", 3840, 2160), ("5K 16:9", 5120, 2880), ("QHD 16:9", 2560, 1440),
        ("16:10", 2880, 1800), ("Ultrawide 21:9", 5120, 2160), ("Super Ultrawide 32:9", 5120, 1440),
        ("iPad Portrait", 1668, 2388), ("Portrait 9:16", 2160, 3840), ("4:3", 2048, 1536)
    ]
}
