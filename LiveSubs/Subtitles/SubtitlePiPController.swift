import AVFoundation
import AVKit
import Combine
import UIKit

/// Floating subtitle window built on Picture-in-Picture.
///
/// iOS does not let third-party apps draw overlays on top of other apps. The one
/// sanctioned floating surface is PiP, so we render captions as video frames into an
/// AVSampleBufferDisplayLayer and hand it to AVPictureInPictureController. While PiP
/// is active iOS also keeps this app running in the background, which is what lets
/// transcription continue while you watch YouTube/TikTok/Safari.
@MainActor
final class SubtitlePiPController: NSObject, ObservableObject {
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false
    @Published private(set) var lastError: String?

    /// Called when the user taps play/pause inside the PiP window.
    var onPlayPauseToggled: ((_ playing: Bool) -> Void)?
    /// Called when the user closes the PiP window (×).
    var onClosedByUser: (() -> Void)?

    let displayLayer = AVSampleBufferDisplayLayer()
    private let renderer = SubtitleFrameRenderer()
    private var pip: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var keepAlive: Timer?
    private var content = SubtitleFrameRenderer.Content(committed: "Subtitles appear here in English, as people speak.", tentative: "", badge: "")
    private var paused = false
    private var stoppingProgrammatically = false

    var aspectRatio: CGFloat { renderer.size.width / renderer.size.height }

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    /// Must be called once the display layer is inside an on-screen view.
    func prepare() {
        // The in-app preview works even where PiP doesn't (e.g. Simulator).
        if keepAlive == nil {
            render()
            startKeepAlive()
        }
        guard pip == nil else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            lastError = "Picture in Picture isn't supported on this device — subtitles show in-app only."
            return
        }
        configureAudioSession()
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // Swiping home while subtitles are on automatically floats them.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pip = controller
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
    }

    func start() {
        guard let pip else { return }
        configureAudioSession()
        render()
        if !pip.isPictureInPictureActive { pip.startPictureInPicture() }
    }

    func stop() {
        guard let pip, pip.isPictureInPictureActive else { return }
        stoppingProgrammatically = true
        pip.stopPictureInPicture()
    }

    func update(_ newContent: SubtitleFrameRenderer.Content) {
        guard newContent != content else { return }
        content = newContent
        render()
    }

    func setPaused(_ value: Bool) {
        paused = value
        pip?.invalidatePlaybackState()
    }

    // MARK: Private

    private func configureAudioSession() {
        // .playback is required for PiP; .mixWithOthers so we never interrupt the
        // video the user is watching in another app.
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playAndRecord { // mic mode configures its own category
                try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            }
            try session.setActive(true)
        } catch {
            lastError = "Audio session: \(error.localizedDescription)"
        }
    }

    private func render() {
        guard let buffer = renderer.makeSampleBuffer(content) else { return }
        let r = displayLayer.sampleBufferRenderer
        if r.status == .failed { r.flush() }
        r.enqueue(buffer)
    }

    /// Re-enqueue the current frame periodically so the PiP layer never goes stale
    /// (e.g. after the system flushes it on app-state transitions).
    private func startKeepAlive() {
        keepAlive?.invalidate()
        keepAlive = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension SubtitlePiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = true
            self.lastError = nil
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = false
            if !self.stoppingProgrammatically { self.onClosedByUser?() }
            self.stoppingProgrammatically = false
        }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in self.lastError = "Couldn't open floating subtitles: \(error.localizedDescription)" }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension SubtitlePiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in
            self.paused = !playing
            self.onPlayPauseToggled?(playing)
            c.invalidatePlaybackState()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        // Live content: no scrubber.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { paused }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
