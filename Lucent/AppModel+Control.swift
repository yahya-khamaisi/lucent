import AppKit
import ColorSync
import CoreGraphics
import IOKit

/// Modes, rotation, arrangement, connection, protection and virtual screens.
extension AppModel {
    // MARK: Modes

    @discardableResult
    func setMode(_ d: Display, _ mode: DisplayMode, remember: Bool = true) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, d.id, mode.mode, nil)
        let ok = CGCompleteDisplayConfiguration(config, .permanently) == .success
        log("mode", "\(d.name) → \(mode.sizeLabel)\(mode.isHiDPI ? " HiDPI" : "") @ \(mode.refreshLabel) Hz" + (ok ? "" : " failed"))
        if ok, remember, settings(d).protect { update(d) { $0.protectedMode = mode.id } }
        return ok
    }

    func setResolution(_ d: Display, key: String) -> Bool {
        let target = flexibleTarget(d)
        let rate = target.current?.refresh ?? 60
        let candidates = target.allModes.filter { $0.key == key }
        guard let mode = candidates.min(by: { abs($0.refresh - rate) < abs($1.refresh - rate) }) else { return false }
        return setMode(target, mode)
    }

    func setRefresh(_ d: Display, _ hz: Double) -> Bool {
        guard let current = d.current,
              let mode = d.allModes.filter({ $0.key == current.key }).min(by: { abs($0.refresh - hz) < abs($1.refresh - hz) }) else { return false }
        return setMode(d, mode)
    }

    /// Moves to the next favourite (or next resolution) — bound to a keyboard shortcut.
    func cycleResolution(_ d: Display, forward: Bool = true) {
        let target = flexibleTarget(d)
        let favorites = settings(d).favorites
        let list = favorites.isEmpty ? target.resolutions.map(\.key) : favorites
        guard !list.isEmpty else { return }
        let i = list.firstIndex(of: target.current?.key ?? "") ?? -1
        let next = list[(i + (forward ? 1 : list.count - 1) + list.count) % list.count]
        _ = setResolution(d, key: next)
    }

    func toggleFavorite(_ d: Display, key: String) {
        update(d) { s in
            if let i = s.favorites.firstIndex(of: key) { s.favorites.remove(at: i) } else { s.favorites.append(key) }
        }
    }

    // MARK: Notch (built-in)

    /// Notched panels offer each width twice: full height (menu bar beside the notch) and
    /// a shorter one that letterboxes it away.
    func notchShown(_ d: Display) -> Bool {
        guard let current = d.current else { return false }
        let heights = d.allModes.filter { $0.width == current.width && $0.isHiDPI == current.isHiDPI }.map(\.height)
        return current.height == heights.max()
    }

    func setNotchShown(_ d: Display, _ show: Bool) {
        guard let current = d.current else { return }
        let options = d.allModes.filter { $0.width == current.width && $0.isHiDPI == current.isHiDPI }
        let heights = Set(options.map(\.height))
        guard heights.count > 1, let h = show ? heights.max() : heights.min(),
              let mode = options.filter({ $0.height == h }).min(by: { abs($0.refresh - current.refresh) < abs($1.refresh - current.refresh) }) else { return }
        setMode(d, mode)
    }

    // MARK: Rotation, main display, mirroring, arrangement

    func setRotation(_ d: Display, _ degrees: Int) {
        let ok = PrivateAPI.setRotation(d.id, degrees: degrees)
        log("display", "\(d.name) rotation → \(degrees)°" + (ok ? "" : " not supported"))
        if ok, settings(d).protect { update(d) { $0.protectedRotation = degrees } }
    }

    func setMain(_ d: Display) {
        let origin = d.bounds.origin
        configure { config in
            for other in displays {
                CGConfigureDisplayOrigin(config, other.id, Int32(other.bounds.minX - origin.x), Int32(other.bounds.minY - origin.y))
            }
        }
        log("display", "\(d.name) is now the main display")
    }

    func setOrigin(_ d: Display, _ point: CGPoint) {
        configure { CGConfigureDisplayOrigin($0, d.id, Int32(point.x), Int32(point.y)) }
        if settings(d).protect { update(d) { $0.protectedOrigin = [Int(point.x), Int(point.y)] } }
    }

    var isMirroring: Bool { displays.contains { $0.mirrorOf != nil } }

    func setMirrorAll(_ on: Bool) {
        guard let main = displays.first(where: \.isMain) else { return }
        configure { config in
            for d in displays where d.id != main.id {
                CGConfigureDisplayMirrorOfDisplay(config, d.id, on ? main.id : kCGNullDirectDisplay)
            }
        }
        log("display", on ? "Mirroring all displays" : "Mirroring off")
    }

    func setMirror(_ d: Display, of master: CGDirectDisplayID?) {
        configure { CGConfigureDisplayMirrorOfDisplay($0, d.id, master ?? kCGNullDirectDisplay) }
    }

    private func configure(_ body: (CGDisplayConfigRef?) -> Void) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        body(config)
        CGCompleteDisplayConfiguration(config, .permanently)
    }

    // MARK: Connection

    func disconnect(_ d: Display) {
        guard displays.count > 1 else { log("display", "Can't disconnect the only display"); return }
        if d.isVirtual, let config = config.virtualScreens.first(where: { virtual.displayID($0.id) == d.id }) {
            setVirtual(config.id, connected: false)
            return
        }
        if PrivateAPI.setDisplayEnabled(d.id, false) {
            disabledByLucent[d.id] = d.name
            log("display", "\(d.name) disconnected")
        } else {
            log("display", "\(d.name) could not be disconnected")
        }
    }

    func reconnect(_ id: CGDirectDisplayID) {
        PrivateAPI.setDisplayEnabled(id, true)
        if let name = disabledByLucent.removeValue(forKey: id) { log("display", "\(name) reconnected") }
    }

    func reconnectAll() {
        for id in disabledByLucent.keys { reconnect(id) }
    }

    /// Keeps only `d` on; everything else is disconnected until "Reconnect All".
    func solo(_ d: Display) {
        for other in displays where other.id != d.id { disconnect(other) }
    }

    func applyConnectionRules() {
        guard config.rules.disconnectBuiltInWithExternal else { return }
        let hasExternal = displays.contains { !$0.isBuiltin && !$0.isVirtual }
        if hasExternal, let builtin = displays.first(where: \.isBuiltin) {
            disconnect(builtin)
        } else if !hasExternal {
            reconnectAll()
        }
    }

    // MARK: Protection

    func setProtect(_ d: Display, _ on: Bool) {
        update(d) { s in
            s.protect = on
            s.protectedMode = on ? d.current?.id : nil
            s.protectedOrigin = on ? [Int(d.bounds.minX), Int(d.bounds.minY)] : nil
            s.protectedRotation = on ? d.rotation : nil
        }
        log("protect", "\(d.name) protection \(on ? "on" : "off")")
    }

    func snapshotProtection() {
        for d in displays where settings(d).protect && settings(d).protectedMode == nil { setProtect(d, true) }
    }

    func scheduleProtection() {
        protectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.enforceProtection() }
        protectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func enforceProtection() {
        let rules = config.protection
        for d in displays {
            let s = settings(d)
            guard s.protect else { continue }
            if (rules.resolution || rules.refreshRate), let want = s.protectedMode, let current = d.current, current.id != want {
                // Mode ids look like "2560x1440@2x@60": the key is everything before the last "@".
                let wantKey = want.components(separatedBy: "@").dropLast().joined(separator: "@")
                let sameSize = current.key == wantKey
                let needs = (rules.resolution && !sameSize) || (rules.refreshRate && sameSize)
                if needs, let mode = d.allModes.first(where: { $0.id == want }) ?? d.allModes.first(where: { $0.key == wantKey }) {
                    log("protect", "\(d.name): restoring \(mode.sizeLabel) @ \(mode.refreshLabel) Hz")
                    setMode(d, mode, remember: false)
                }
            }
            if rules.arrangement, let o = s.protectedOrigin, o.count == 2,
               Int(d.bounds.minX) != o[0] || Int(d.bounds.minY) != o[1], displays.count > 1 {
                log("protect", "\(d.name): restoring arrangement")
                configure { CGConfigureDisplayOrigin($0, d.id, Int32(o[0]), Int32(o[1])) }
            }
            if rules.rotation, let r = s.protectedRotation, r != d.rotation {
                log("protect", "\(d.name): restoring rotation \(r)°")
                _ = PrivateAPI.setRotation(d.id, degrees: r)
            }
            if rules.colorProfile, let profile = s.colorProfile, currentProfileName(d) != URL(fileURLWithPath: profile).deletingPathExtension().lastPathComponent {
                setColorProfile(d, path: profile)
            }
        }
    }

    // MARK: Virtual screens

    func addVirtual(name: String, width: Int, height: Int, hiDPI: Bool = true, refresh: Double = 60) {
        var c = VirtualScreenConfig()
        c.name = name
        c.width = width
        c.height = height
        c.hiDPI = hiDPI
        c.refreshRate = refresh
        config.virtualScreens.append(c)
        setVirtual(c.id, connected: true)
    }

    func updateVirtual(_ c: VirtualScreenConfig) {
        guard let i = config.virtualScreens.firstIndex(where: { $0.id == c.id }) else { return }
        let old = config.virtualScreens[i]
        config.virtualScreens[i] = c
        let needsReconnect = old.width != c.width || old.height != c.height || old.hiDPI != c.hiDPI
            || old.refreshRate != c.refreshRate || old.name != c.name
        if needsReconnect && virtual.isConnected(c.id) {
            virtual.disconnect(c.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.setVirtual(c.id, connected: true) }
        }
    }

    func setVirtual(_ id: UUID, connected: Bool) {
        guard let i = config.virtualScreens.firstIndex(where: { $0.id == id }) else { return }
        config.virtualScreens[i].enabled = connected
        let c = config.virtualScreens[i]
        if connected {
            if virtual.connect(c) != nil { log("virtual", "“\(c.name)” connected \(c.width)×\(c.height)") }
            else { log("virtual", "“\(c.name)” could not be created") }
        } else {
            virtual.disconnect(id)
            log("virtual", "“\(c.name)” disconnected")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refreshDisplays() }
    }

    func removeVirtual(_ id: UUID) {
        virtual.disconnect(id)
        config.virtualScreens.removeAll { $0.id == id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refreshDisplays() }
    }

    func virtualConfig(for d: Display) -> VirtualScreenConfig? {
        config.virtualScreens.first { virtual.displayID($0.id) == d.id }
    }

    // MARK: Flexible HiDPI (real display mirrors a HiDPI virtual screen)

    /// The display whose modes the resolution list should show: the HiDPI helper when on.
    func flexibleTarget(_ d: Display) -> Display {
        guard settings(d).flexibleHiDPI,
              let helper = config.virtualScreens.first(where: { $0.mirrorOf == d.uuid }),
              let id = virtual.displayID(helper.id), let target = display(id) else { return d }
        return target
    }

    func setFlexibleHiDPI(_ d: Display, _ on: Bool) {
        update(d) { $0.flexibleHiDPI = on }
        if on {
            let native = d.allModes.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
            var helper = VirtualScreenConfig()
            helper.name = "\(d.name) HiDPI"
            helper.width = native?.pixelWidth ?? Int(d.bounds.width)
            helper.height = native?.pixelHeight ?? Int(d.bounds.height)
            helper.refreshRate = d.current?.refresh ?? 60
            helper.mirrorOf = d.uuid
            config.virtualScreens.append(helper)
            applyFlexibleHiDPI()
        } else {
            for helper in config.virtualScreens where helper.mirrorOf == d.uuid { removeVirtual(helper.id) }
            setMirror(d, of: nil)
        }
        log("hidpi", "\(d.name) flexible HiDPI \(on ? "on" : "off")")
    }

    func applyFlexibleHiDPI() {
        for helper in config.virtualScreens {
            guard let uuid = helper.mirrorOf, let real = displays.first(where: { $0.uuid == uuid }),
                  settings(real).flexibleHiDPI else { continue }
            guard let id = virtual.connect(helper) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.setMirror(real, of: id)
                self.refreshDisplays()
            }
        }
    }

    // MARK: Colour profiles and presets

    static func installedProfiles() -> [URL] {
        let dirs = ["/Library/ColorSync/Profiles", "/Library/ColorSync/Profiles/Displays",
                    "/System/Library/ColorSync/Profiles", NSHomeDirectory() + "/Library/ColorSync/Profiles"]
        return dirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".icc") || $0.hasSuffix(".icm") }
                .map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func currentProfileName(_ d: Display) -> String? {
        d.screen?.colorSpace?.localizedName
    }

    func setColorProfile(_ d: Display, path: String) {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(d.id)?.takeRetainedValue() else { return }
        let info: [String: Any] = [
            kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String: URL(fileURLWithPath: path),
            kColorSyncProfileUserScope.takeUnretainedValue() as String: kCFPreferencesCurrentUser as String
        ]
        let ok = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, info as CFDictionary)
        update(d) { $0.colorProfile = path }
        log("color", "\(d.name) profile → \(URL(fileURLWithPath: path).lastPathComponent)" + (ok ? "" : " failed"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.objectWillChange.send() }
    }

    // MARK: Night Shift, dithering

    func setNightShift(_ on: Bool) {
        PrivateAPI.setNightShift(on)
        nightShift = on
    }

    /// Turns temporal dithering off on the built-in panel's framebuffer, which reduces
    /// shimmer for people sensitive to it. Needs the framebuffer to accept the property.
    func setAntiPWM(_ on: Bool) {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var ok = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            ok = IORegistryEntrySetCFProperty(service, "enableDither" as CFString, (!on) as CFBoolean) == KERN_SUCCESS || ok
            IOObjectRelease(service)
        }
        antiPWM = ok ? on : false
        log("display", ok ? "Temporal dithering \(on ? "off" : "on")" : "This Mac doesn't allow changing dithering")
    }
}
