import Foundation
import WhisperKit

/// Whisper path (WhisperKit, CoreML on the Neural Engine):
/// VAD-segmented chunks → Whisper with automatic language identification →
/// English, either via Whisper's built-in translate task or (optionally, and when
/// the language pack is installed) Apple's Translation framework for higher quality.
final class WhisperPipeline: TranslationPipeline {
    var onUpdate: (@Sendable (SubtitleUpdate) -> Void)?

    struct Options {
        var model: WhisperModel
        /// nil = auto-detect.
        var forcedLanguage: String?
        var preferAppleTranslation: Bool
        /// false = Steady subtitles: skip the provisional passes (also saves battery).
        var partials: Bool = true
        /// Live-caption streaming: passes every 0.5 s, settled clauses committed early,
        /// the unsettled English tail masked. See StreamingStabilizer.
        var streaming: Bool = true
    }

    private let options: Options
    private let segmenter = SpeechSegmenter()
    private let segQueue = DispatchQueue(label: "livesubs.segmenter", qos: .userInitiated)
    private let worker: WhisperWorker

    init(options: Options) {
        self.options = options
        worker = WhisperWorker(options: options)
        if options.streaming && options.partials {
            segmenter.config.partialInterval = 0.5
            segmenter.config.minSpeech = 0.5
            if let s = ProcessInfo.processInfo.environment["LIVESUBS_END_SILENCE"], let v = Double(s) {
                segmenter.config.endSilence = v
            }
        }
    }

    func start() async throws {
        let onUpdate = self.onUpdate
        onUpdate?(SubtitleUpdate(status: "Loading \(options.model.displayName)…"))
        try await worker.load()
        await worker.setUpdateHandler(onUpdate)
        await worker.prewarmTranslation()
        await worker.run()
        onUpdate?(SubtitleUpdate(status: "Listening…"))
    }

    func append(_ samples: [Float]) {
        segQueue.async { [segmenter, worker] in
            let events = segmenter.append(samples)
            guard !events.isEmpty else { return }
            Task { await worker.enqueue(events) }
        }
    }

    func stop() async {
        let tail: SpeechSegmenter.Event? = segQueue.sync { segmenter.flush() }
        if let tail { await worker.enqueue([tail]) }
        await worker.stop()
    }
}

