import AVFoundation
import Foundation
import Speech
import WhisperKit

/// One recognised line, in seconds relative to the audio handed in.
struct TimedLine: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// Speech → text in the spoken language (translation happens later). Implementations:
/// Parakeet (Japanese, fastest), Apple's recogniser (many languages, fast, nothing to
/// download), Whisper (any language, slowest; optional accuracy choice).
protocol SpeechRecognizer: Actor {
    nonisolated var name: String { get }
    func supports(_ language: String) async -> Bool
    func transcribe(_ samples: [Float], language: String) async throws -> [TimedLine]
    func unload() async
}

/// Spoken-language identification for when the viewer picked more than one language.
protocol LanguageDetector: Actor {
    func detect(_ samples: [Float]) async throws -> String
    func unload() async
}

// MARK: - Pause-based utterances (shared)

enum Utterances {
    /// Splits audio at pauses into utterances of roughly 1–15 s, so recognisers that
    /// mishandle several sentences at once see one at a time. Ranges are sample indices.
    static func split(_ s: [Float], rate: Int = 16_000) -> [Range<Int>] {
        let hop = rate / 50                                   // 20 ms frames
        guard s.count > hop * 10 else { return s.isEmpty ? [] : [0..<s.count] }
        var energies: [Float] = []
        var i = 0
        while i + hop <= s.count {
            var e: Float = 0
            for k in i..<(i + hop) { e += s[k] * s[k] }
            energies.append(sqrt(e / Float(hop))); i += hop
        }
        let sorted = energies.sorted()
        let floor = sorted[sorted.count / 10], loud = sorted[sorted.count * 9 / 10]
        let threshold = max(0.004, floor + (loud - floor) * 0.12)
        // Speech frames, then runs separated by ≥ 300 ms of quiet.
        var runs: [Range<Int>] = []
        var start: Int?, quiet = 0
        for (f, e) in energies.enumerated() {
            if e > threshold { if start == nil { start = f }; quiet = 0 }
            else if let s0 = start { quiet += 1; if quiet >= 15 { runs.append(s0..<(f - quiet + 1)); start = nil; quiet = 0 } }
        }
        if let s0 = start { runs.append(s0..<energies.count) }
        // Merge short pieces into neighbours; split anything over 15 s at its quietest frame.
        var merged: [Range<Int>] = []
        for r in runs {
            if let last = merged.last, (r.count < 50 || last.count < 50), r.upperBound - last.lowerBound < 750 {
                merged[merged.count - 1] = last.lowerBound..<r.upperBound
            } else { merged.append(r) }
        }
        var out: [Range<Int>] = []
        for r in merged {
            var piece = r
            while piece.count > 750 {
                let search = (piece.lowerBound + 300)..<(piece.lowerBound + 700)
                let cut = search.min { energies[$0] < energies[$1] } ?? (piece.lowerBound + 600)
                out.append(piece.lowerBound..<cut); piece = cut..<piece.upperBound
            }
            out.append(piece)
        }
        // Frames → samples, with 150 ms of padding either side.
        let pad = rate * 15 / 100
        return out.map { max(0, $0.lowerBound * hop - pad)..<min(s.count, $0.upperBound * hop + pad) }
    }
}

// MARK: - Whisper

actor WhisperRecognizer: SpeechRecognizer, LanguageDetector {
    nonisolated let name: String
    private let model: WhisperModel
    private var kit: WhisperKit?

    init(model: WhisperModel) {
        self.model = model
        name = "Whisper " + model.displayName.replacingOccurrences(of: " (recommended)", with: "")
    }

    private func load() async throws -> WhisperKit {
        if let kit { return kit }
        guard let folder = ModelStore.localFolder(for: model) else { throw PipelineError.modelMissing }
        let k = try await WhisperKit(WhisperKitConfig(
            model: model.variant, downloadBase: ModelStore.baseURL, modelFolder: folder.path,
            tokenizerFolder: ModelStore.baseURL, computeOptions: ModelStore.computeOptions,
            verbose: false, logLevel: .error, prewarm: false, load: true, download: false))
        kit = k
        return k
    }

    func supports(_ language: String) async -> Bool { true }

    func transcribe(_ samples: [Float], language: String) async throws -> [TimedLine] {
        let kit = try await load()
        let opts = DecodingOptions(task: .transcribe, language: language, temperature: 0, temperatureFallbackCount: 3,
                                   usePrefillPrompt: true, detectLanguage: false, skipSpecialTokens: true,
                                   withoutTimestamps: false, windowClipTime: 0, suppressBlank: true,
                                   compressionRatioThreshold: 2.4, logProbThreshold: -1.0, noSpeechThreshold: 0.6)
        return try await kit.transcribe(audioArray: samples, decodeOptions: opts)
            .flatMap(\.segments)
            .filter { $0.noSpeechProb < 0.6 || $0.avgLogprob > -0.8 }
            .compactMap { seg in
                let text = HallucinationFilter.clean(seg.text)
                return text.isEmpty ? nil : TimedLine(start: Double(seg.start), end: Double(seg.end), text: text)
            }
    }

    func detect(_ samples: [Float]) async throws -> String {
        try await load().detectLangauge(audioArray: samples).language
    }

    func unload() async { await kit?.unloadModels(); kit = nil }
}

