import AppKit

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--focus-link-test") || CommandLine.arguments.contains("--focus-developer-test") {
        Task { @MainActor in exit(await FocusLinkProbe.run(developerMode: CommandLine.arguments.contains("--focus-developer-test"))) }
        NSApplication.shared.run()
        return
    }
    if CommandLine.arguments.contains("--focus-api-test") || CommandLine.arguments.contains("--focus-screen-test") {
        Task { @MainActor in exit(await FocusDiagnostics.run(realScreen: CommandLine.arguments.contains("--focus-screen-test"))) }
        NSApplication.shared.run()
        return
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
    app.run()
}
