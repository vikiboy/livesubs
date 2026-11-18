#if canImport(ScreenCaptureKit)
import CoreMedia
import Foundation
import ScreenCaptureKit

/// iOS 27+: captures the system audio mix in-process with ScreenCaptureKit.
///
/// The user approves capture once per session in the system picker (the same
/// "Screen Recording" consent iOS shows for any recorder). The `screen-capture`
/// background mode keeps the stream — and therefore this app — running while the
/// user is in another app. No broadcast extension, no extension memory limit.
@available(iOS 27.0, *)
final class ScreenCaptureAudioSource: NSObject, AudioSource, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    var onSamples: (([Float]) -> Void)?
    /// Called if capture ends for any reason other than `stop()`.
    var onEnded: ((Error?) -> Void)?

    private let picker = SCContentSharingPicker.shared
    private var stream: SCStream?
    private let converter = AppAudioConverter()
    private let queue = DispatchQueue(label: "livesubs.sck.audio", qos: .userInitiated)
    private var pickContinuation: CheckedContinuation<SCContentFilter, Error>?
    private var stopping = false

    static var isAvailable: Bool { SCContentSharingPicker.shared.isAvailable }

    func start() async throws {
        guard Self.isAvailable else { throw CaptureError.screenCaptureUnavailable }
        stopping = false
        picker.add(self)
        picker.isActive = true
        var config = SCContentSharingPickerConfiguration()
        config.showsMicrophoneControl = false
        picker.defaultConfiguration = config

        let filter: SCContentFilter = try await withCheckedThrowingContinuation { cont in
            pickContinuation = cont
            Task { @MainActor in self.picker.present() }
        }

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true
        // We never use the video; ask for the smallest frames the system allows.
        cfg.width = 16
        cfg.height = 16

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        stopping = true
        stream?.stopCapture { _ in }
        stream = nil
        picker.remove(self)
        picker.isActive = false
    }

    // MARK: SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        pickContinuation?.resume(throwing: CancellationError())
        pickContinuation = nil
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        pickContinuation?.resume(returning: filter)
        pickContinuation = nil
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        pickContinuation?.resume(throwing: error)
        pickContinuation = nil
    }

    // MARK: SCStreamOutput / Delegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let samples = converter.convert(sampleBuffer) else { return }
        onSamples?(samples)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        if !stopping { onEnded?(error) }
    }
}
#endif
