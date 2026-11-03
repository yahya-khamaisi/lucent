import AppKit
import SwiftUI

enum Page: Hashable {
    case onboarding, main, display, image, pip
    case settings, virtual, arrange, groups, keys, tvs, automation, overrides, diagnostics, permissions, about
}

/// Simple push/pop navigation inside the one menu-bar panel. No windows.
final class Navigator: ObservableObject {
    @Published var stack: [Page]
    init(_ start: Page) { stack = [start] }
    var current: Page { stack.last ?? .main }
    func push(_ p: Page) { withAnimation(.snappy(duration: 0.25)) { stack.append(p) } }
    func pop() { withAnimation(.snappy(duration: 0.25)) { if stack.count > 1 { stack.removeLast() } } }
    func reset(_ p: Page) { withAnimation(.snappy(duration: 0.25)) { stack = [p] } }
}

struct PanelView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var nav: Navigator

    init(initialPage: Page? = nil) {
        _nav = StateObject(wrappedValue: Navigator(initialPage ?? (Onboarding.isComplete ? .main : .onboarding)))
    }

    var body: some View {
        Group {
            switch nav.current {
            case .onboarding: OnboardingPage { Onboarding.isComplete = true; nav.reset(.main) }
            case .main: MainPage()
            case .display: DisplayPage()
            case .image: ImagePage()
            case .pip: PiPPage()
            case .settings: SettingsPage()
            case .virtual: VirtualPage()
            case .arrange: ArrangePage()
            case .groups: GroupsPage()
            case .keys: KeysPage()
            case .tvs: TVsPage()
            case .automation: AutomationPage()
            case .overrides: OverridesPage()
            case .diagnostics: DiagnosticsPage()
            case .permissions: PermissionsPage()
            case .about: AboutPage()
            }
        }
        .id(nav.current)
        .transition(.opacity)
        .environmentObject(nav)
        .frame(width: Metrics.width)
        .focusEffectDisabled()
    }
}

// MARK: - Main page

