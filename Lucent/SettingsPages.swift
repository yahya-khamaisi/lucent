import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        PageScroll {
            PageHeader(title: "Settings", back: nav.pop)
            Module {
                ToggleRow(title: "Open at Login", isOn: Binding(get: { openAtLogin }, set: { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    openAtLogin = SMAppService.mainApp.status == .enabled
                }))
                Row(title: "Menu Bar Icon") {
                    Picker("Menu Bar Icon", selection: $model.config.menuIcon) {
                        ForEach(MenuIcon.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }
            Module {
                NavRow(symbol: "rectangle.dashed", tint: .indigo, title: "Virtual Screens",
                       value: "\(model.config.virtualScreens.filter { $0.mirrorOf == nil }.count)") { nav.push(.virtual) }
                NavRow(symbol: "square.stack.3d.up.fill", tint: .purple, title: "Display Groups",
                       value: "\(model.config.groups.count)") { nav.push(.groups) }
                NavRow(symbol: "lock.fill", tint: .teal, title: "Arrangement & Protection") { nav.push(.arrange) }
                NavRow(symbol: "keyboard", tint: .orange, title: "Keys, Shortcuts & OSD") { nav.push(.keys) }
                NavRow(symbol: "slider.horizontal.3", tint: .pink, title: "Image Adjustments") { nav.push(.image) }
                NavRow(symbol: "tv", tint: .green, title: "TVs & Receivers", value: "\(model.config.tvs.count)") { nav.push(.tvs) }
                NavRow(symbol: "terminal.fill", tint: .gray, title: "Automation") { nav.push(.automation) }
                NavRow(symbol: "checkmark.shield.fill", tint: .gray, title: "Overrides (EDID)") { nav.push(.overrides) }
                NavRow(symbol: "waveform.path.ecg", tint: .cyan, title: "Diagnostics & Console") { nav.push(.diagnostics) }
                NavRow(symbol: "hand.raised.fill", tint: .blue, title: "Permissions", value: Permissions.summary) { nav.push(.permissions) }
                NavRow(symbol: "info.circle.fill", tint: .gray, title: "About Lucent") { nav.push(.about) }
            }
            Text("Lucent \(Bundle.main.version) · free, no account, no subscription")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 30)
        }
    }
}

