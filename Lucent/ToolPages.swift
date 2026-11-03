import AppKit
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Picture in Picture

struct PiPPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @ObservedObject var pip = PiP.shared
    @State private var windows: [(CGWindowID, String)] = []
    @State private var streamTarget: CGDirectDisplayID?
    @State private var pickingLUT = false

    var body: some View {
        PageScroll {
            PageHeader(title: "Picture in Picture", back: nav.pop) {
                Toggle("Picture in Picture", isOn: Binding(get: { pip.isOpen }, set: { on in
                    if on, let d = model.selected { pip.open(display: d.id) } else { pip.closeAll() }
                }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            if let error = pip.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor).font(.system(size: 11)).padding(.horizontal, Metrics.inset)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Module {
                Row(title: "Source") {
                    Menu(pip.sourceName) {
                        Section("Displays") {
                            ForEach(model.displays) { d in Button(d.name) { pip.open(display: d.id) } }
                        }
                        Section("Windows") {
                            ForEach(windows, id: \.0) { id, title in Button(title) { pip.open(window: id, title: title) } }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                PickerRow(title: "Frame Rate", selection: $pip.settings.frameRate,
                          options: [(15, "15 fps"), (30, "30 fps"), (60, "60 fps"), (120, "120 fps")])
                PickerRow(title: "Rotation", selection: $pip.settings.rotation,
                          options: [(0, "0°"), (90, "90°"), (180, "180°"), (270, "270°")])
                Row(title: "3D LUT") {
                    Button(pip.settings.lutPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose…") { pickingLUT = true }
                        .buttonStyle(.borderless)
                    if pip.settings.lutPath != nil {
                        Button { pip.settings.lutPath = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove LUT")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ModuleHeader("Video filters")
                Module {
                    ToggleRow(title: "Flip Horizontally", subtitle: "Teleprompter", isOn: $pip.settings.flip)
                    SliderRow(title: "Sharpen", value: $pip.settings.sharpen)
                    SliderRow(title: "Opacity", value: $pip.settings.opacity, range: 0.2...1)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ModuleHeader("Window")
                Module {
                    ToggleRow(title: "Float on Top", isOn: $pip.settings.floatOnTop)
                    ToggleRow(title: "Click-through", isOn: $pip.settings.clickThrough)
                    ToggleRow(title: "Hide from Screenshots", isOn: $pip.settings.hideFromCapture)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ModuleHeader("Stream full screen")
                Module {
                    PickerRow(title: "Show On", selection: $streamTarget,
                              options: [(nil, "Choose")] + model.displays.filter { $0.id != model.selected?.id }.map { ($0.id, $0.name) })
                }
                ButtonBar(buttons: [("Stream \(model.selected?.shortName ?? "Display")", false, {
                    if let s = model.selected, let t = streamTarget { pip.stream(s.id, to: t) }
                })])
                .disabled(streamTarget == nil)
            }
        }
        .task { await loadWindows() }
        .fileImporter(isPresented: $pickingLUT, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]) { result in
            if case .success(let url) = result { pip.settings.lutPath = url.path }
        }
    }

    private func loadWindows() async {
        guard PiP.permissionGranted,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        windows = content.windows
            .filter { $0.isOnScreen && $0.frame.width > 120 && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
            .prefix(20)
            .map { ($0.windowID, [$0.owningApplication?.applicationName, $0.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")) }
    }
}

// MARK: - Virtual screens

struct VirtualPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @State private var selected: UUID?

    var body: some View {
        let screens = model.config.virtualScreens.filter { $0.mirrorOf == nil }
        PageScroll {
            PageHeader(title: "Virtual Screens", back: nav.pop) {
                Menu {
                    ForEach(VirtualScreens.presets, id: \.0) { name, w, h in
                        Button("\(name) · \(w) × \(h)") { model.addVirtual(name: name, width: w, height: h); selected = model.config.virtualScreens.last?.id }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.button).buttonStyle(.borderedProminent).buttonBorderShape(.circle).menuIndicator(.hidden)
                .fixedSize().accessibilityLabel("New Virtual Screen")
            }
            if screens.isEmpty {
                Module(padded: true) {
                    Text("Virtual screens work like real monitors: a desktop for a headless Mac, Screen Sharing at any HiDPI size, or a source for Picture in Picture. Add one with +.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Module {
                    ForEach(screens) { s in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                                .foregroundStyle(.secondary)
                                .frame(width: s.width >= s.height ? 28 : 14, height: s.width >= s.height ? max(10, 28 * CGFloat(s.height) / CGFloat(s.width)) : 20)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(s.name).fontWeight(.medium)
                                Text("\(s.width) × \(s.height) · \(s.aspectLabel)\(s.hiDPI ? " · HiDPI" : "") · \(Int(s.refreshRate)) Hz")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(s.name, isOn: Binding(get: { model.virtual.isConnected(s.id) }, set: { model.setVirtual(s.id, connected: $0) }))
                                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        }
                        .padding(.horizontal, Metrics.inset)
                        .frame(height: Metrics.tallRow)
                        .background(selected == s.id ? Color.accentColor.opacity(0.12) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = s.id }
                    }
                }
                if let s = screens.first(where: { $0.id == (selected ?? screens.first?.id) }) {
                    VirtualEditor(screen: s)
                }
            }
        }
    }
}

struct VirtualEditor: View {
    @EnvironmentObject var model: AppModel
    let screen: VirtualScreenConfig
    @State private var draft: VirtualScreenConfig

    init(screen: VirtualScreenConfig) {
        self.screen = screen
        _draft = State(initialValue: screen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            VStack(alignment: .leading, spacing: 4) {
                ModuleHeader(screen.name)
                Module {
                    Row(title: "Name") {
                        TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder).frame(width: 150).onSubmit(save)
                    }
                    Row(title: "Size") {
                        HStack(spacing: 4) {
                            TextField("W", value: $draft.width, format: .number.grouping(.never)).frame(width: 58).onSubmit(save)
                            Text("×").foregroundStyle(.secondary)
                            TextField("H", value: $draft.height, format: .number.grouping(.never)).frame(width: 58).onSubmit(save)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                    PickerRow(title: "Refresh Rate", selection: Binding(get: { draft.refreshRate }, set: { draft.refreshRate = $0; save() }),
                              options: [(30.0, "30 Hz"), (60.0, "60 Hz"), (120.0, "120 Hz")])
                    ToggleRow(title: "HiDPI", isOn: Binding(get: { draft.hiDPI }, set: { draft.hiDPI = $0; save() }))
                    ToggleRow(title: "Connect at Login", isOn: Binding(get: { draft.connectAtLogin }, set: { draft.connectAtLogin = $0; save() }))
                }
            }
            ButtonBar(buttons: [
                ("Show in PiP", false, {
                    if let id = model.virtual.displayID(screen.id) { PiP.shared.open(display: id) }
                }),
                ("Delete", true, { model.removeVirtual(screen.id) })
            ])
        }
        .onChange(of: screen) { _, new in draft = new }
    }

    private func save() {
        draft.width = max(640, min(8192, draft.width))
        draft.height = max(480, min(8192, draft.height))
        model.updateVirtual(draft)
    }
}

// MARK: - Arrangement, protection, connection

struct ArrangePage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator

    var body: some View {
        PageScroll {
            PageHeader(title: "Arrange & Connect", back: nav.pop)
            ArrangementCanvas()
            if !model.disabledByLucent.isEmpty {
                Module {
                    ForEach(model.disabledByLucent.sorted(by: { $0.key < $1.key }), id: \.key) { id, name in
                        Row(title: name, subtitle: "Disconnected by Lucent") {
                            Button("Reconnect") { model.reconnect(id) }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ModuleHeader("When protection is on, keep")
                Module {
                    ToggleRow(title: "Arrangement", isOn: $model.config.protection.arrangement)
                    ToggleRow(title: "Resolution", isOn: $model.config.protection.resolution)
                    ToggleRow(title: "Refresh Rate", isOn: $model.config.protection.refreshRate)
                    ToggleRow(title: "Rotation", isOn: $model.config.protection.rotation)
                    ToggleRow(title: "Colour Profile", isOn: $model.config.protection.colorProfile)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ModuleHeader("Connection rules")
                Module {
                    ToggleRow(title: "Turn Off Built-in With External", isOn: Binding(get: { model.config.rules.disconnectBuiltInWithExternal },
                                                                                     set: { model.config.rules.disconnectBuiltInWithExternal = $0; model.applyConnectionRules() }))
                    ToggleRow(title: "Reconnect All on Wake", isOn: $model.config.rules.reconnectOnWake)
                }
            }
            if let d = model.selected, model.displays.count > 1 {
                ButtonBar(buttons: [("Only \(d.shortName)", false, { model.solo(d) }), ("Reconnect All", false, { model.reconnectAll() })])
            }
        }
    }
}

/// Drag displays to arrange them; edges snap together like System Settings.
struct ArrangementCanvas: View {
    @EnvironmentObject var model: AppModel
    @State private var drag: (CGDirectDisplayID, CGSize)?

    var body: some View {
        let displays = model.displays.filter { $0.mirrorOf == nil }
        let union = displays.reduce(CGRect.null) { $0.union($1.bounds) }
        GeometryReader { geo in
            let scale = min((geo.size.width - 32) / max(1, union.width), (geo.size.height - 32) / max(1, union.height))
            let offset = CGPoint(x: (geo.size.width - union.width * scale) / 2, y: (geo.size.height - union.height * scale) / 2)
            ZStack(alignment: .topLeading) {
                ForEach(displays) { d in
                    let moving = drag?.0 == d.id ? drag!.1 : .zero
                    let rect = CGRect(x: (d.bounds.minX - union.minX) * scale + offset.x + moving.width,
                                      y: (d.bounds.minY - union.minY) * scale + offset.y + moving.height,
                                      width: d.bounds.width * scale, height: d.bounds.height * scale)
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(d.isVirtual ? AnyShapeStyle(.clear) : AnyShapeStyle(d.id == model.selected?.id ? Color.accentColor : Color.accentColor.opacity(0.55)))
                        if d.isVirtual {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).foregroundStyle(Color.accentColor)
                        }
                        if d.isMain {
                            Capsule().fill(.white.opacity(0.85)).frame(width: rect.width * 0.4, height: 3).padding(5)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                        Text(d.shortName).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(d.isVirtual ? Color.accentColor : .white).padding(5)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .onTapGesture { model.selectedID = d.id }
                    .gesture(DragGesture()
                        .onChanged { g in drag = (d.id, g.translation) }
                        .onEnded { g in
                            drag = nil
                            let proposed = CGRect(origin: CGPoint(x: d.bounds.minX + g.translation.width / scale,
                                                                  y: d.bounds.minY + g.translation.height / scale), size: d.bounds.size)
                            model.setOrigin(d, Self.snap(proposed, to: displays.filter { $0.id != d.id }.map(\.bounds)))
                        })
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(d.name)\(d.isMain ? ", main display" : "")")
                }
            }
        }
        .frame(height: 170)
        .background(.quinary, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
    }

    /// Moves `r` so it touches the nearest edge of another display.
    static func snap(_ r: CGRect, to others: [CGRect]) -> CGPoint {
        guard !others.isEmpty else { return r.origin }
        var best = r.origin
        var bestDistance = CGFloat.infinity
        for o in others {
            let candidates = [
                CGPoint(x: o.maxX, y: r.minY), CGPoint(x: o.minX - r.width, y: r.minY),
                CGPoint(x: r.minX, y: o.maxY), CGPoint(x: r.minX, y: o.minY - r.height)
            ]
            for var c in candidates {
                // Keep the shared edge overlapping and align to edges when close.
                if c.x == o.maxX || c.x == o.minX - r.width {
                    c.y = min(max(c.y, o.minY - r.height + 40), o.maxY - 40)
                    if abs(c.y - o.minY) < 60 { c.y = o.minY }
                } else {
                    c.x = min(max(c.x, o.minX - r.width + 40), o.maxX - 40)
                    if abs(c.x - o.minX) < 60 { c.x = o.minX }
                }
                let d = hypot(c.x - r.minX, c.y - r.minY)
                if d < bestDistance { bestDistance = d; best = c }
            }
        }
        return CGPoint(x: best.x.rounded(), y: best.y.rounded())
    }
}

// MARK: - Display groups

struct GroupsPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator

    var body: some View {
        PageScroll {
            PageHeader(title: "Display Groups", back: nav.pop) {
                Button {
                    var g = DisplayGroup()
                    g.name = "Group \(model.config.groups.count + 1)"
                    g.members = model.displays.filter { !$0.isVirtual }.map(\.uuid)
                    model.config.groups.append(g)
                } label: { Image(systemName: "plus") }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle).accessibilityLabel("New Group")
            }
            if model.config.groups.isEmpty {
                Module(padded: true) {
                    Text("Group displays to move their brightness together. Matching in nits keeps a bright and a dim monitor looking the same.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach($model.config.groups) { $group in
                VStack(alignment: .leading, spacing: 4) {
                    ModuleHeader(group.name, trailing: AnyView(Button("Delete", role: .destructive) {
                        model.config.groups.removeAll { $0.id == group.id }
                    }.buttonStyle(.link)))
                    Module {
                        Row(title: "Name") { TextField("Name", text: $group.name).textFieldStyle(.roundedBorder).frame(width: 150) }
                        ForEach(model.displays) { d in
                            ToggleRow(title: d.name, isOn: Binding(get: { group.members.contains(d.uuid) }, set: { on in
                                if on { group.members.append(d.uuid) } else { group.members.removeAll { $0 == d.uuid } }
                            }))
                        }
                        ToggleRow(title: "Sync Brightness", isOn: $group.syncBrightness)
                        ToggleRow(title: "Match in Nits", isOn: $group.matchNits)
                        ToggleRow(title: "Sync Image Adjustments", isOn: $group.syncAdjustments)
                    }
                }
            }
            if model.config.groups.contains(where: \.matchNits) {
                VStack(alignment: .leading, spacing: 4) {
                    ModuleHeader("Peak brightness (nits)")
                    Module {
                        ForEach(model.displays.filter { !$0.isVirtual }) { d in
                            Row(title: d.name) {
                                TextField("nits", value: Binding(get: { model.settings(d).maxNits }, set: { v in model.update(d) { $0.maxNits = v } }),
                                          format: .number).textFieldStyle(.roundedBorder).frame(width: 64)
                            }
                        }
                    }
                }
            }
        }
    }
}
