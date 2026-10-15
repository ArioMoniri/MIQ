import AppIntents

/// Registers MIQ's intents as App Shortcuts, so they appear in the Shortcuts app's
/// MIQ section and in Spotlight without the user building a shortcut first. On
/// macOS 26 Spotlight also lists App Shortcuts as runnable actions; nothing extra
/// is needed for that.
///
/// Phrases cannot reference the `IntentFile` parameter (only `AppEnum` /
/// `AppEntity` parameters may appear in a phrase), so the system asks for the file
/// when the shortcut runs.
@available(macOS 15.0, *)
struct MIQAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetVolumeInfoIntent(),
            phrases: [
                "Get volume info with \(.applicationName)",
                "Show medical image info in \(.applicationName)",
            ],
            shortTitle: "Volume Info",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: RenderCenterSliceIntent(),
            phrases: [
                "Render a center slice with \(.applicationName)",
                "Render the \(\.$plane) slice with \(.applicationName)",
            ],
            shortTitle: "Render Center Slice",
            systemImageName: "square.split.bottomrightquarter"
        )
    }
}
