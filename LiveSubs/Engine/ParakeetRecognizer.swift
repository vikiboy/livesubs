import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT-CTC 0.6B Japanese (CC-BY-4.0) on the Neural Engine, via FluidAudio.
/// In our FLEURS test: 3.9% character errors at ~220× real time on a Mac (Whisper Turbo:
/// 3.2% at 15×). It can drop sentences when a window holds several, so it is fed one
/// pause-cut utterance at a time. (FluidAudio also ships Alibaba models; LiveSubs never
/// loads or downloads them.)
actor ParakeetRecognizer: SpeechRecognizer {
    nonisolated let name = "Parakeet"
    private var asr: AsrManager?

    static var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .tdtJa), version: .tdtJa)
    }

    /// One-time download (~0.6 GB), with progress 0…1.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await AsrModels.download(version: .tdtJa, progressHandler: { p in progress(p.fractionCompleted) })
    }

    /// Loads once so iOS prepares the Neural Engine copy (after downloads and installs).
    static func warmUp() async {
        guard isDownloaded else { return }
        _ = try? await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: .tdtJa), version: .tdtJa)
    }

    func supports(_ language: String) async -> Bool { language == "ja" && Self.isDownloaded }

    private func load() async throws -> AsrManager {
        if let asr { return asr }
        let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: .tdtJa), version: .tdtJa)
        let m = AsrManager(models: models)
        asr = m
        return m
    }

    func transcribe(_ samples: [Float], language: String) async throws -> [TimedLine] {
        let asr = try await load()
        var lines: [TimedLine] = []
        for range in Utterances.split(samples) where range.count > 16_000 / 4 {
            var state = try TdtDecoderState(decoderLayers: 2)
            let text = try await asr.transcribe(Array(samples[range]), decoderState: &state).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(TimedLine(start: Double(range.lowerBound) / 16_000, end: Double(range.upperBound) / 16_000, text: text))
        }
        return lines
    }

    func unload() async { asr = nil }
}
