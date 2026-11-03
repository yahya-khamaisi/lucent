import AppKit
import CoreImage
import ScreenCaptureKit
import SwiftUI

struct PiPSettings: Equatable {
    var flip = false
    var rotation = 0
    var sharpen = 0.0
    var lutPath: String?
    var frameRate = 30
    var floatOnTop = true
    var clickThrough = false
    var hideFromCapture = false
    var opacity = 1.0
}

/// Picture in Picture and display streaming with ScreenCaptureKit.
@MainActor
final class PiP: ObservableObject {
    static let shared = PiP()

    enum Source: Equatable {
        case display(CGDirectDisplayID)
        case window(CGWindowID, String)
    }

    @Published var settings = PiPSettings() { didSet { applySettings() } }
    @Published private(set) var source: Source?
    @Published private(set) var paused = false
    @Published var lastError: String?

    private var window: PiPWindow?
    private var stream: SCStream?
    private var output: FrameOutput?
    private var fullScreenOn: CGDirectDisplayID?

    var isOpen: Bool { window != nil }

    static var permissionGranted: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    func toggle(display: CGDirectDisplayID) {
        if isOpen { closeAll() } else { open(display: display) }
    }

    func open(display: CGDirectDisplayID) { start(.display(display), fullScreenOn: nil) }
    func open(window id: CGWindowID, title: String) { start(.window(id, title), fullScreenOn: nil) }

    /// Shows `source` filling another display: portrait Sidecar, teleprompters, redirects.
    func stream(_ source: CGDirectDisplayID, to target: CGDirectDisplayID) {
        start(.display(source), fullScreenOn: target)
    }

    func closeAll() {
        Task { try? await stream?.stopCapture() }
        stream = nil
        output = nil
        window?.close()
        window = nil
        source = nil
        fullScreenOn = nil
        paused = false
    }

    func togglePause() {
        paused.toggle()
        output?.paused = paused
    }

    private func start(_ newSource: Source, fullScreenOn target: CGDirectDisplayID?) {
        guard Self.permissionGranted else {
            Self.requestPermission()
            lastError = "Allow Screen Recording for Lucent in System Settings, then try again."
            return
        }
        closeAll()
        source = newSource
        fullScreenOn = target
        Task { await begin(newSource) }
    }

    private func begin(_ source: Source) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter: SCContentFilter
            var size = CGSize(width: 1280, height: 720)
            switch source {
            case .display(let id):
                guard let display = content.displays.first(where: { $0.displayID == id }) else { throw PiPError.missing }
                filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                size = CGSize(width: display.width, height: display.height)
            case .window(let id, _):
                guard let w = content.windows.first(where: { $0.windowID == id }) else { throw PiPError.missing }
                filter = SCContentFilter(desktopIndependentWindow: w)
                size = w.frame.size
            }
            let config = SCStreamConfiguration()
            let scale = 2.0
            config.width = Int(size.width * scale)
            config.height = Int(size.height * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
            config.queueDepth = 4
            config.showsCursor = true
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let window = PiPWindow(aspect: size)
            let output = FrameOutput(layer: window.videoLayer)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "lucent.pip"))
            try await stream.startCapture()
            self.window = window
            self.output = output
            self.stream = stream
            if let target = fullScreenOn, let screen = AppModel.shared.display(target)?.screen {
                window.fill(screen)
            } else {
                window.placeDefault()
            }
            applySettings()
            window.orderFrontRegardless()
            lastError = nil
        } catch {
            lastError = "Couldn't start capture: \(error.localizedDescription)"
            AppModel.shared.log("pip", lastError ?? "")
            closeAll()
        }
    }

    private func applySettings() {
        guard let window else { return }
        window.level = fullScreenOn != nil ? .screenSaver : (settings.floatOnTop ? .floating : .normal)
        window.ignoresMouseEvents = settings.clickThrough
        window.sharingType = settings.hideFromCapture ? .none : .readOnly
        window.alphaValue = settings.opacity
        window.apply(flip: settings.flip, rotation: settings.rotation, sharpen: settings.sharpen,
                     lut: settings.lutPath.flatMap(LUT.load))
        if let stream {
            let config = SCStreamConfiguration()
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
            Task { try? await stream.updateConfiguration(config) }
        }
    }

    var sourceName: String {
        switch source {
        case .display(let id): AppModel.shared.display(id)?.name ?? "Display"
        case .window(_, let title): title
        case nil: "None"
        }
    }

    enum PiPError: Error { case missing }
}