/// Runs one Whisper inference at a time. Finals are processed in order; for
/// partials only the newest one matters, so older ones are dropped.
actor WhisperWorker {
    private let options: WhisperPipeline.Options
    private var whisper: WhisperKit?
    private var finals: [[Float]] = []
    private var latestPartial: [Float]?
    private var loopTask: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var onUpdate: (@Sendable (SubtitleUpdate) -> Void)?
    private let state = UpdateState()
    private var language = LanguageTracker()
    private var appleTranslators: [String: Translator] = [:]
    private var running = false
    private var finalCount = 0
    /// Newest partial English for the utterance in progress; the fallback if the
    /// final pass fails Whisper's quality gates and returns nothing.
    private var lastPartialText = ""
    private var stabilizer = StreamingStabilizer()

    init(options: WhisperPipeline.Options) {
        self.options = options
        if let forced = options.forcedLanguage { language.force(forced) }
    }

    func setUpdateHandler(_ h: (@Sendable (SubtitleUpdate) -> Void)?) { onUpdate = h }

    func load() async throws {
        guard let folder = ModelStore.localFolder(for: options.model) else { throw PipelineError.modelMissing }
        await ModelWarmup.wait()
        do {
            let config = WhisperKitConfig(
                model: options.model.variant,
                downloadBase: ModelStore.baseURL,
                modelFolder: folder.path,
                tokenizerFolder: ModelStore.baseURL,
                computeOptions: ModelStore.computeOptions,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false
            )
            whisper = try await WhisperKit(config)
        } catch {
            throw PipelineError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Opens the Apple translation session early when the language is already known.
    func prewarmTranslation() {
        guard let lang = options.forcedLanguage, lang != "en",
              options.preferAppleTranslation || !options.model.supportsTranslate else { return }
        let t = translator(for: lang)
        Task { _ = await t.probe() }
    }

    func run() {
        running = true
        loopTask = Task { await self.loop() }
    }

    func stop() async {
        running = false
        wake?.resume(); wake = nil
        await loopTask?.value
        loopTask = nil
        await whisper?.unloadModels()
        whisper = nil
    }

    func enqueue(_ events: [SpeechSegmenter.Event]) {
        for e in events {
            switch e {
            case .final(let a): finals.append(a); latestPartial = nil
            case .partial(let a): if options.partials { latestPartial = a }
            }
        }
        // Never let a backlog build up: if inference is slower than real time,
        // merge the oldest finals so latency stays bounded.
        if finals.count > 3 {
            let merged = finals.prefix(finals.count - 2).flatMap { $0 }
            finals = [Array(merged.suffix(Int(Shared.sampleRate * 25)))] + finals.suffix(2)
        }
        wake?.resume(); wake = nil
    }

    private func loop() async {
        while running || !finals.isEmpty {
            if !finals.isEmpty {
                let audio = finals.removeFirst()
                await process(audio, isFinal: true)
            } else if let p = latestPartial {
                latestPartial = nil
                await process(p, isFinal: false)
            } else if running {
                await withCheckedContinuation { wake = $0 }
            }
        }
    }

    private func process(_ audio: [Float], isFinal: Bool) async {
        guard let whisper else { return }
        let duration = Double(audio.count) / Shared.sampleRate
        // Short partial snippets are too little evidence to re-detect language.
        // Finals re-check the language every 4th segment so a switch is noticed.
        var lockedLang = language.locked
        if isFinal { finalCount += 1; if finalCount % 4 == 0, !language.isForced { lockedLang = nil } }
        let lang: String? = lockedLang ?? (isFinal || duration > 2 ? nil : language.best)
        let englishSource = lang == "en"

        // Plan: Apple Translation (if preferred & installed for this language) needs
        // a source-language transcript; otherwise ask Whisper to translate directly.
        var useApple = false
        if options.preferAppleTranslation || !options.model.supportsTranslate, let lang, !englishSource {
            useApple = await translator(for: lang).isAvailable
        }
        // Models without a translate head (e.g. large-v3 turbo) fall back to showing
        // the original-language transcript if no Apple language pack is installed.
        let task: DecodingTask = (englishSource || useApple || !options.model.supportsTranslate) ? .transcribe : .translate

        var opts = DecodingOptions(
            task: task,
            language: lang,
            temperature: 0,
            temperatureFallbackCount: isFinal ? 3 : 0,
            usePrefillPrompt: true,
            detectLanguage: lang == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // Live chunks end exactly where speech stops; WhisperKit's default 1 s
            // end-of-window clip (meant for long files) would cut the newest words.
            windowClipTime: 0,
            suppressBlank: true,
            // Partials are provisional: accept the best guess rather than discarding
            // it; finals keep the quality gates and temperature fallback.
            compressionRatioThreshold: isFinal ? 2.4 : nil,
            logProbThreshold: isFinal ? -1.0 : nil,
            firstTokenLogProbThreshold: isFinal ? -1.5 : nil,
            noSpeechThreshold: 0.6
        )
        opts.concurrentWorkerCount = 1

        do {
            let results = try await whisper.transcribe(audioArray: audio, decodeOptions: opts)
            guard let first = results.first else { return }
            let silent = first.segments.allSatisfy { $0.noSpeechProb > 0.6 && $0.avgLogprob < -0.8 }
            var text = silent ? "" : HallucinationFilter.clean(results.map(\.text).joined(separator: " "))
            let detected = first.language
            if ProcessInfo.processInfo.environment["LIVESUBS_DEBUG"] != nil {
                print(String(format: "  whisper %@ %.1fs lang=%@ task=%@ segs=%d silent=%@ raw=%@", isFinal ? "FINAL" : "partial", duration,
                             detected, "\(task)", first.segments.count, "\(silent)", results.map(\.text).joined(separator: " ")))
            }
            if isFinal, lang == nil, duration >= 1.5 { language.vote(detected) }
            let spoken = lang ?? detected

            _ = await state.setDetectedLanguage(spoken)
            let viaApple: Translator? = await {
                guard task == .transcribe, spoken != "en", !text.isEmpty else { return nil }
                let t = translator(for: spoken)
                return await t.isAvailable ? t : nil
            }()

            if let t = viaApple {
                // Transcript in the spoken language → stabilise → Apple translates.
                let source = text
                if isFinal {
                    guard let plan = stabilizer.finish(source) else { return }
                    if plan.replacesClauses > 0 { await state.dropLast(plan.replacesClauses) }
                    let english = plan.text.isEmpty ? "" : await t.translate(plan.text)
                    await state.setOriginal(plan.text)
                    lastPartialText = ""
                    onUpdate?(await state.commit(english))
                } else {
                    if options.streaming, let clause = stabilizer.takeSettledClause(from: source) {
                        stabilizer.noteClauseCommitted()
                        let english = await t.translate(clause)
                        await state.setOriginal(clause)
                        onUpdate?(await state.commit(english))
                    }
                    guard let rest = stabilizer.remainder(of: source)?.trimmingCharacters(in: .whitespaces),
                          !rest.isEmpty else { return }
                    let english = await t.translate(rest)
                    let shown = options.streaming ? stabilizer.visibleGuess(english) : english
                    if !english.isEmpty { lastPartialText = english }
                    await state.setOriginal(rest)
                    onUpdate?(await state.setTentative(shown))
                }
                return
            }

            // Whisper translated (or the speech is English): only the English side can be steadied.
            let update: SubtitleUpdate
            if isFinal {
                stabilizer.reset()
                await state.setOriginal("")
                if text.isEmpty, !silent { text = lastPartialText }
                lastPartialText = ""
                update = await state.commit(text)
            } else {
                if !text.isEmpty { lastPartialText = text }
                update = await state.setTentative(options.streaming ? stabilizer.visibleGuess(text) : text)
            }
            onUpdate?(update)
        } catch {
            onUpdate?(await state.setStatus("Recognition error: \(error.localizedDescription)"))
        }
    }

    private func translator(for code: String) -> Translator {
        if let t = appleTranslators[code] { return t }
        let t = Translator(source: Locale.Language(identifier: code))
        appleTranslators[code] = t
        return t
    }
}

extension Translator {
    /// True when the source→English pack is installed (or source is English).
    var isAvailable: Bool {
        get async { await probe() }
    }
}

/// Stabilises Whisper's per-segment language guesses: lock onto a language once
/// two of the last three confident segments agree; unlock if it changes.
struct LanguageTracker {
    private(set) var locked: String?
    private var history: [String] = []
    private var forced = false
    var isForced: Bool { forced }

    var best: String? {
        let counts = Dictionary(grouping: history, by: { $0 }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }

    mutating func force(_ code: String) { locked = code; forced = true }

    mutating func vote(_ code: String) {
        guard !forced else { return }
        history.append(code)
        if history.count > 3 { history.removeFirst() }
        if let b = best, history.filter({ $0 == b }).count >= 2 { locked = b }
        // No consensus at all → go back to per-segment detection.
        if history.count == 3, Set(history).count == 3 { locked = nil }
    }
}