struct KeysPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator

    var body: some View {
        PageScroll {
            PageHeader(title: "Keys, Shortcuts & OSD", back: nav.pop)
            Module {
                ToggleRow(title: "Brightness Keys for All Displays", subtitle: Keys.accessibilityGranted ? "Acts on the display under the pointer" : "Needs Accessibility",
                          isOn: Binding(get: { model.config.keys.mediaKeys }, set: { model.config.keys.mediaKeys = $0; Keys.shared.restart() }))
                ToggleRow(title: "Global Shortcuts", isOn: Binding(get: { model.config.keys.shortcutsEnabled },
                                                                   set: { model.config.keys.shortcutsEnabled = $0; Keys.shared.installShortcuts() }))
                PickerRow(title: "Step", selection: $model.config.keys.step,
                          options: [(3.125, "Fine (32 steps)"), (6.25, "Normal (16 steps)"), (12.5, "Coarse (8 steps)")])
            }
            VStack(alignment: .leading, spacing: 4) {
                ModuleHeader("Shortcuts")
                Module {
                    ForEach(Keys.shortcutList, id: \.0) { keys, action in
                        Row(title: action) { Text(keys).font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ModuleHeader("On-screen display")
                Module {
                    PickerRow(title: "Style", selection: $model.config.osd,
                              options: [(.modern, "Modern"), (.classic, "Classic"), (.off, "Off")])
                    ToggleRow(title: "Share with Other Apps", subtitle: "Notch and island apps can show it", isOn: $model.config.automation.osdBroadcast)
                }
                ButtonBar(buttons: [("Preview", false, {
                    if let d = model.selected { OSD.shared.show(kind: .brightness, value: model.brightness[d.id] ?? 0.5, on: d) }
                })])
            }
        }
    }
}

struct TVsPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @ObservedObject var tvs = TVs.shared
    @State private var kind = TVKind.lg
    @State private var host = ""

    var body: some View {
        PageScroll {
            PageHeader(title: "TVs & Receivers", back: nav.pop) {
                Button(tvs.scanning ? "Scanning…" : "Scan") { tvs.scan() }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).disabled(tvs.scanning)
            }
            if !model.config.tvs.isEmpty {
                Module {
                    ForEach(model.config.tvs) { tv in
                        VStack(spacing: 6) {
                            HStack(spacing: 10) {
                                IconTile(symbol: tv.kind == .yamaha ? "hifispeaker.fill" : "tv", tint: tint(tv.kind))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(tv.name).fontWeight(.medium).lineLimit(1)
                                    Text("\(tv.kind.rawValue) · \(tvs.status[tv.id] ?? tv.host)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button { tvs.remove(tv) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("Remove").accessibilityLabel("Remove \(tv.name)")
                            }
                            HStack(spacing: 6) {
                                control("speaker.minus.fill", "Volume Down") { tvs.send(.volumeDown, to: tv) }
                                control("speaker.plus.fill", "Volume Up") { tvs.send(.volumeUp, to: tv) }
                                control("speaker.slash.fill", "Mute") { tvs.send(.mute, to: tv) }
                                Menu {
                                    ForEach(["HDMI1", "HDMI2", "HDMI3", "HDMI4"], id: \.self) { i in Button(i) { tvs.send(.input(i), to: tv) } }
                                } label: { Image(systemName: "rectangle.portrait.and.arrow.forward") }
                                .menuStyle(.button).buttonStyle(.bordered).buttonBorderShape(.capsule).menuIndicator(.hidden).help("Input")
                                control("power", "Power Off") { tvs.send(.powerOff, to: tv) }
                            }
                        }
                        .padding(.horizontal, Metrics.inset)
                        .padding(.vertical, 8)
                    }
                }
            }
            if !tvs.found.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ModuleHeader("Found on this network")
                    Module {
                        ForEach(tvs.found) { tv in
                            Row(title: tv.name, subtitle: "\(tv.kind.rawValue) · \(tv.host)") {
                                Button("Add") { tvs.add(tv) }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ModuleHeader("Add manually")
                Module {
                    PickerRow(title: "Type", selection: $kind, options: TVKind.allCases.map { ($0, $0.rawValue) })
                    Row(title: "Address") {
                        TextField("192.168.1.20", text: $host).textFieldStyle(.roundedBorder).frame(width: 150)
                    }
                }
                ButtonBar(buttons: [("Add", false, {
                    guard !host.isEmpty else { return }
                    tvs.add(TVDevice(kind: kind, name: kind.rawValue, host: host))
                    host = ""
                })])
            }
        }
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(maxWidth: .infinity) }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).help(label).accessibilityLabel(label)
    }

    private func tint(_ k: TVKind) -> Color {
        switch k { case .lg: .pink; case .samsung: .blue; case .philips: .teal; case .yamaha: .gray }
    }
}

struct AutomationPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @ObservedObject var automation = Automation.shared

    var body: some View {
        PageScroll {
            PageHeader(title: "Automation", back: nav.pop)
            Module {
                Row(title: "Command-Line Tool", subtitle: automation.cliInstalled ? Automation.cliPath : "Not installed") {
                    Button(automation.cliInstalled ? "Reinstall" : "Install") { automation.installCLI() }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                }
                ToggleRow(title: "URL Scheme", subtitle: "lucent://set?display=main&brightness=40", isOn: $model.config.automation.urlScheme)
                ToggleRow(title: "Local HTTP Server", subtitle: automation.httpRunning ? "127.0.0.1:\(model.config.automation.httpPort)" : "Off",
                          isOn: Binding(get: { model.config.automation.httpServer }, set: { model.config.automation.httpServer = $0; automation.setHTTP($0) }))
                Row(title: "Shortcuts", subtitle: "7 actions in the Shortcuts app") {
                    Button("Open") { NSWorkspace.shared.open(URL(string: "shortcuts://")!) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                }
            }
            if let d = model.selected {
                let events = Binding(get: { model.settings(d).events }, set: { v in model.update(d) { $0.events = v } })
                VStack(alignment: .leading, spacing: 4) {
                    ModuleHeader("When \(d.name)…")
                    Module {
                        eventRow("Connects", events.onConnect)
                        eventRow("Disconnects", events.onDisconnect)
                        eventRow("Sleeps", events.onSleep)
                        eventRow("Wakes", events.onWake)
                    }
                }
                Text("A shell command, “lucent …”, or “shortcut: Name”.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, Metrics.inset)
            }
            CodeBlock(text: "lucent set -n builtin --brightness 40%\nlucent set -n \"DELL*\" --resolution 2560x1440\nopen \"lucent://set?display=main&xdr=50\"")
        }
    }

    private func eventRow(_ title: String, _ text: Binding<String>) -> some View {
        Row(title: title) {
            TextField("Command", text: text).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)).frame(width: 190)
        }
    }
}

