import ReplayKit

/// ReplayKit Broadcast Upload Extension.
///
/// iOS runs this in its own small process while the user has "LiveSubs" selected in
/// the Screen Recording control. It receives the system-wide app audio mix
/// (`.audioApp`), converts it to 16 kHz mono and writes it into a shared memory-mapped
/// ring buffer. All AI work happens in the main app — this extension stays tiny to
/// respect the extension memory limit. Video frames are ignored and never stored.
final class SampleHandler: RPBroadcastSampleHandler {
    private let converter = AppAudioConverter()
    private var ring: AudioRingBuffer?
    private let notifier = DarwinNotifier.shared
    private var lastPing: CFAbsoluteTime = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        if let url = Shared.ringBufferURL {
            ring = AudioRingBuffer(url: url)
            ring?.beginSession()
        }
        notifier.observe(Shared.Note.requestStop) { [weak self] in
            let error = NSError(domain: "LiveSubs", code: 0, userInfo: [
                NSLocalizedFailureReasonErrorKey: "Live subtitles stopped."
            ])
            self?.finishBroadcastWithError(error)
        }
        notifier.post(Shared.Note.broadcastStarted)
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        notifier.post(Shared.Note.broadcastStopped)
        ring = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .audioApp, let ring else { return }
        guard let samples = converter.convert(sampleBuffer) else { return }
        samples.withUnsafeBufferPointer { ring.write($0) }

        // A light heartbeat (≤5/s) so the app can wake its reader promptly.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastPing > 0.2 {
            lastPing = now
            notifier.post(Shared.Note.audioAvailable)
        }
    }
}
