import AppKit
import ServiceManagement
import SwiftUI

enum Onboarding {
    private static let key = "onboarding.completed"

    static var isComplete: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static var panel: GlassPanel?

    /// On first launch, shows the welcome page in a glass panel under the menu bar.
    /// (MenuBarExtra can't open its own panel from code, so we present the same page.)
    @MainActor static func presentIfNeeded() {
        guard !isComplete else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let page = OnboardingPage(done: finish).environmentObject(AppModel.shared)
            let panel = GlassPanel(rootView: page.frame(width: Metrics.width).focusEffectDisabled())
            panel.showUnderMenuBar()
            self.panel = panel
        }
    }

    @MainActor static func finish() {
        isComplete = true
        panel?.close()
        panel = nil
    }
}

struct OnboardingPage: View {
    let done: () -> Void
    @State private var openAtLogin = true
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                Text("Welcome to Lucent").font(.system(size: 17, weight: .bold))
                Text("Every display feature, free. Grant these so Lucent can control your screens.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.top, 12)

            PermissionList()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Open at login", isOn: $openAtLogin)
                Toggle("Use brightness keys for every display", isOn: $model.config.keys.mediaKeys)
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.inset)

            Button {
                if openAtLogin { try? SMAppService.mainApp.register() }
                Keys.shared.restart()
                done()
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(Metrics.pad)
    }
}