/// Receives frames on a background queue and shows each IOSurface on the layer.
final class FrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private weak var layer: CALayer?
    var paused = false

    init(layer: CALayer) { self.layer = layer }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !paused, type == .screen, buffer.isValid,
              let pixels = CMSampleBufferGetImageBuffer(buffer),
              let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.layer?.contents = surface
            CATransaction.commit()
        }
    }
}

/// Borderless floating window: rounded, resizable, controls on hover. No title bar.
final class PiPWindow: NSPanel {
    let videoLayer = CALayer()
    private let videoView = NSView()
    private var aspect: CGSize

    init(aspect: CGSize) {
        self.aspect = aspect
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = aspect

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        videoView.wantsLayer = true
        videoView.layerUsesCoreImageFilters = true
        videoView.layer = videoLayer
        videoLayer.contentsGravity = .resizeAspect
        videoView.autoresizingMask = [.width, .height]
        container.addSubview(videoView)

        let hud = NSHostingView(rootView: PiPHUD())
        hud.autoresizingMask = [.width, .height]
        container.addSubview(hud)
        contentView = container
        videoView.frame = container.bounds
        hud.frame = container.bounds
    }

    override var canBecomeKey: Bool { true }

    func placeDefault() {
        guard let screen = NSScreen.main else { return }
        let width = min(560, screen.visibleFrame.width * 0.35)
        let height = width * aspect.height / max(1, aspect.width)
        setFrame(NSRect(x: screen.visibleFrame.maxX - width - 24, y: screen.visibleFrame.minY + 24, width: width, height: height), display: true)
    }

    func fill(_ screen: NSScreen) {
        contentAspectRatio = .zero
        styleMask.remove(.resizable)
        isMovableByWindowBackground = false
        contentView?.layer?.cornerRadius = 0
        setFrame(screen.frame, display: true)
    }

    func apply(flip: Bool, rotation: Int, sharpen: Double, lut: CIFilter?) {
        var t = CGAffineTransform.identity
        if flip { t = t.scaledBy(x: -1, y: 1) }
        t = t.rotated(by: CGFloat(rotation) * .pi / 180)
        videoLayer.setAffineTransform(t)
        var filters: [CIFilter] = []
        if sharpen > 0.01, let f = CIFilter(name: "CISharpenLuminance") {
            f.setValue(sharpen * 2, forKey: kCIInputSharpnessKey)
            filters.append(f)
        }
        if let lut { filters.append(lut) }
        videoLayer.filters = filters.isEmpty ? nil : filters
    }
}

/// Controls shown while the pointer is over the PiP window.
struct PiPHUD: View {
    @ObservedObject var pip = PiP.shared
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear.contentShape(Rectangle())
            if hovering {
                HStack(spacing: 2) {
                    hudButton(pip.paused ? "play.fill" : "pause.fill", pip.paused ? "Resume" : "Pause") { pip.togglePause() }
                    hudButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip Horizontally") { pip.settings.flip.toggle() }
                    hudButton("rotate.right", "Rotate") { pip.settings.rotation = (pip.settings.rotation + 90) % 360 }
                    hudButton("xmark", "Close") { pip.closeAll() }
                }
                .padding(.horizontal, 4)
                .frame(height: 32)
                .modifier(GlassCapsule())
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    private func hudButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// `.cube` 3D LUT files → CIColorCubeWithColorSpace.
enum LUT {
    static func load(_ path: String) -> CIFilter? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var size = 0
        var values: [Float] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            if parts.first == "LUT_3D_SIZE", parts.count > 1 { size = Int(parts[1]) ?? 0; continue }
            let nums = parts.compactMap { Float($0) }
            if nums.count == 3, !(line.first?.isLetter ?? true) { values += nums + [1] }
        }
        guard size > 1, values.count == size * size * size * 4 else { return nil }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let f = CIFilter(name: "CIColorCubeWithColorSpace")
        f?.setValue(size, forKey: "inputCubeDimension")
        f?.setValue(data, forKey: "inputCubeData")
        f?.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
        return f
    }
}