struct MainPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator

    var body: some View {
        PageScroll {
            header
            if model.displays.count > 1 { displayPicker }
            if let d = model.selected {
                sliders(d)
                toggles(d)
                rows(d)
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Lucent").font(.system(size: 13, weight: .semibold))
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.displays.count > 1 {
                Toggle("All Displays", isOn: $model.config.combineAllBrightness)
                    .toggleStyle(.button)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .help("Move every display's brightness together")
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 32)
    }

    private var summary: String {
        let virtual = model.displays.filter(\.isVirtual).count
        let n = model.displays.count
        return "\(n) display\(n == 1 ? "" : "s")" + (virtual > 0 ? " · \(virtual) virtual" : "")
    }

    private var displayPicker: some View {
        Picker("Display", selection: Binding(get: { model.selected?.id ?? 0 }, set: { model.selectedID = $0 })) {
            ForEach(model.displays) { d in Text(d.shortName).tag(d.id) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
    }

    private func sliders(_ d: Display) -> some View {
        let resolutions = Array(model.flexibleTarget(d).resolutions.reversed())
        return Module(padded: true) {
            VStack(spacing: 10) {
                WideSlider(title: "Brightness", symbol: "sun.max.fill",
                           valueLabel: percentLabel(model.brightness[d.id] ?? 1),
                           value: Binding(get: { model.brightness[d.id] ?? 1 }, set: { model.setBrightness(d, $0) }))
                if d.edrHeadroom > 1.01 {
                    let boost = model.settings(d).xdrBoost
                    WideSlider(title: "XDR Boost", symbol: "bolt.fill",
                               valueLabel: boost < 0.01 ? "Off" : "\(Int(500 * (1 + (Double(d.boostHeadroom) - 1) * boost))) nits",
                               value: Binding(get: { boost }, set: { model.setXDR(d, $0) }))
                }
                if resolutions.count > 1, let current = model.flexibleTarget(d).current {
                    let index = Double(resolutions.firstIndex { $0.key == current.key } ?? 0)
                    let max = Double(resolutions.count - 1)
                    ResolutionSlider(resolutions: resolutions, index: index, max: max, current: current) { key in
                        _ = model.setResolution(d, key: key)
                    }
                }
                if let volume = model.hardware[d.id]?.volume {
                    WideSlider(title: "Volume", symbol: "speaker.wave.2.fill", valueLabel: percentLabel(volume),
                               value: Binding(get: { volume }, set: { model.setVolume(d, $0) }))
                }
            }
        }
    }

    private func toggles(_ d: Display) -> some View {
        let s = model.settings(d)
        let hidpi = model.flexibleTarget(d).current?.isHiDPI ?? false
        return Module(padded: true) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 10) {
                ToggleTile(symbol: "sparkles", title: "HiDPI", isOn: hidpi || s.flexibleHiDPI) {
                    if d.isBuiltin || d.isVirtual { toggleHiDPIMode(d) } else { model.setFlexibleHiDPI(d, !s.flexibleHiDPI) }
                }
                ToggleTile(symbol: "a.circle", title: "Auto", isOn: model.config.autoBrightnessSync,
                           enabled: model.displays.contains(where: \.isBuiltin) && model.displays.count > 1) {
                    model.setAutoBrightnessSync(!model.config.autoBrightnessSync)
                }
                ToggleTile(symbol: "rectangle.topthird.inset.filled", title: "Notch", isOn: d.hasNotch && model.notchShown(d), enabled: d.hasNotch) {
                    model.setNotchShown(d, !model.notchShown(d))
                }
                ToggleTile(symbol: "moon.fill", title: "Night Shift", isOn: model.nightShift, enabled: PrivateAPI.nightShiftAvailable) {
                    model.setNightShift(!model.nightShift)
                }
                ToggleTile(symbol: "circle.lefthalf.filled", title: "Dim to Black", isOn: s.dimToBlack) {
                    model.update(d) { $0.dimToBlack.toggle() }
                    model.readBrightness(d)
                }
                ToggleTile(symbol: "waveform.path", title: "Anti-PWM", isOn: model.antiPWM) {
                    model.setAntiPWM(!model.antiPWM)
                }
                ToggleTile(symbol: "rectangle.on.rectangle", title: "Mirror", isOn: model.isMirroring, enabled: model.displays.count > 1) {
                    model.setMirrorAll(!model.isMirroring)
                }
                ToggleTile(symbol: "lock.fill", title: "Protect", isOn: s.protect) {
                    model.setProtect(d, !s.protect)
                }
            }
        }
    }

    /// Built-in and virtual screens: swap between the HiDPI and low-resolution version of a size.
    private func toggleHiDPIMode(_ d: Display) {
        guard let current = d.current else { return }
        let others = d.allModes.filter { $0.isHiDPI != current.isHiDPI }
        let match = others.first { $0.width == current.width && $0.height == current.height }
            ?? others.min { abs($0.width - current.width) < abs($1.width - current.width) }
        if let match { model.setMode(d, match) }
    }

    private func rows(_ d: Display) -> some View {
        let target = model.flexibleTarget(d)
        let group = model.config.groups.first { $0.members.contains(d.uuid) }?.name ?? "None"
        return Module {
            NavRow(symbol: "display", tint: .blue, title: "Display Mode",
                   value: target.current.map { "\($0.width) × \($0.height)" } ?? "") { nav.push(.display) }
            NavRow(symbol: "arrow.clockwise", tint: .indigo, title: "Refresh Rate",
                   value: d.current.map { "\($0.refreshLabel) Hz" } ?? "") { nav.push(.display) }
            NavRow(symbol: "paintpalette.fill", tint: .pink, title: "Color Profile",
                   value: model.currentProfileName(d) ?? "") { nav.push(.display) }
            NavRow(symbol: "slider.horizontal.3", tint: .orange, title: "Image Adjustments",
                   value: model.settings(d).adjustments.isNeutral ? "Default" : "Custom") { nav.push(.image) }
            NavRow(symbol: "rotate.right", tint: .teal, title: "Rotation", value: "\(d.rotation)°") { nav.push(.display) }
            NavRow(symbol: "pip", tint: .green, title: "Picture in Picture",
                   value: PiP.shared.isOpen ? PiP.shared.sourceName : "Off") { nav.push(.pip) }
            NavRow(symbol: "rectangle.on.rectangle.angled", tint: .cyan, title: "Arrange & Connect",
                   value: model.disabledByLucent.isEmpty ? "" : "\(model.disabledByLucent.count) off") { nav.push(.arrange) }
            NavRow(symbol: "square.stack.3d.up.fill", tint: .purple, title: "Display Group", value: group) { nav.push(.groups) }
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(symbol: "rectangle.3.group", label: "Arrange Displays") { nav.push(.arrange) }
            FooterButton(symbol: "rectangle.dashed.badge.record", label: "Virtual Screens") { nav.push(.virtual) }
            FooterButton(symbol: "camera.filters", label: "Video Filter Window") {
                if let d = Keys.displayUnderPointer() { PiP.shared.open(display: d.id) }
                nav.push(.pip)
            }
            FooterButton(symbol: "terminal", label: "Console") { nav.push(.diagnostics) }
            Spacer()
            FooterButton(symbol: "gearshape", label: "Settings") { nav.push(.settings) }
                .keyboardShortcut(",", modifiers: .command)
            FooterButton(symbol: "power", label: "Quit Lucent") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .frame(height: 30)
    }
}

/// Discrete slider over the resolution list, styled like the other wide sliders.
struct ResolutionSlider: View {
    let resolutions: [DisplayMode]
    let index: Double
    let max: Double
    let current: DisplayMode
    let commit: (String) -> Void
    @State private var dragging: Double?

    var body: some View {
        let shown = Int((dragging ?? index).rounded())
        let mode = resolutions[Swift.max(0, Swift.min(resolutions.count - 1, shown))]
        WideSlider(title: "Resolution" + (mode.isHiDPI ? " · HiDPI" : ""), symbol: "arrow.up.left.and.arrow.down.right",
                   valueLabel: "\(mode.width) × \(mode.height)",
                   value: Binding(get: { (dragging ?? index) / Swift.max(1, max) },
                                  set: { dragging = ($0 * max).rounded() }),
                   onCommit: {
                       if let d = dragging, Int(d) != Int(index) { commit(resolutions[Int(d)].key) }
                       dragging = nil
                   })
    }
}

/// Borderless 30pt icon button with a tooltip and spoken label.
struct FooterButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}
