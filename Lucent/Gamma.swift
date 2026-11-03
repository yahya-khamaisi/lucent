import AppKit
import CoreGraphics
import MetalKit

/// Software dimming and image adjustments through each display's gamma table.
enum Gamma {
    /// Writes one combined table: contrast → gamma → colour gains × temperature × dim.
    static func apply(_ id: CGDirectDisplayID, adjustments a: ImageAdjustments, dim: Double) {
        if a.isNeutral && dim >= 0.999 {
            reset(id)
            return
        }
        let size = 256
        let t = temperatureGains(a.temperature)
        let gains = [a.red * t.r, a.green * t.g, a.blue * t.b].map { $0 * dim }
        var tables: [[CGGammaValue]] = [[], [], []]
        for i in 0..<size {
            var v = Double(i) / Double(size - 1)
            if a.invert { v = 1 - v }
            v = (v - 0.5) * a.contrast + 0.5
            v = pow(max(0, min(1, v)), a.gamma)
            for c in 0..<3 { tables[c].append(CGGammaValue(max(0, min(1, v * gains[c])))) }
        }
        CGSetDisplayTransferByTable(id, UInt32(size), tables[0], tables[1], tables[2])
    }

    static func reset(_ id: CGDirectDisplayID) {
        // Restores every display from ColorSync; the caller re-applies the ones still adjusted.
        CGDisplayRestoreColorSyncSettings()
    }

    /// RGB multipliers for a white point (Tanner Helland's approximation), normalised to 6500 K.
    static func temperatureGains(_ kelvin: Double) -> (r: Double, g: Double, b: Double) {
        func rgb(_ k: Double) -> (Double, Double, Double) {
            let t = k / 100
            let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
            let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
            let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
            return (min(255, max(0, r)) / 255, min(255, max(0, g)) / 255, min(255, max(0, b)) / 255)
        }
        let target = rgb(kelvin)
        let base = rgb(6500)
        let r = target.0 / base.0, g = target.1 / base.1, b = target.2 / base.2
        let m = max(r, g, b)
        return (r / m, g / m, b / m)
    }
}

/// Extra brightness on XDR/HDR screens: a click-through window drawing EDR white with a
/// multiply blend, which raises everything beneath it above SDR white.
@MainActor
final class XDRBoost {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    func set(_ display: Display, amount: Double) {
        guard let screen = display.screen, display.edrHeadroom > 1.01, amount > 0.001 else {
            windows.removeValue(forKey: display.id)?.close()
            return
        }
        let window = windows[display.id] ?? makeWindow(screen)
        windows[display.id] = window
        window.setFrame(screen.frame, display: true)
        let factor = 1 + (Double(display.boostHeadroom) - 1) * amount
        (window.contentView as? EDRView)?.factor = factor
        window.orderFrontRegardless()
    }

    func removeAll() {
        windows.values.forEach { $0.close() }
        windows.removeAll()
    }

    private func makeWindow(_ screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        window.contentView = EDRView(frame: NSRect(origin: .zero, size: screen.frame.size))
        return window
    }
}

/// A Metal view that clears to an EDR grey of `factor` and multiplies onto the desktop.
final class EDRView: MTKView, MTKViewDelegate {
    var factor: Double = 1 { didSet { needsDisplay = true } }
    private let queue: MTLCommandQueue?

    init(frame: NSRect) {
        let device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init(frame: frame, device: device)
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        enableSetNeedsDisplay = true
        isPaused = true
        delegate = self
        wantsLayer = true
        if let layer = layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = false
            layer.compositingFilter = "multiplyBlendMode"
        }
    }

    required init(coder: NSCoder) { fatalError() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        clearColor = MTLClearColor(red: factor, green: factor, blue: factor, alpha: 1)
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = queue?.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
