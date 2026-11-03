import Foundation

/// Software image adjustments applied through the display's gamma table.
struct ImageAdjustments: Codable, Equatable {
    var contrast = 1.0        // 0.5 … 1.5
    var gamma = 1.0           // 0.5 … 2.0 (multiplier on the system curve)
    var temperature = 6500.0  // Kelvin, 2700 … 9300
    var red = 1.0, green = 1.0, blue = 1.0
    var invert = false

    static let neutral = ImageAdjustments()
    var isNeutral: Bool { self == .neutral }
}

/// Per-display preferences, keyed by the display's stable UUID.
struct DisplaySettings: Codable, Equatable {
    var favorites: [String] = []          // ModeKey strings
    var dimToBlack = true
    var adjustments = ImageAdjustments()
    var xdrBoost = 0.0                    // 0 … 1 of the extra headroom
    var flexibleHiDPI = false
    var protect = false
    var protectedMode: String?            // ModeKey to hold
    var protectedOrigin: [Int]?           // x, y
    var protectedRotation: Int?
    var maxNits = 350.0                   // for nits-matched group sync
    var events = DisplayEvents()
    var colorProfile: String?
}

struct DisplayEvents: Codable, Equatable {
    var onConnect = ""
    var onDisconnect = ""
    var onSleep = ""
    var onWake = ""
}

struct VirtualScreenConfig: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Virtual Screen"
    var width = 3840
    var height = 2160
    var refreshRate = 60.0
    var hiDPI = true
    var enabled = true
    var connectAtLogin = true
    var mirrorOf: String?                 // UUID of a real display to mirror onto this one

    var aspectLabel: String {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(width, height)
        let (w, h) = (width / g, height / g)
        switch (w, h) {
        case (64, 27), (43, 18), (12, 5): return "21:9"
        case (8, 5): return "16:10"
        default: return w > 32 ? String(format: "%.2f:1", Double(width) / Double(height)) : "\(w):\(h)"
        }
    }
}

struct DisplayGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Desk"
    var members: [String] = []            // display UUIDs
    var syncBrightness = true
    var matchNits = true
    var syncAdjustments = false
}

struct ProtectionRules: Codable, Equatable {
    var arrangement = true
    var resolution = true
    var refreshRate = true
    var rotation = false
    var colorProfile = true
    var mirroring = false
}

struct ConnectionRules: Codable, Equatable {
    var disconnectBuiltInWithExternal = false
    var reconnectOnWake = true
    var pointerAnchors = false
}

struct AutomationSettings: Codable, Equatable {
    var urlScheme = true
    var httpServer = false
    var httpPort = 55777
    var osdBroadcast = true
}

struct KeySettings: Codable, Equatable {
    var mediaKeys = true                  // brightness/volume keys control the display under the pointer
    var shortcutsEnabled = true
    var step = 6.25                       // percent per key press, like macOS (16 steps)
}

enum OSDStyle: String, Codable, CaseIterable { case modern, classic, off }

enum TVKind: String, Codable, CaseIterable { case lg = "LG webOS", samsung = "Samsung Tizen", philips = "Philips", yamaha = "Yamaha" }

struct TVDevice: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: TVKind
    var name: String
    var host: String
    var token: String?
    var followMacVolume = false
}

struct Config: Codable, Equatable {
    var displays: [String: DisplaySettings] = [:]
    var virtualScreens: [VirtualScreenConfig] = []
    var groups: [DisplayGroup] = []
    var protection = ProtectionRules()
    var rules = ConnectionRules()
    var automation = AutomationSettings()
    var keys = KeySettings()
    var osd = OSDStyle.modern
    var tvs: [TVDevice] = []
    var combineAllBrightness = false
    var autoBrightnessSync = false
    var menuIcon = MenuIcon.sun

    // MARK: Persistence

    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lucent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.url, options: .atomic)
    }
}

enum MenuIcon: String, Codable, CaseIterable, Identifiable {
    case sun, display, sparkle, dial
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .sun: "sun.max"
        case .display: "display"
        case .sparkle: "sparkles"
        case .dial: "dial.medium"
        }
    }
    var title: String { rawValue.capitalized }
}
