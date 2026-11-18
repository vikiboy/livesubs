import Foundation

/// Reads system app-audio captured by the ReplayKit broadcast extension from the
/// shared memory-mapped ring buffer.
final class BroadcastAudioSource: AudioSource {
    var onSamples: (([Float]) -> Void)?

    private let queue = DispatchQueue(label: "livesubs.broadcast.reader", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var ring: AudioRingBuffer?
    private var readIndex: UInt64 = 0
    private var sessionID: UInt64 = 0

    func start() async throws {
        guard let url = Shared.ringBufferURL else { throw CaptureError.appGroupMissing }
        guard let ring = AudioRingBuffer(url: url) else { throw CaptureError.ringBufferUnavailable }
        queue.sync {
            self.ring = ring
            self.sessionID = ring.sessionID
            self.readIndex = ring.writeIndex // only translate audio from now on
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { self.ring = nil }
    }

    private func drain() {
        guard let ring else { return }
        if ring.sessionID != sessionID { // a new broadcast started
            sessionID = ring.sessionID
            readIndex = 0
        }
        let samples = ring.read(from: &readIndex)
        if !samples.isEmpty { onSamples?(samples) }
    }
}

enum CaptureError: LocalizedError {
    case appGroupMissing, ringBufferUnavailable, microphoneDenied, screenCaptureUnavailable, sampleMissing

    var errorDescription: String? {
        switch self {
        case .appGroupMissing: "The App Group isn't configured. Check Config/Signing.xcconfig and re-run xcodegen."
        case .ringBufferUnavailable: "Couldn't open the shared audio buffer."
        case .microphoneDenied: "Microphone access is off. Enable it in Settings ▸ LiveSubs."
        case .screenCaptureUnavailable: "Screen audio capture isn't available on this device."
        case .sampleMissing: "The practice clip is missing from this build."
        }
    }
}
