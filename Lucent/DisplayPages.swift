import AppKit
import SwiftUI

/// Everything about one display: resolution, refresh, colour, rotation, DDC, connection.
struct DisplayPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @State private var showAll = false

    var body: some View {
        if let d = model.selected {
            PageScroll {
                PageHeader(title: d.name, subtitle: subtitle(d), back: nav.pop)
                resolutions(d)
                signal(d)
                if model.ddc[d.id] != nil { hardware(d) }
                Module {
                    if !d.isBuiltin && !d.isVirtual {
                        ToggleRow(title: "Flexible HiDPI Scaling", isOn: Binding(get: { model.settings(d).flexibleHiDPI },
                                                                                 set: { model.setFlexibleHiDPI(d, $0) }))
                    }
                    ToggleRow(title: "Dim to Black", isOn: Binding(get: { model.settings(d).dimToBlack },
                                                                   set: { v in model.update(d) { $0.dimToBlack = v }; model.readBrightness(d) }))
                    ToggleRow(title: "Protect Configuration", isOn: Binding(get: { model.settings(d).protect }, set: { model.setProtect(d, $0) }))
                    ToggleRow(title: "Use as Main Display", isOn: Binding(get: { d.isMain }, set: { if $0 { model.setMain(d) } }))
                        .disabled(d.isMain)
                }
                ButtonBar(buttons: [
                    ("Sleep", false, { model.sleepDisplay(d) }),
                    ("Disconnect", false, { model.disconnect(d) }),
                    ("Info", false, { nav.push(.diagnostics) })
                ])
            }
        }
    }

    private func subtitle(_ d: Display) -> String {
        var parts = [d.nativePixels.map { "\($0.0) × \($0.1) pixels" } ?? ""]
        parts.append(model.method(d).rawValue)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func resolutions(_ d: Display) -> some View {
        let target = model.flexibleTarget(d)
        let favorites = model.settings(d).favorites
        let all = target.resolutions.filter { showAll || $0.isHiDPI || $0.isNative || !target.resolutions.contains(where: \.isHiDPI) }
        let list = showAll ? all : Array(all.filter { favorites.contains($0.key) || $0.key == target.current?.key }
            + all.filter { !favorites.contains($0.key) && $0.key != target.current?.key }.prefix(6))
        let sorted = list.sorted { $0.width > $1.width }
        return VStack(alignment: .leading, spacing: 4) {
            ModuleHeader("Resolution", trailing: AnyView(Button(showAll ? "Fewer" : "Show All") { showAll.toggle() }.buttonStyle(.link)))
            Module {
                ForEach(sorted) { mode in
                    let isCurrent = mode.key == target.current?.key
                    let isFavorite = favorites.contains(mode.key)
                    HStack(spacing: 6) {
                        Button { _ = model.setResolution(d, key: mode.key) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color.accentColor).opacity(isCurrent ? 1 : 0).frame(width: 14)
                                Text(mode.sizeLabel).monospacedDigit()
                                Spacer()
                                Text(mode.isHiDPI ? (mode.isNative ? "HiDPI · Default" : "HiDPI") : mode.isNative ? "Native" : "Low Resolution")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { model.toggleFavorite(d, key: mode.key) } label: {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.system(size: 11)).foregroundStyle(isFavorite ? Color.orange : Color.secondary)
                                .frame(width: 18, height: 18).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isFavorite ? "Remove from favourites" : "Add to favourites (⌃⌥→ cycles them)")
                        .accessibilityLabel(isFavorite ? "Remove favourite" : "Add favourite")
                    }
                    .padding(.leading, Metrics.inset - 2)
                    .padding(.trailing, 8)
                    .frame(height: Metrics.row)
                }
            }
        }
    }

    private func signal(_ d: Display) -> some View {
        let rates = d.refreshRates
        let presets = PrivateAPI.presets(d.id)
        return VStack(alignment: .leading, spacing: 4) {
            ModuleHeader("Signal & Colour")
            Module {
                if rates.count > 1 {
                    Row(title: "Refresh Rate") {
                        Picker("Refresh Rate", selection: Binding(get: { d.current?.refreshLabel ?? "" },
                                                                  set: { v in _ = model.setRefresh(d, Double(v) ?? 60) })) {
                            ForEach(rates, id: \.refreshLabel) { Text("\($0.refreshLabel) Hz").tag($0.refreshLabel) }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                } else {
                    Row(title: "Refresh Rate") { Text("\(d.current?.refreshLabel ?? "60") Hz").foregroundStyle(.secondary) }
                }
                PickerRow(title: "Rotation", selection: Binding(get: { d.rotation }, set: { model.setRotation(d, $0) }),
                          options: [(0, "Standard"), (90, "90°"), (180, "180°"), (270, "270°")])
                Row(title: "Colour Profile") {
                    Menu(model.currentProfileName(d) ?? "Default") {
                        ForEach(AppModel.installedProfiles(), id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) { model.setColorProfile(d, path: url.path) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                if !presets.names.isEmpty {
                    Row(title: "Preset") {
                        Menu(presets.active ?? "Choose") {
                            ForEach(presets.names, id: \.self) { name in
                                Button(name) { _ = PrivateAPI.setPreset(d.id, name: name); model.objectWillChange.send() }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                if d.hasNotch {
                    ToggleRow(title: "Show Notch Area", isOn: Binding(get: { model.notchShown(d) }, set: { model.setNotchShown(d, $0) }))
                }
            }
        }
    }

    private func hardware(_ d: Display) -> some View {
        let h = model.hardware[d.id] ?? HardwareState()
        return VStack(alignment: .leading, spacing: 4) {
            ModuleHeader("Hardware (DDC)")
            Module {
                SliderRow(title: "Brightness", value: Binding(get: { model.brightness[d.id] ?? 1 }, set: { model.setBrightness(d, $0) }))
                if let c = h.contrast {
                    SliderRow(title: "Contrast", value: Binding(get: { c }, set: { model.setContrast(d, $0) }))
                }
                if let v = h.volume {
                    SliderRow(title: "Volume", value: Binding(get: { v }, set: { model.setVolume(d, $0) }))
                }
                Row(title: "Input Source") {
                    Menu(h.input.map(DDCInput.name) ?? "Choose") {
                        ForEach(DDCInput.common, id: \.0) { code, name in Button(name) { model.setInput(d, code) } }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }
}

/// Software image adjustments (gamma table). Works on every display, including TVs.
struct ImagePage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator

    var body: some View {
        if let d = model.selected {
            let a = model.settings(d).adjustments
            let set: (WritableKeyPath<ImageAdjustments, Double>) -> Binding<Double> = { key in
                Binding(get: { a[keyPath: key] }, set: { v in var n = a; n[keyPath: key] = v; model.setAdjustments(d, n) })
            }
            PageScroll {
                PageHeader(title: "Image Adjustments", subtitle: d.name, back: nav.pop)
                Module {
                    SliderRow(title: "Contrast", value: set(\.contrast), range: 0.5...1.5)
                    SliderRow(title: "Gamma", value: set(\.gamma), range: 0.5...2.0, format: { String(format: "%.2f", $0) })
                    SliderRow(title: "Temperature", value: set(\.temperature), range: 2700...9300, format: { "\(Int($0)) K" })
                }
                VStack(alignment: .leading, spacing: 4) {
                    ModuleHeader("Colour balance")
                    Module {
                        SliderRow(title: "Red", value: set(\.red))
                        SliderRow(title: "Green", value: set(\.green))
                        SliderRow(title: "Blue", value: set(\.blue))
                        ToggleRow(title: "Invert Colours", isOn: Binding(get: { a.invert }, set: { v in var n = a; n.invert = v; model.setAdjustments(d, n) }))
                    }
                }
                Text("Applied in software, so it works on any display. Lower temperature works as Night Shift for TVs.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, Metrics.inset)
                    .fixedSize(horizontal: false, vertical: true)
                ButtonBar(buttons: [("Reset", false, { model.setAdjustments(d, .neutral) })])
            }
        }
    }
}
