import AppIntents
import Foundation

// Shared by the app and the Control Center extension (LiveSubsControls).

extension Notification.Name {
    static let liveSubsCommand = Notification.Name("LiveSubsCommand")
}

// MARK: - Shortcuts / Siri / Action button

/// "Start Live Subtitles" — opens the app (iOS requires the app in the foreground to
/// begin screen-audio capture and Picture in Picture) and starts immediately.
struct StartSubtitlesIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Live Subtitles"
    static let description = IntentDescription("Starts translating audio from videos into floating English subtitles.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Give the scene a moment to become active before starting PiP.
        try? await Task.sleep(for: .milliseconds(400))
        NotificationCenter.default.post(name: .liveSubsCommand, object: "start")
        return .result()
    }
}

struct StopSubtitlesIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Live Subtitles"
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .liveSubsCommand, object: "stop")
        return .result()
    }
}

/// One tap from Control Center, the Lock Screen or the Action button: starts subtitles,
/// or stops them if they're on. iOS requires the app in front to begin capture.
struct ToggleSubtitlesIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Live Subtitles On or Off"
    static let description = IntentDescription("Starts LiveSubs, or stops it if subtitles are already on.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try? await Task.sleep(for: .milliseconds(400))
        NotificationCenter.default.post(name: .liveSubsCommand, object: "toggle")
        return .result()
    }
}

struct LiveSubsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartSubtitlesIntent(),
                    phrases: ["Start \(.applicationName)", "Turn on \(.applicationName)"],
                    shortTitle: "Start Subtitles", systemImageName: "captions.bubble.fill")
        AppShortcut(intent: StopSubtitlesIntent(),
                    phrases: ["Stop \(.applicationName)", "Turn off \(.applicationName)"],
                    shortTitle: "Stop Subtitles", systemImageName: "stop.circle")
        AppShortcut(intent: ToggleSubtitlesIntent(),
                    phrases: ["Toggle \(.applicationName)", "\(.applicationName) subtitles"],
                    shortTitle: "Subtitles On/Off", systemImageName: "captions.bubble")
    }
}
