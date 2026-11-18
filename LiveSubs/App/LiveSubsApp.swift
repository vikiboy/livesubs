import SwiftUI

@main
struct LiveSubsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var models = ModelManager()
    @StateObject private var session: LiveSession

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _session = StateObject(wrappedValue: LiveSession(settings: s))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(models)
                .environmentObject(session)
                // A cinema is dark: the app always runs in the dark appearance,
                // with subtitle yellow as the single tint.
                .preferredColorScheme(.dark)
                .tint(Theme.subtitle)
                // Compile the private browser's ad-blocking rules in the background (first launch
                // after an update only; afterwards they load instantly).
                .task {
                    // Re-create the Neural Engine copy of the speech model right away after an
                    // install, so it's ready before you press play.
                    ModelWarmup.start(settings.model, manager: models)
                    if settings.blockAds { _ = await BrowserModel.adBlockers() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .liveSubsCommand)) { note in
                    switch note.object as? String {
                    case "start": session.start()
                    case "stop": session.stop()
                    default: session.toggle()
                    }
                }
        }
    }
}


