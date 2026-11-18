import AVFoundation
import Speech
import Translation

/// Apple-native path: SpeechAnalyzer/SpeechTranscriber (iOS 26) streams a live
/// transcript, Translation framework turns it into English. Everything runs
/// on-device once the language assets are installed. Requires choosing the spoken
/// language — Apple's speech stack has no automatic language identification.
final class ApplePipeline: TranslationPipeline {
    var onUpdate: (@Sendable (SubtitleUpdate) -> Void)?

    private let sourceLocale: Locale
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private let translator: Translator
    private let state = UpdateState()
    private var stabilizer = StreamingStabilizer()
    private let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Shared.sampleRate, channels: 1, interleaved: false)!

    /// false = Steady subtitles: only finished sentences are produced.
    private let partials: Bool

    init(sourceLocale: Locale, partials: Bool = true) {
        self.sourceLocale = sourceLocale
        self.partials = partials
        translator = Translator(source: sourceLocale.language)
    }

    func start() async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: sourceLocale) else {
            throw PipelineError.unsupportedLanguage(sourceLocale.localizedString(forIdentifier: sourceLocale.identifier) ?? sourceLocale.identifier)
        }
        // Live guesses as early as possible: volatile results, biased toward speed.
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [])
        self.transcriber = transcriber

        if !(await AssetInventory.reservedLocales).contains(where: { $0.identifier == locale.identifier }) {
            let reserved = await AssetInventory.reservedLocales
            if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
                _ = await AssetInventory.release(reservedLocale: oldest)
            }
            _ = try await AssetInventory.reserve(locale: locale)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            emit(status: "Downloading Apple speech model…")
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        self.analyzer = analyzer
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: srcFormat) ?? srcFormat
        analyzerFormat = format
        if format != srcFormat { converter = AVAudioConverter(from: srcFormat, to: format) }
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        input = continuation
        try await analyzer.start(inputSequence: stream)

        let lang = sourceLocale.language.languageCode?.identifier
        await state.setLanguage(lang)
        // The first translation of a session takes ~1 s longer; do it now, not on line one.
        Task { [translator] in _ = await translator.probe() }
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    await self.handle(text: text, isFinal: result.isFinal)
                }
            } catch {
                self?.emit(status: "Speech recognition stopped: \(error.localizedDescription)")
            }
        }
        emit(status: nil)
    }

    func append(_ samples: [Float]) {
        guard let input, let buffer = makeBuffer(samples) else { return }
        input.yield(AnalyzerInput(buffer: buffer))
    }

    func stop() async {
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
    }

    // MARK: Private

    private func handle(text: String, isFinal: Bool) async {
        guard !text.isEmpty else { return }
        if isFinal {
            // Apple finalises several sentences at once; subtitles show one at a time.
            // Clauses already shown from the live guesses are not repeated.
            guard let plan = stabilizer.finish(text) else { return }
            if plan.replacesClauses > 0 { await state.dropLast(plan.replacesClauses) }
            for sentence in Self.sentences(in: plan.text) {
                let english = await translator.translate(sentence)
                await state.setOriginal(sentence)
                let update = await state.commit(english)
                onUpdate?(update)
            }
        } else {
            // Steady mode shows finished lines only; skip the tentative work entirely.
            guard partials else { return }
            // A clause both of the last two guesses agree on becomes a line right away.
            if let clause = stabilizer.takeSettledClause(from: text) {
                stabilizer.noteClauseCommitted()
                let english = await translator.translate(clause)
                await state.setOriginal(clause)
                onUpdate?(await state.commit(english))
            }
            // Translate the rest at most ~3×/s; drop stale requests.
            guard let rest = stabilizer.remainder(of: text)?.trimmingCharacters(in: .whitespaces), !rest.isEmpty,
                  await state.shouldTranslateTentative() else { return }
            let english = await translator.translate(rest)
            await state.setOriginal(rest)
            let update = await state.setTentative(stabilizer.visibleGuess(english))
            onUpdate?(update)
        }
    }

    /// Splits on sentence-ending punctuation (。！？.!?), keeping the mark.
    static func sentences(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "。！？.!?".contains(ch) {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    private func emit(status: String?) {
        Task { [state, onUpdate] in onUpdate?(await state.setStatus(status)) }
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let src = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        guard let converter, let format = analyzerFormat else { return src }
        let cap = AVAudioFrameCount(Double(samples.count) * format.sampleRate / srcFormat.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return src
        }
        return error == nil ? out : nil
    }
}

/// Holds the latest subtitle state; serialises updates from concurrent tasks.
actor UpdateState {
    private var update = SubtitleUpdate()
    private var lastTentativeAt = Date.distantPast
    private let maxLines = 6

    func setLanguage(_ code: String?) { update.sourceLanguage = code }

    func setOriginal(_ text: String) { update.original = text }

    /// Removes the newest committed lines (clause lines superseded by a rewritten sentence).
    func dropLast(_ n: Int) { update.committed.removeLast(min(n, update.committed.count)) }

    func setStatus(_ s: String?) -> SubtitleUpdate { update.status = s; return update }

    func commit(_ text: String) -> SubtitleUpdate {
        update.tentative = ""
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, update.committed.last != t {
            update.committed.append(t)
            if update.committed.count > maxLines { update.committed.removeFirst(update.committed.count - maxLines) }
        }
        update.status = nil
        return update
    }

    func setTentative(_ text: String) -> SubtitleUpdate {
        update.tentative = text
        update.status = nil
        return update
    }

    func setDetectedLanguage(_ code: String?) -> SubtitleUpdate {
        update.sourceLanguage = code
        return update
    }

    func shouldTranslateTentative() -> Bool {
        guard Date().timeIntervalSince(lastTentativeAt) > 0.33 else { return false }
        lastTentativeAt = Date()
        return true
    }

    func current() -> SubtitleUpdate { update }
}

/// Wraps an Apple Translation session for one source language → English.
/// If the language pack isn't installed, returns the original text so the user
/// still sees something (and the UI points them to the download screen).
actor Translator {
    private let source: Locale.Language
    private let target = Locale.Language(identifier: "en")
    private var session: TranslationSession?
    private(set) var available = true

    init(source: Locale.Language) { self.source = source }

    var isNoOp: Bool { source.languageCode == target.languageCode }

    /// Test harness only: translate through another process (see Tests/Harness).
    nonisolated(unsafe) static var externalBackend: ((_ source: String, _ text: String) async -> String?)?

    func translate(_ text: String) async -> String {
        if isNoOp || !available { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let backend = Self.externalBackend {
            guard !trimmed.isEmpty else { return text }
            return await backend(source.minimalIdentifier, trimmed) ?? text
        }
        if session == nil {
            // LanguageAvailability.status can report an installed pack as only
            // "supported" (seen on macOS 26 from a background actor), so it is a hint,
            // not a gate: open the session and let a real translation decide.
            session = TranslationSession(installedSource: source, target: target)
        }
        guard !trimmed.isEmpty else { return text }
        do {
            let english = try await session!.translate(trimmed).targetText
            failures = 0
            return english
        } catch {
            debug("translate error: \(error)")
            failures += 1
            // Two failures in a row: the pack really isn't there. Show the original
            // words rather than retrying every line.
            if failures >= 2 { available = false; session = nil }
            return text
        }
    }

    /// Checks with one short real translation (first call only).
    func probe() async -> Bool {
        if isNoOp { return true }
        if probed == true { return true }
        // A "no" is never final: the pack may have just been installed. Retry at most every 5 s.
        if probed == false, let at = probedAt, Date().timeIntervalSince(at) < 5 { return false }
        available = true; failures = 0; session = nil
        _ = await translate("はい")  // a short phrase; succeeds whenever a pack is installed
        let ok = available && failures == 0
        probed = ok; probedAt = Date()
        if !ok { available = true; failures = 0; session = nil }
        return ok
    }

    private var failures = 0
    private var probed: Bool?
    private var probedAt: Date?

    private func debug(_ s: String) {
        if ProcessInfo.processInfo.environment["LIVESUBS_DEBUG"] != nil { print("  " + s) }
    }
}

enum PipelineError: LocalizedError {
    case unsupportedLanguage(String)
    case modelMissing
    case modelLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let l): "Apple speech recognition doesn't support \(l) on this device. Switch to the Whisper engine for automatic language detection."
        case .modelMissing: "Download a Whisper model first (Settings ▸ Models)."
        case .modelLoadFailed(let m): "Couldn't load the speech model: \(m)"
        }
    }
}
