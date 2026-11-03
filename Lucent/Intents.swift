import AppIntents

/// Shortcuts actions. Each one is a thin wrapper over the shared command language.

struct SetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Display Brightness"
    static let description = IntentDescription("Sets a display's brightness in Lucent.")
    @Parameter(title: "Display", default: "main") var display: String
    @Parameter(title: "Brightness (%)", inclusiveRange: (0, 100)) var percent: Int

    static var parameterSummary: some ParameterSummary { Summary("Set \(\.$display) brightness to \(\.$percent)%") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: Command.run(["set", "-n", display, "--brightness", "\(percent)%"]))
    }
}

struct GetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Display Brightness"
    @Parameter(title: "Display", default: "main") var display: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: Command.run(["get", "-n", display, "--brightness"]))
    }
}

struct SetResolutionIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Display Resolution"
    @Parameter(title: "Display", default: "main") var display: String
    @Parameter(title: "Resolution", description: "For example 2560x1440") var resolution: String
    @Parameter(title: "HiDPI", default: true) var hiDPI: Bool

    static var parameterSummary: some ParameterSummary { Summary("Set \(\.$display) to \(\.$resolution)") { \.$hiDPI } }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: Command.run(["set", "-n", display, "--resolution", resolution, "--hidpi", hiDPI ? "on" : "off"]))
    }
}

struct SetXDRIntent: AppIntent {
    static let title: LocalizedStringResource = "Set XDR Boost"
    @Parameter(title: "Display", default: "builtin") var display: String
    @Parameter(title: "Boost (%)", inclusiveRange: (0, 100)) var percent: Int

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: Command.run(["set", "-n", display, "--xdr", "\(percent)%"]))
    }
}

struct VirtualScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect Virtual Screen"
    @Parameter(title: "Name") var name: String
    @Parameter(title: "Connected", default: true) var connected: Bool

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: Command.run(["virtual", connected ? "connect" : "disconnect", name]))
    }
}

struct DisconnectDisplayIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect or Reconnect Display"
    @Parameter(title: "Display") var display: String
    @Parameter(title: "Connected", default: false) var connected: Bool

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: Command.run(["set", "-n", display, "--connected", connected ? "on" : "off"]))
    }
}

struct RunCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Lucent Command"
    static let description = IntentDescription("Runs any lucent command, for example: set -n builtin --brightness 40%")
    @Parameter(title: "Command") var command: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: Command.run(Command.split(command)))
    }
}

struct LucentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetBrightnessIntent(), phrases: ["Set brightness in \(.applicationName)"],
                    shortTitle: "Set Brightness", systemImageName: "sun.max")
        AppShortcut(intent: SetResolutionIntent(), phrases: ["Change resolution in \(.applicationName)"],
                    shortTitle: "Set Resolution", systemImageName: "display")
        AppShortcut(intent: RunCommandIntent(), phrases: ["Run a \(.applicationName) command"],
                    shortTitle: "Run Command", systemImageName: "terminal")
    }
}
