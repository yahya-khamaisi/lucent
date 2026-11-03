import CoreGraphics
import Foundation
import IOKit

/// MCCS VCP codes Lucent uses.
enum VCP: UInt8 {
    case brightness = 0x10
    case contrast = 0x12
    case inputSource = 0x60
    case volume = 0x62
    case mute = 0x8D
    case power = 0xD6
}

/// DDC/CI over the display's I²C channel (Apple silicon, via IOAVService).
/// All I/O runs on one serial queue: monitors dislike overlapping requests.
final class DDCChannel: @unchecked Sendable {
    let service: PrivateAPI.AVService
    let productName: String
    static let queue = DispatchQueue(label: "lucent.ddc", qos: .userInitiated)

    init(service: PrivateAPI.AVService, productName: String) {
        self.service = service
        self.productName = productName
    }

    private func checksum(_ initial: UInt8, _ data: [UInt8]) -> UInt8 {
        data.reduce(initial) { $0 ^ $1 }
    }

    private func send(_ payload: [UInt8]) -> Bool {
        var packet = [UInt8(0x80 | (payload.count + 1)), UInt8(payload.count)] + payload
        packet.append(checksum(payload.count == 1 ? 0x6E : 0x6E ^ 0x51, packet))
        var ok = false
        for _ in 0..<2 {   // many monitors drop the first write
            usleep(10_000)
            ok = PrivateAPI.i2cWrite(service, chip: 0x37, offset: 0x51, &packet) || ok
        }
        return ok
    }

    /// Current and maximum value of a VCP feature.
    func read(_ code: VCP) -> (value: Int, max: Int)? {
        for _ in 0..<3 {
            guard send([code.rawValue]) else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard PrivateAPI.i2cRead(service, chip: 0x37, offset: 0x51, &reply) else { continue }
            guard reply[2] == 0x02, reply[3] == 0x00,
                  checksum(0x50, Array(reply[0..<10])) == reply[10] else { continue }
            let max = Int(reply[6]) << 8 | Int(reply[7])
            let value = Int(reply[8]) << 8 | Int(reply[9])
            return (value, max == 0 ? 100 : max)
        }
        return nil
    }

    @discardableResult
    func write(_ code: VCP, _ value: Int) -> Bool {
        let v = UInt16(clamping: value)
        return send([code.rawValue, UInt8(v >> 8), UInt8(v & 0xFF)])
    }

    func readAsync(_ code: VCP, _ done: @escaping @MainActor @Sendable ((value: Int, max: Int)?) -> Void) {
        Self.queue.async { [self] in
            let result = read(code)
            Task { @MainActor in done(result) }
        }
    }

    /// Writes are coalesced: while a slider is dragged only the latest value is sent.
    private var pending: [VCP: Int] = [:]
    private let lock = NSLock()

    func writeAsync(_ code: VCP, _ value: Int) {
        lock.lock()
        let scheduled = pending[code] != nil
        pending[code] = value
        lock.unlock()
        guard !scheduled else { return }
        Self.queue.async { [self] in
            lock.lock()
            let latest = pending.removeValue(forKey: code)
            lock.unlock()
            if let latest { write(code, latest) }
        }
    }
}

enum DDCDiscovery {
    struct Found {
        let channel: DDCChannel
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
        let name: String
    }

    /// Walks the IORegistry pairing each external framebuffer's product attributes with
    /// the DCPAVServiceProxy that follows it, then matches those to CoreGraphics displays.
    static func scan() -> [Found] {
        var found: [Found] = []
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var attributes: [String: Any]?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            let name = String(cString: nameBuffer)

            if name.hasPrefix("AppleCLCD2") || name.hasPrefix("IOMobileFramebufferShim") {
                if let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] {
                    attributes = attrs["ProductAttributes"] as? [String: Any]
                }
            } else if name == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                guard location == "External", let service = PrivateAPI.avService(for: entry) else { continue }
                let product = attributes?["ProductName"] as? String ?? "External Display"
                found.append(Found(
                    channel: DDCChannel(service: service, productName: product),
                    vendor: (attributes?["LegacyManufacturerID"] as? NSNumber)?.uint32Value ?? 0,
                    product: (attributes?["ProductID"] as? NSNumber)?.uint32Value ?? 0,
                    serial: (attributes?["SerialNumber"] as? NSNumber)?.uint32Value ?? 0,
                    name: product))
                attributes = nil
            }
        }
        return found
    }

    /// Display ID → DDC channel.
    static func match(_ found: [Found], to displays: [Display]) -> [CGDirectDisplayID: DDCChannel] {
        var result: [CGDirectDisplayID: DDCChannel] = [:]
        var remaining = found
        let externals = displays.filter { !$0.isBuiltin && !$0.isVirtual }
        for display in externals {
            if let i = remaining.firstIndex(where: { $0.vendor == display.vendor && $0.product == display.model
                && ($0.serial == 0 || display.serial == 0 || $0.serial == display.serial) }) {
                result[display.id] = remaining.remove(at: i).channel
            }
        }
        // One unmatched display and one unmatched channel: they belong together.
        let unmatched = externals.filter { result[$0.id] == nil }
        if unmatched.count == 1, remaining.count == 1 { result[unmatched[0].id] = remaining[0].channel }
        return result
    }
}