struct OverridesPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @State private var name = ""
    @State private var sizes = "1920x1080, 2304x1296"
    @State private var edid: Data?
    @State private var importing = false
    @State private var message = ""

    var body: some View {
        PageScroll {
            PageHeader(title: "Overrides (EDID)", back: nav.pop)
            if let d = model.selected {
                let current = EDID.read(d)
                Module {
                    Row(title: "Display", subtitle: current.map(EDID.summary) ?? "EDID not readable") { Text(d.name).foregroundStyle(.secondary) }
                    Row(title: "Override") { Text(EDID.hasOverride(d) ? "Installed" : "None").foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ModuleHeader("New override")
                    Module {
                        Row(title: "Name") { TextField(d.name, text: $name).textFieldStyle(.roundedBorder).frame(width: 160) }
                        Row(title: "HiDPI Sizes") { TextField("1920x1080, …", text: $sizes).textFieldStyle(.roundedBorder).frame(width: 160) }
                        Row(title: "Replacement EDID", subtitle: edid.map(EDID.summary)) {
                            Button(edid == nil ? "Choose…" : "Change…") { importing = true }.buttonStyle(.borderless)
                        }
                    }
                }
                ButtonBar(buttons: [
                    ("Export EDID", false, { EDID.export(d) }),
                    ("Install", false, {
                        let list = sizes.split(separator: ",").compactMap { part -> (Int, Int)? in
                            let n = part.lowercased().trimmingCharacters(in: .whitespaces).split(separator: "x").compactMap { Int($0) }
                            return n.count == 2 ? (n[0], n[1]) : nil
                        }
                        let ok = EDID.writeOverride(d, name: name.isEmpty ? d.name : name, hidpiSizes: list, edid: edid)
                        message = ok ? "Installed. Reconnect the display to apply it." : "Not installed."
                    }),
                    ("Remove", true, { message = EDID.removeOverride(d) ? "Removed." : "Not removed." })
                ])
                if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, Metrics.inset) }
                Text("Overrides live in /Library/Displays and need your administrator password. Apple silicon Macs honour fewer override keys than Intel Macs; Flexible HiDPI works on both.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, Metrics.inset)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { edid = try? Data(contentsOf: url) }
        }
    }
}

