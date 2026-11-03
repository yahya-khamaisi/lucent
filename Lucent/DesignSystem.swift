import AppKit
import SwiftUI

/// One spacing system for every page (4pt grid). Values match the approved mock.
enum Metrics {
    static let width: CGFloat = 340
    static let pad: CGFloat = 12          // panel edge
    static let gap: CGFloat = 8           // between modules
    static let radius: CGFloat = 16       // module corners
    static let row: CGFloat = 30          // single-line row
    static let tallRow: CGFloat = 44      // two-line row
    static let inset: CGFloat = 12        // row content inset inside a module
    /// Tallest the panel gets before its content scrolls.
    static var maxHeight: CGFloat { min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 40) }
}

/// A rounded group of rows, like a Control Center module.
struct Module<Content: View>: View {
    var padded = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.vertical, padded ? Metrics.inset : 4)
            .padding(.horizontal, padded ? Metrics.inset : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
    }
}

/// Small caption above a module.
struct ModuleHeader: View {
    let title: String
    var trailing: AnyView? = nil
    init(_ title: String, trailing: AnyView? = nil) { self.title = title; self.trailing = trailing }

    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            trailing.font(.system(size: 11))
        }
        .frame(height: 14)
        .padding(.horizontal, Metrics.inset)
    }
}

/// White SF Symbol on a tinted rounded square, like System Settings.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Row that opens another page.
struct NavRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var value: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, tint: tint)
                Text(title)
                Spacer(minLength: 8)
                Text(value).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.leading, Metrics.inset)
            .padding(.trailing, 10)
            .frame(height: Metrics.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel("\(title), \(value)")
    }
}

/// Subtle press highlight for full-width rows.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear)
    }
}

/// Label on the left, any control on the right, 30pt tall.
struct Row<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Metrics.inset)
        .frame(minHeight: subtitle == nil ? Metrics.row : Metrics.tallRow)
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Row(title: title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

struct PickerRow<T: Hashable>: View {
    let title: String
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        Row(title: title) {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

/// Native thin slider with a label and value, for hardware and image adjustments.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))" }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 86, alignment: .leading).lineLimit(1)
            Slider(value: $value, in: range) { Text(title) }.labelsHidden().controlSize(.small)
            Text(format(value)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, Metrics.inset)
        .frame(height: Metrics.row)
    }
}

/// Control Center–style wide slider: 28pt capsule, symbol inside, white fill.
struct WideSlider: View {
    let title: String
    let symbol: String
    let valueLabel: String
    @Binding var value: Double
    var onCommit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(valueLabel).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 2)
            GeometryReader { geo in
                let w = geo.size.width
                let fill = max(28, w * value)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.white).frame(width: fill)
                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.6))
                        .padding(.leading, 9)
                }
                .contentShape(Capsule())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in value = max(0, min(1, g.location.x / w)) }
                    .onEnded { _ in onCommit() })
            }
            .frame(height: 28)
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...1) { Text(title) }
        }
    }
}

/// Round toggle with a caption, like Control Center's quick toggles.
struct ToggleTile: View {
    let symbol: String
    let title: String
    let isOn: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .frame(width: 34, height: 34)
                    .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Circle())
                Text(title).font(.system(size: 10.5)).lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Page title row with a back button and an optional trailing control.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let back: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .keyboardShortcut(.cancelAction)
            .help("Back")
            .accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: 32)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, back: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, back: back) { EmptyView() }
    }
}

/// A row of equal-width capsule buttons.
struct ButtonBar: View {
    let buttons: [(String, Bool, () -> Void)]   // title, destructive, action

    var body: some View {
        HStack(spacing: Metrics.gap) {
            ForEach(buttons.indices, id: \.self) { i in
                Button(role: buttons[i].1 ? .destructive : nil, action: buttons[i].2) {
                    Text(buttons[i].0).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
    }
}

/// Scrolls only when the page is taller than the screen allows; otherwise sizes to fit.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 400

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Metrics.gap) { content }
                .padding(Metrics.pad)
                .background(GeometryReader { g in
                    Color.clear.preference(key: HeightKey.self, value: g.size.height)
                })
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(height, Metrics.maxHeight))
        .onPreferenceChange(HeightKey.self) { h in height = h }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Monospaced dark block for commands and logs.
struct CodeBlock: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Color(white: 0.9))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, 10)
            .background(Color(white: 0.11), in: .rect(cornerRadius: Metrics.radius, style: .continuous))
    }
}

func percentLabel(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
