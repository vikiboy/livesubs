import Foundation

/// A producer of 16 kHz mono Float32 audio for the translation pipeline.
protocol AudioSource: AnyObject {
    /// Delivered on an arbitrary background queue.
    var onSamples: (([Float]) -> Void)? { get set }
    func start() async throws
    func stop()
}

enum AudioSourceKind: String, CaseIterable, Identifiable, Codable {
    /// Audio of whatever is playing on the iPhone (YouTube, Safari, TikTok…).
    case otherApps
    /// The microphone — for a TV, laptop or person in the room.
    case microphone

    var id: String { rawValue }
    var title: String {
        switch self {
        case .otherApps: "Videos on this iPhone"
        case .microphone: "Microphone (nearby audio)"
        }
    }
}

#if canImport(ScreenCaptureKit)
@available(iOS 27.0, *)
typealias ScreenCaptureSourceType = ScreenCaptureAudioSource
#else
/// Simulator / SDKs without ScreenCaptureKit.
final class ScreenCaptureSourceType: AudioSource {
    var onSamples: (([Float]) -> Void)?
    var onEnded: ((Error?) -> Void)?
    func start() async throws { throw CaptureError.screenCaptureUnavailable }
    func stop() {}
}
#endif
