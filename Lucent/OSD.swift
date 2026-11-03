import AppKit
import SwiftUI

/// Brightness / volume overlay on the display that changed, styled like the system's.
@MainActor
final class OSD {
    static let shared = OSD()
    enum Kind { case brightness, volume }

    private var window: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(kind: Kind, value: Double, on display: Display) {
        let style = AppModel.shared.config.osd
        if AppModel.shared.config.automation.osdBroadcast {
            // Other apps (notch and island utilities) can draw their own OSD from this.
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.yahyakhamaisi.lucent.osd"), object: nil,
                userInfo: ["kind": kind == .brightness ? "brightness" : "volume", "value": value, "display": display.uuid],
                deliverImmediately: true)
        }
        guard style != .off, let screen = display.screen else { return }
        let view = OSDView(kind: kind, value: value, classic: style == .classic)
        let size = style == .classic ? NSSize(width: 200, height: 200) : NSSize(width: 300, height: 56)
        let panel = window ?? makePanel()
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        let frame = screen.visibleFrame
        let y = style == .classic ? frame.minY + 120 : frame.maxY - size.height - 12
        let x = style == .classic ? frame.midX - size.width / 2 : frame.maxX - size.width - 12
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        window = panel
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; panel?.animator().alphaValue = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }
}

struct OSDView: View {
    let kind: OSD.Kind
    let value: Double
    let classic: Bool

    private var symbol: String {
        switch kind {
        case .brightness: value < 0.01 ? "sun.min" : "sun.max.fill"
        case .volume: value < 0.01 ? "speaker.slash.fill" : value < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
        }
    }

    var body: some View {
        Group {
            if classic {
                VStack(spacing: 20) {
                    Image(systemName: symbol).font(.system(size: 64, weight: .regular))
                    HStack(spacing: 2) {
                        ForEach(0..<16, id: \.self) { i in
                            Rectangle().fill(Double(i) < value * 16 ? Color.primary : Color.primary.opacity(0.2))
                                .frame(width: 7, height: 6)
                        }
                    }
                }
                .frame(width: 200, height: 200)
                .background(.regularMaterial, in: .rect(cornerRadius: 20, style: .continuous))
            } else {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 22)
                    ProgressView(value: max(0, min(1, value)))
                        .progressViewStyle(.linear)
                    Text("\(Int((value * 100).rounded()))")
                        .font(.callout.monospacedDigit())
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .frame(width: 300, height: 56)
                .modifier(GlassCapsule())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind == .brightness ? "Brightness" : "Volume") \(Int(value * 100)) percent")
    }
}

/// Liquid Glass on macOS 26+, a material capsule before.
struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: .capsule)
        }
    }
}
