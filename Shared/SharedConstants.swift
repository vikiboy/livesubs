import Foundation

/// Values shared by the app and the ReplayKit broadcast extension.
enum Shared {
    /// App Group identifier, injected into both Info.plists from Config/Signing.xcconfig.
    static let appGroupID: String = {
        if let id = Bundle.main.object(forInfoDictionaryKey: "LSAppGroupIdentifier") as? String, !id.isEmpty {
            return id
        }
        return "group.com.example.livesubs"
    }()

    /// Audio delivered across the process boundary is always 16 kHz mono Float32 —
    /// the native input format of Whisper and fine for SpeechAnalyzer after conversion.
    static let sampleRate: Double = 16_000

    /// Ring buffer capacity: 30 s of audio (≈1.9 MB). The app drains it every ~100 ms.
    static let ringCapacitySamples = 16_000 * 30

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var ringBufferURL: URL? { containerURL?.appendingPathComponent("audio.ring") }

    /// Darwin notification names (cross-process, payload-free).
    enum Note {
        static let broadcastStarted = "livesubs.broadcast.started"
        static let broadcastStopped = "livesubs.broadcast.stopped"
        static let audioAvailable = "livesubs.broadcast.audio"
        /// Posted by the app to ask the extension to end the broadcast.
        static let requestStop = "livesubs.app.requestStop"
    }
}