// MARK: - Apple's recogniser (SpeechTranscriber)

actor AppleRecognizer: SpeechRecognizer {
    nonisolated let name = "Apple's recogniser"
    private var installed = Set<String>()

    static func locale(for code: String) -> Locale? {
        let map = ["ja": "ja_JP", "ko": "ko_KR", "es": "es_ES", "fr": "fr_FR", "de": "de_DE", "it": "it_IT",
                   "pt": "pt_BR", "zh": "zh_CN", "yue": "yue_CN", "en": "en_US"]
        return map[code].map(Locale.init(identifier:))
    }

    func supports(_ language: String) async -> Bool {
        guard let l = Self.locale(for: language) else { return false }
        return await SpeechTranscriber.supportedLocale(equivalentTo: l) != nil
    }

    func transcribe(_ samples: [Float], language: String) async throws -> [TimedLine] {
        guard let wanted = Self.locale(for: language),
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
        else { throw PipelineError.unsupportedLanguage(language) }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if !installed.contains(language) {
            // Apps must reserve a language before using Apple's on-device speech model for it;
            // free the oldest reservation if the system limit is reached.
            let reserved = await AssetInventory.reservedLocales
            if reserved.count >= AssetInventory.maximumReservedLocales,
               !reserved.contains(where: { $0.language.languageCode == locale.language.languageCode }), let oldest = reserved.first {
                _ = await AssetInventory.release(reservedLocale: oldest)
            }
            _ = try? await AssetInventory.reserve(locale: locale)    // harmless if already reserved
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()      // Apple's speech model for this language, once
            }
            installed.insert(language)
        }
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: src) ?? src
        guard let buffer = Self.buffer(samples, format: src, to: format) else { return [] }

        let collector = Task { () throws -> [TimedLine] in
            var lines: [TimedLine] = []
            for try await r in transcriber.results where r.isFinal {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lines.append(TimedLine(start: r.range.start.seconds, end: r.range.end.seconds, text: text))
            }
            return lines
        }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        input.yield(AnalyzerInput(buffer: buffer))
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value.flatMap(Self.sentences)
    }

    /// Apple sometimes finalises several sentences as one result: one line each, with
    /// the time shared out by length.
    private static func sentences(_ line: TimedLine) -> [TimedLine] {
        let parts = ApplePipeline.sentences(in: line.text)
        guard parts.count > 1 else { return [line] }
        let total = Double(parts.reduce(0) { $0 + $1.count })
        var t = line.start
        return parts.map { p in
            let d = (line.end - line.start) * Double(p.count) / total
            defer { t += d }
            return TimedLine(start: t, end: t + d, text: p)
        }
    }

    private static func buffer(_ s: [Float], format src: AVAudioFormat, to dst: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(s.count)) else { return nil }
        b.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: s.count) }
        if src == dst { return b }
        guard let conv = AVAudioConverter(from: src, to: dst),
              let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: AVAudioFrameCount(Double(s.count) * dst.sampleRate / src.sampleRate) + 1024)
        else { return nil }
        var fed = false
        conv.convert(to: out, error: nil) { _, st in if fed { st.pointee = .endOfStream; return nil }; fed = true; st.pointee = .haveData; return b }
        return out
    }

    func unload() async {}
}
