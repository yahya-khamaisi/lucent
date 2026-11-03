import AppKit
import CoreGraphics

/// Brightness, volume, image adjustments and XDR boost.
extension AppModel {
    /// Below this point of the combined slider, hardware is at minimum and software dims further.
    private static let softwareKnee = 0.15

    func method(_ d: Display) -> BrightnessMethod {
        if PrivateAPI.nativeBrightnessSupported(d.id) { return .native }
        if ddc[d.id] != nil { return .ddc }
        return .software
    }

    func readAllBrightness() {
        for d in displays { readBrightness(d) }
    }

    func readBrightness(_ d: Display) {
        let dim = settings(d).dimToBlack
        switch method(d) {
        case .native:
            if let v = PrivateAPI.nativeBrightness(d.id) { brightness[d.id] = combined(hardware: Double(v), dim: dim) }
        case .ddc:
            ddc[d.id]?.readAsync(.brightness) { [weak self] r in
                guard let self, let r else { return }
                brightness[d.id] = combined(hardware: Double(r.value) / Double(r.max), dim: dim)
            }
        case .software:
            if brightness[d.id] == nil { brightness[d.id] = 1 }
        }
    }

    private func combined(hardware: Double, dim: Bool) -> Double {
        dim ? Self.softwareKnee + hardware * (1 - Self.softwareKnee) : hardware
    }

    /// Hardware level (nil when there is none) and software multiplier for a combined value.
    private func split(_ c: Double, hasHardware: Bool, dim: Bool) -> (hw: Double?, sw: Double) {
        guard hasHardware else { return (nil, dim ? max(0.02, c) : max(0.2, c)) }
        guard dim else { return (c, 1) }
        let k = Self.softwareKnee
        if c >= k { return ((c - k) / (1 - k), 1) }
        return (0, 0.03 + 0.97 * c / k)
    }

    func setBrightness(_ d: Display, _ value: Double, propagate: Bool = true) {
        let c = max(0, min(1, value))
        brightness[d.id] = c
        let m = method(d)
        let parts = split(c, hasHardware: m != .software, dim: settings(d).dimToBlack)
        if let hw = parts.hw {
            if m == .native { PrivateAPI.setNativeBrightness(d.id, Float(hw)) }
            if m == .ddc { ddc[d.id]?.writeAsync(.brightness, Int((hw * 100).rounded())) }
        }
        softwareDim[d.id] = parts.sw
        applyImage(d)
        guard propagate else { return }
        if config.combineAllBrightness {
            for other in displays where other.id != d.id { setBrightness(other, c, propagate: false) }
        } else {
            syncGroups(from: d, value: c)
        }
    }

    func stepBrightness(_ d: Display, up: Bool) {
        let step = config.keys.step / 100
        setBrightness(d, (brightness[d.id] ?? 1) + (up ? step : -step))
        OSD.shared.show(kind: .brightness, value: brightness[d.id] ?? 0, on: d)
    }

    private func syncGroups(from d: Display, value: Double) {
        for group in config.groups where group.syncBrightness && group.members.contains(d.uuid) {
            let nits = value * settings(d).maxNits
            for other in displays where other.id != d.id && group.members.contains(other.uuid) {
                let v = group.matchNits ? nits / max(1, settings(other).maxNits) : value
                setBrightness(other, v, propagate: false)
            }
        }
    }

    // MARK: Image (gamma)

    func applyImage(_ d: Display) {
        let adjustments = settings(d).adjustments
        let dim = softwareDim[d.id] ?? 1
        if adjustments.isNeutral && dim >= 0.999 {
            // A restore resets every display, so re-apply the others afterwards.
            CGDisplayRestoreColorSyncSettings()
            for other in displays where other.id != d.id { applyImageOnly(other) }
        } else {
            applyImageOnly(d)
        }
    }

    private func applyImageOnly(_ d: Display) {
        let adjustments = settings(d).adjustments
        let dim = softwareDim[d.id] ?? 1
        guard !(adjustments.isNeutral && dim >= 0.999) else { return }
        Gamma.apply(d.id, adjustments: adjustments, dim: dim)
    }

    func applyImageAll() {
        CGDisplayRestoreColorSyncSettings()
        displays.forEach(applyImageOnly)
    }

    func setAdjustments(_ d: Display, _ a: ImageAdjustments) {
        update(d) { $0.adjustments = a }
        applyImage(d)
        for group in config.groups where group.syncAdjustments && group.members.contains(d.uuid) {
            for other in displays where other.id != d.id && group.members.contains(other.uuid) {
                update(other) { $0.adjustments = a }
                applyImage(other)
            }
        }
    }

    // MARK: XDR / HDR boost

    func applyXDR(_ d: Display) {
        xdr.set(d, amount: settings(d).xdrBoost)
    }

    func setXDR(_ d: Display, _ amount: Double) {
        update(d) { $0.xdrBoost = max(0, min(1, amount)) }
        applyXDR(d)
    }

    // MARK: DDC hardware controls

    func setVolume(_ d: Display, _ value: Double) {
        let v = max(0, min(1, value))
        hardware[d.id, default: .init()].volume = v
        ddc[d.id]?.writeAsync(.volume, Int((v * 100).rounded()))
    }

    func stepVolume(_ d: Display, up: Bool) {
        setVolume(d, (hardware[d.id]?.volume ?? 0.5) + (up ? 0.0625 : -0.0625))
        OSD.shared.show(kind: .volume, value: hardware[d.id]?.volume ?? 0, on: d)
    }

    func toggleMute(_ d: Display) {
        let muted = !(hardware[d.id]?.muted ?? false)
        hardware[d.id, default: .init()].muted = muted
        ddc[d.id]?.writeAsync(.mute, muted ? 1 : 2)
        OSD.shared.show(kind: .volume, value: muted ? 0 : hardware[d.id]?.volume ?? 0, on: d)
    }

    func setContrast(_ d: Display, _ value: Double) {
        let v = max(0, min(1, value))
        hardware[d.id, default: .init()].contrast = v
        ddc[d.id]?.writeAsync(.contrast, Int((v * 100).rounded()))
    }

    func setInput(_ d: Display, _ code: Int) {
        hardware[d.id, default: .init()].input = code
        ddc[d.id]?.writeAsync(.inputSource, code)
        log("ddc", "\(d.name) input → \(DDCInput.name(code))")
    }

    /// Puts one display to sleep (DDC power standby) without touching the others.
    func sleepDisplay(_ d: Display) {
        if let channel = ddc[d.id] {
            channel.writeAsync(.power, 4)
            log("ddc", "\(d.name) → standby")
        } else {
            setBrightness(d, 0, propagate: false)
            log("display", "\(d.name) dimmed to black (no DDC power control)")
        }
    }
}

enum DDCInput {
    static let common: [(Int, String)] = [
        (0x0F, "DisplayPort 1"), (0x10, "DisplayPort 2"), (0x11, "HDMI 1"), (0x12, "HDMI 2"),
        (0x1B, "USB-C"), (0x19, "USB-C 2"), (0x01, "VGA"), (0x03, "DVI")
    ]
    static func name(_ code: Int) -> String { common.first { $0.0 == code }?.1 ?? String(format: "Input 0x%02X", code) }
}
