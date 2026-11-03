import AppKit
import SwiftUI

/// Lucent lives entirely in one menu-bar panel: no Dock icon, no windows.
@main
struct LucentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    init() {
        CLIClient.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            Image(systemName: model.config.menuIcon.symbol)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        MainActor.assumeIsolated {
            AppModel.shared.start()
            #if DEBUG
            if DesignPreview.runIfRequested() { return }
            #endif
            Onboarding.presentIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.stop() }
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: string) else { return }
        MainActor.assumeIsolated { Automation.shared.handle(url: url) }
    }
}

#if DEBUG
/// `-preview <page> [light|dark]` shows a page in a borderless glass panel so it can be
/// captured for design review without opening the menu bar.
enum DesignPreview {
    @MainActor static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-preview"), i + 1 < args.count else { return false }
        let pages: [String: Page] = ["main": .main, "display": .display, "settings": .settings, "virtual": .virtual,
                                     "arrange": .arrange, "automation": .automation, "diagnostics": .diagnostics,
                                     "pip": .pip, "image": .image, "keys": .keys, "tvs": .tvs, "onboarding": .onboarding,
                                     "groups": .groups, "overrides": .overrides, "permissions": .permissions]
        let page = pages[args[i + 1]] ?? .main
        if args.contains("dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("light") { NSApp.appearance = NSAppearance(named: .aqua) }
        let panel = GlassPanel(rootView: PanelView(initialPage: page).environmentObject(AppModel.shared))
        panel.title = "Lucent \(args[i + 1])"
        panel.hasShadow = false
        panel.showUnderMenuBar()
        return true
    }
}
#endif