struct DiagnosticsPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @State private var command = ""

    var body: some View {
        PageScroll {
            PageHeader(title: "Diagnostics", subtitle: model.selected?.name, back: nav.pop)
            if let d = model.selected {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Metrics.gap), GridItem(.flexible())], spacing: Metrics.gap) {
                    stat("Mode", d.current.map { "\($0.width)×\($0.height)" } ?? "?")
                    stat("Pixels", d.current.map { "\($0.pixelWidth)×\($0.pixelHeight)" } ?? "?")
                    stat("Refresh", "\(d.current?.refreshLabel ?? "?") Hz")
                    stat("EDR Headroom", String(format: "%.1f×", d.edrHeadroom))
                }
                Module {
                    Row(title: "Brightness") { info(model.method(d).rawValue) }
                    Row(title: "Vendor / Product") { info(String(format: "%04X / %04X", d.vendor, d.model)) }
                    Row(title: "Serial") { info("\(d.serial)") }
                    Row(title: "Display ID") { info("\(d.id)") }
                    Row(title: "Modes") { info("\(d.allModes.count) (\(d.allModes.filter(\.isHiDPI).count) HiDPI)") }
                    Row(title: "DDC/CI") { info(model.ddc[d.id] != nil ? "Available" : d.isBuiltin || d.isVirtual ? "Not applicable" : "Not found") }
                    Row(title: "EDID") { info(EDID.read(d).map { "\($0.count) bytes" } ?? "Not readable") }
                }
                ButtonBar(buttons: [
                    ("Export EDID", false, { EDID.export(d) }),
                    ("Re-scan DDC", false, { model.scanDDC(); model.readBrightness(d) }),
                    ("Copy Info", false, {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Command.run(["get", "-n", "\(d.id)"]), forType: .string)
                    })
                ])
            }
            VStack(alignment: .leading, spacing: 4) {
                ModuleHeader("Console")
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(model.log.suffix(120)) { line in
                                Text("\(line.date.formatted(.dateTime.hour().minute().second()))  \(line.category)  \(line.text)")
                                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(white: 0.88))
                                    .frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                            }
                        }
                        .padding(10)
                        .textSelection(.enabled)
                    }
                    .frame(height: 150)
                    .background(Color(white: 0.11), in: .rect(cornerRadius: Metrics.radius, style: .continuous))
                    .onChange(of: model.log.count) { _, _ in if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                TextField("lucent command, e.g. get -n main", text: $command)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                    .onSubmit {
                        let output = Command.run(Command.split(command.hasPrefix("lucent ") ? String(command.dropFirst(7)) : command))
                        output.split(separator: "\n").forEach { model.log("›", String($0)) }
                        command = ""
                    }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, Metrics.inset)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(.quinary, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
    }

    private func info(_ s: String) -> some View {
        Text(s).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
    }
}

@MainActor
enum Permissions {
    static var summary: String {
        let granted = [Keys.accessibilityGranted, PiP.permissionGranted].filter { $0 }.count
        return "\(granted) of 2"
    }

    static func open(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

struct PermissionsPage: View {
    @EnvironmentObject var nav: Navigator
    @State private var tick = 0

    var body: some View {
        PageScroll {
            PageHeader(title: "Permissions", back: nav.pop)
            PermissionList()
            Text("If a switch doesn't update, quit and reopen Lucent.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, Metrics.inset)
        }
    }
}

/// Shared by onboarding and settings.
struct PermissionList: View {
    @State private var refresh = 0
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Module {
            row("Accessibility", "Brightness keys and shortcuts", "accessibility", Keys.accessibilityGranted, tint: .blue) {
                Keys.requestAccessibility(); Permissions.open("Privacy_Accessibility")
            }
            row("Screen Recording", "Picture in Picture and streaming", "record.circle", PiP.permissionGranted, tint: .pink) {
                PiP.requestPermission(); Permissions.open("Privacy_ScreenCapture")
            }
            row("Local Network", "TVs and receivers (asked on first scan)", "network", nil, tint: .green) {
                Permissions.open("Privacy_LocalNetwork")
            }
        }
        .id(refresh)
        .onReceive(timer) { _ in refresh += 1 }
    }

    private func row(_ title: String, _ detail: String, _ symbol: String, _ granted: Bool?, tint: Color, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if granted == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 17)).accessibilityLabel("Granted")
            } else {
                Button(granted == nil ? "Open" : "Allow", action: action)
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
            }
        }
        .padding(.horizontal, Metrics.inset)
        .frame(height: Metrics.tallRow)
    }
}

struct AboutPage: View {
    @EnvironmentObject var nav: Navigator

    var body: some View {
        PageScroll {
            PageHeader(title: "About Lucent", back: nav.pop)
            Module(padded: true) {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    Text("Lucent").font(.system(size: 15, weight: .semibold))
                    Text("Version \(Bundle.main.version)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Every display feature, free. No account, no subscription, no tracking.")
                        .font(.system(size: 12)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
            ButtonBar(buttons: [
                ("Source Code", false, { NSWorkspace.shared.open(URL(string: "https://github.com/yahya-khamaisi/lucent")!) }),
                ("Check for Updates", false, { NSWorkspace.shared.open(URL(string: "https://github.com/yahya-khamaisi/lucent/releases")!) })
            ])
        }
    }
}

extension Bundle {
    var version: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
}
