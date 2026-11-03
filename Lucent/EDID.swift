import AppKit
import IOKit

/// Reading EDIDs and writing display override files.
enum EDID {
    /// Finds the EDID blob for a display by walking the IORegistry for "EDID" data whose
    /// manufacturer and product code match the display.
    static func read(_ d: Display) -> Data? {
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var fallback: Data?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            for key in ["EDID", "IODisplayEDID"] {
                guard let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data, data.count >= 128 else { continue }
                let vendor = UInt32(data[8]) << 8 | UInt32(data[9])
                let product = UInt32(data[10]) | UInt32(data[11]) << 8
                if vendor == d.vendor && product == d.model { return data }
                fallback = fallback ?? data
            }
        }
        return d.isBuiltin ? nil : fallback
    }

    static func summary(_ data: Data) -> String {
        guard data.count >= 128 else { return "Invalid" }
        let v = UInt16(data[8]) << 8 | UInt16(data[9])
        let letters = [(v >> 10) & 0x1F, (v >> 5) & 0x1F, v & 0x1F].map { Character(UnicodeScalar(UInt8($0) + 64)) }
        return "\(String(letters)) · \(data[18]).\(data[19]) · week \(data[16]) \(1990 + Int(data[17])) · \(data.count) bytes"
    }

    static func export(_ d: Display) {
        guard let data = read(d) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(d.name) EDID.bin"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }

    /// Writes an override for this display to /Library/Displays: a custom name, extra
    /// HiDPI sizes and optionally a replacement EDID. Takes effect after reconnecting.
    /// macOS on Apple silicon honours fewer override keys than on Intel.
    static func writeOverride(_ d: Display, name: String, hidpiSizes: [(Int, Int)], edid: Data?) -> Bool {
        var plist: [String: Any] = [
            "DisplayProductName": name,
            "DisplayVendorID": d.vendor,
            "DisplayProductID": d.model
        ]
        if !hidpiSizes.isEmpty {
            plist["scale-resolutions"] = hidpiSizes.flatMap { w, h -> [Data] in
                func entry(_ w: Int, _ h: Int, _ flags: UInt32) -> Data {
                    var bytes = [UInt32(w * 2).bigEndian, UInt32(h * 2).bigEndian, flags.bigEndian]
                    return Data(bytes: &bytes, count: 12)
                }
                return [entry(w, h, 1), entry(w, h, 0x200000)]
            }
        }
        if let edid { plist["IODisplayEDID"] = edid }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lucent-override.plist")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? data.write(to: temp)) != nil else { return false }
        let dir = String(format: "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-%x", d.vendor)
        let file = String(format: "%@/DisplayProductID-%x", dir, d.model)
        return admin("mkdir -p '\(dir)' && cp '\(temp.path)' '\(file)' && chmod 644 '\(file)'")
    }

    static func removeOverride(_ d: Display) -> Bool {
        let file = String(format: "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-%x/DisplayProductID-%x", d.vendor, d.model)
        return admin("rm -f '\(file)'")
    }

    static func hasOverride(_ d: Display) -> Bool {
        FileManager.default.fileExists(atPath: String(format: "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-%x/DisplayProductID-%x", d.vendor, d.model))
    }

    private static func admin(_ shell: String) -> Bool {
        var error: NSDictionary?
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        return error == nil
    }
}
