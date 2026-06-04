import AppIntents

/// Launches Ramblr and immediately starts recording.
///
/// Assign to the Action Button: Settings → Action Button → Shortcut → pick
/// "Start Ramblr Recording". Also appears in the Shortcuts app and Spotlight.
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Ramblr Recording"
    static var description = IntentDescription(
        "Opens Ramblr and starts recording a voice note for Whisper transcription."
    )

    /// Bring the app to the foreground — recording requires an active app.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.requestAutoStart()
        return .result()
    }
}

/// Makes the intent discoverable as an App Shortcut (no manual setup needed).
struct RamblrShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start \(.applicationName) recording",
                "Record with \(.applicationName)",
                "New \(.applicationName) note",
            ],
            shortTitle: "Record",
            systemImageName: "mic.fill"
        )
    }
}
