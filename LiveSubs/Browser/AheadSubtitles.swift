import Foundation

/// One timed subtitle, in video time.
struct Cue: Equatable, Sendable {
    let start: Double
    let end: Double
    var english: String
    var original: String
    /// Spoken language of a line still waiting for translation (its pack wasn't available).
    var untranslated: String? = nil
    /// The literal translation, kept once the line has been rewritten as natural English.
    var literal: String? = nil
    /// Natural-English pass done (or not wanted) for this line.
    var polished = false
}

/// Which stretches of the video already have subtitles (merged, sorted).
struct Coverage {
    private(set) var ranges: [(start: Double, end: Double)] = []

    mutating func insert(_ a: Double, _ b: Double) {
        guard b > a else { return }
        var lo = a, hi = b
        ranges.removeAll { r in
            let touches = r.end >= lo - 0.3 && r.start <= hi + 0.3
            if touches { lo = min(lo, r.start); hi = max(hi, r.end) }
            return touches
        }
        ranges.append((lo, hi))
        ranges.sort { $0.start < $1.start }
    }

    func covers(_ t: Double) -> Bool { ranges.contains { $0.start <= t + 0.05 && t < $0.end } }
    /// End of the covered stretch containing `t`, if any.
    func end(at t: Double) -> Double? { ranges.first { $0.start <= t + 0.05 && t < $0.end }?.end }
    /// First uncovered time at or after `t`.
    func gap(from t: Double) -> Double { end(at: t) ?? t }
    /// Start of the next covered stretch after `t` (where a window starting at `t` should stop).
    func nextStart(after t: Double) -> Double? { ranges.first { $0.start > t + 0.05 }?.start }
    var total: Double { ranges.reduce(0) { $0 + $1.end - $1.start } }
}

/// Audio decoded from the page, placed on the video's own timeline (16 kHz mono).
/// The same stretch can arrive twice (the player's own chunks and the playlist reader);
/// overlaps are tolerated. Everything lives in memory and is dropped once subtitled.
struct AudioTimeline {
    private(set) var runs: [(start: Double, samples: [Float])] = []
    static let rate = Shared.sampleRate

    private static func end(_ r: (start: Double, samples: [Float])) -> Double { r.start + Double(r.samples.count) / rate }

    mutating func add(start: Double, samples: [Float]) {
        guard !samples.isEmpty else { return }
        let new = (start: start, samples: samples)
        let newEnd = Self.end(new)
        // An existing run mostly covering the same time is the same audio: replace it.
        runs.removeAll { r in
            let overlap = min(Self.end(r), newEnd) - max(r.start, start)
            return overlap > 0.5 * min(Self.end(r) - r.start, newEnd - start)
        }
        runs.append(new)
        runs.sort { $0.start < $1.start }
    }

    /// Continuous audio from `time` (small gaps and overlaps bridged), up to `until`.
    func contiguous(from time: Double, until: Double) -> (start: Double, samples: [Float])? {
        var out: [Float] = []
        var cursor = time
        var first: Double?
        for r in runs where Self.end(r) > cursor + 0.01 {
            if r.start > cursor + 0.25 { break }
            let from = max(cursor, r.start)
            let offset = Int((from - r.start) * Self.rate)
            guard offset < r.samples.count else { continue }
            if first == nil { first = from }
            let room = Int((until - cursor) * Self.rate)
            guard room > 0 else { break }
            out += r.samples[offset..<min(r.samples.count, offset + room)]
            cursor = from + Double(r.samples.count - offset) / Self.rate
            if cursor >= until { break }
        }
        guard let first, !out.isEmpty else { return nil }
        return (first, out)
    }

    /// Earliest time ≥ `t` that has audio and isn't covered.
    func firstUncovered(from t: Double, coverage: Coverage) -> Double? {
        for r in runs where Self.end(r) > t {
            var p = max(t, r.start)
            while p < Self.end(r) {
                if !coverage.covers(p) { return p }
                p = coverage.end(at: p) ?? Self.end(r)
            }
        }
        return nil
    }

    /// Start of the next audio after `t` (beyond a gap with no sound), if any.
    /// nil when audio continues right after `t` (any run covers the next 0.25 s).
    func nextAudio(after t: Double) -> Double? {
        if runs.contains(where: { $0.start <= t + 0.25 && Self.end($0) > t + 0.25 }) { return nil }
        return runs.first { $0.start > t + 0.25 }?.start
    }

    /// Seconds of audio waiting for subtitles.
    func pending(_ coverage: Coverage) -> Double {
        runs.reduce(0) { total, r in
            let a = r.start, b = Self.end(r)
            let covered = coverage.ranges.reduce(0) { $0 + max(0, min(b, $1.end) - max(a, $1.start)) }
            return total + max(0, (b - a) - covered)
        }
    }

    mutating func dropCovered(_ coverage: Coverage) {
        runs.removeAll { r in coverage.ranges.contains { $0.start <= r.start + 0.05 && Self.end(r) <= $0.end + 0.05 } }
    }

    mutating func removeAll() { runs.removeAll() }
}

/// Subtitles the whole video ahead of the viewer: first from the playhead onward, then
/// the rest, keeping everything already done, so skipping ahead or back finds lines ready.
actor AheadTranscriber {
    struct Config {
        /// The spoken language, when the viewer fixed it.
        var language: String?
        /// Languages the viewer said they watch: detection chooses among these.
        var candidates: [String] = []
        var preferAppleTranslation = true
        /// Re-translate each line with the refiner (TranslateGemma) for natural English.
        var natural = false
    }

    /// Second-stage translator injected by the app (TranslateGemma), so this engine
    /// doesn't depend on MLX.
    struct Refiner: Sendable {
        let name: String
        let isReady: @Sendable () -> Bool
        let translate: @Sendable (_ text: String, _ language: String) async throws -> String
    }

    /// What's actually happening, for the status line (no silent fallbacks).
    struct Diagnostics: Sendable, Equatable {
        var language: String?
        var recognizer: String?
        var lines = 0
        var natural = 0
        var problem: String?
        /// What the engine is doing right now, in plain words.
        var stage: String?
    }

    private let config: Config
    private let recognizers: [any SpeechRecognizer]
    private let detector: (any LanguageDetector)?
    private let refiner: Refiner?
    private var timeline = AudioTimeline()
    private var cues: [Cue] = []
    private var coverage = Coverage()
    private var playhead: Double = 0
    private var lastAudioAt = Date.distantPast
    private var running = false
    private var loopTask: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var language = LanguageTracker()
    private var translators: [String: Translator] = [:]
    private var onCues: (@Sendable ([Cue], _ coveredTo: Double) -> Void)?
    private var refineFailed = false
    private var diagnostics = Diagnostics()
    private var setUpLanguages = Set<String>()

    static func clock(_ t: Double) -> String {
        let s = Int(max(0, t)); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    init(config: Config, recognizers: [any SpeechRecognizer], detector: (any LanguageDetector)? = nil, refiner: Refiner? = nil) {
        self.config = config
        self.recognizers = recognizers
        self.detector = detector
        self.refiner = refiner
        if let l = config.language { language.force(l) }
        else if config.candidates.count == 1 { language.force(config.candidates[0]) }
    }

    func setHandler(_ h: @escaping @Sendable ([Cue], Double) -> Void) { onCues = h }

    /// Models load lazily on first use, so this only starts the work loop.
    func load() async throws {
        running = true
        loopTask = Task { await self.loop() }
    }

    func stop() async {
        running = false
        wake?.resume(); wake = nil
        await loopTask?.value
        loopTask = nil
        for r in recognizers { await r.unload() }
        await detector?.unload()
        timeline.removeAll(); cues.removeAll(); coverage = Coverage()
    }

    func addAudio(start: Double, samples: [Float]) {
        timeline.add(start: start, samples: samples)
        lastAudioAt = Date()
        wake?.resume(); wake = nil
    }

    func setPlayhead(_ t: Double) {
        let jumped = abs(t - playhead) > 3
        playhead = t
        if jumped { wake?.resume(); wake = nil }
    }

    /// Wake the loop (e.g. the refiner became ready again when the app came to the front).
    func poke() { wake?.resume(); wake = nil }

    /// Seconds of subtitles ready from the playhead, audio in hand at the next gap,
    /// seconds of audio waiting, and seconds of the video subtitled so far.
    func status() -> (ahead: Double, buffered: Double, pending: Double, done: Double) {
        let ahead = (coverage.end(at: playhead) ?? playhead) - playhead
        let gap = coverage.gap(from: playhead)
        let buffered = timeline.contiguous(from: gap, until: gap + 3600).map { Double($0.samples.count) / AudioTimeline.rate } ?? 0
        return (max(0, ahead), buffered, timeline.pending(coverage), coverage.total)
    }

    func currentDiagnostics() -> Diagnostics {
        var d = diagnostics
        // Lines the refiner has finished (reworded or confirmed as already right).
        d.natural = cues.filter { $0.polished && !$0.original.isEmpty && $0.untranslated == nil }.count
        d.lines = cues.filter { !$0.original.isEmpty && $0.untranslated == nil }.count
        return d
    }

    /// Covered stretches, for the fullscreen scrub bar.
    func coveredRanges() -> [ClosedRange<Double>] { coverage.ranges.map { $0.start...$0.end } }

    // MARK: Loop

    private func loop() async {
        while running {
            // Natural English for lines coming up in the next minute, then more
            // transcription, then natural English for everything else.
            if let i = nextToRefine(within: 60) { await refineCue(i) }
            else if let window = nextWindow() { await transcribe(window) }
            else if let i = nextToRefine(within: .infinity) { await refineCue(i) }
            // Audio is waiting but not ready to take (e.g. for the stream to go quiet):
            // look again shortly instead of sleeping until something else wakes us.
            else if timeline.pending(coverage) > 0.5 { try? await Task.sleep(for: .milliseconds(500)) }
            else { await withCheckedContinuation { wake = $0 } }
        }
    }

    private func nextToRefine(within seconds: Double) -> Int? {
        guard config.natural, let refiner, refiner.isReady(), !refineFailed else { return nil }
        let from = playhead - 1
        let waiting: (Cue) -> Bool = { !$0.polished && $0.untranslated == nil && !$0.original.isEmpty }
        return cues.indices.first { waiting(cues[$0]) && cues[$0].start >= from && cues[$0].start < from + seconds }
            ?? (seconds == .infinity ? cues.indices.first { waiting(cues[$0]) } : nil)
    }

    private func refineCue(_ i: Int) async {
        guard let refiner else { return }
        let cue = cues[i]
        guard let lang = language.locked ?? language.best else { return }
        var natural = cue.english
        do { natural = try await refiner.translate(cue.original, lang) }
        catch {
            refineFailed = true    // e.g. not enough memory: keep Apple's lines, say why
            diagnostics.problem = "\(refiner.name) couldn't run (\(error.localizedDescription)); showing Apple's translation."
        }
        guard let j = cues.firstIndex(where: { $0.start == cue.start && $0.original == cue.original }) else { return }
        if natural != cues[j].english, !natural.isEmpty { cues[j].literal = cues[j].english; cues[j].english = natural }
        cues[j].polished = true
        onCues?(cues, coverage.end(at: playhead) ?? playhead)
    }

    /// Next stretch to subtitle: the first gap at or after the playhead if its audio is
    /// here, else the next uncovered audio later on, else anything earlier (the start of
    /// the video, after a skip). Up to 24 s, cut at the quietest moment so no word is split.
    private func nextWindow() -> (start: Double, samples: [Float])? {
        let here = coverage.gap(from: max(0, playhead - 0.5))
        guard let from = (timeline.contiguous(from: here, until: here + 1) != nil ? here : nil)
                ?? timeline.firstUncovered(from: here, coverage: coverage)
                ?? timeline.firstUncovered(from: 0, coverage: coverage) else { return nil }
        let stop = min(from + 24, coverage.nextStart(after: from) ?? .infinity)
        guard let audio = timeline.contiguous(from: from, until: stop) else { return nil }
        let seconds = Double(audio.samples.count) / AudioTimeline.rate
        let audioEnd = audio.start + seconds
        // Audio that stops at a silent gap (sound resumes later) is complete as it is.
        let endsAtGap = timeline.nextAudio(after: audioEnd - 0.25).map { $0 > audioEnd + 0.25 } ?? false
        let hitsCovered = coverage.nextStart(after: from).map { audioEnd >= $0 - 0.3 } ?? false
        let hitsCap = audioEnd >= from + 24 - 0.3
        let streamIdle = Date().timeIntervalSince(lastAudioAt) > 2
        // A real end: silence follows, the next stretch is already done, or this is all the
        // audio there is (not just the 24 s cap).
        let reachesStop = endsAtGap || hitsCovered || (streamIdle && !hitsCap)
        // The first lines at a new spot only need 4 s; elsewhere, longer windows read better.
        let needed: Double = coverage.covers(playhead) ? 8 : 4
        guard seconds >= needed || reachesStop || (streamIdle && seconds >= 1) else { return nil }
        // Ends exactly where the audio ends (a silent gap, the next covered stretch, or the
        // stream has stopped): take it whole.
        let trace = ProcessInfo.processInfo.environment["LIVESUBS_DEBUG"] != nil
        if trace { print(String(format: "window from %.2f audioEnd %.2f gap=%d covered=%d cap=%d idle=%d", from, audioEnd,
                                endsAtGap ? 1 : 0, hitsCovered ? 1 : 0, hitsCap ? 1 : 0, streamIdle ? 1 : 0)) }
        if reachesStop { return audio }
        // Otherwise never cut mid-word: end at the last real pause; with no pause in sight
        // yet, wait for more audio (or, at 24 s, cut at the quietest moment after 12 s).
        if let cut = Self.lastPause(in: audio.samples, after: needed) {
            if trace { print(String(format: "  → pause cut at %.2f", audio.start + Double(cut) / AudioTimeline.rate)) }
            return (audio.start, Array(audio.samples.prefix(cut)))
        }
        guard seconds >= 23.5 else { return nil }
        return (audio.start, Array(audio.samples.prefix(Self.quietest(in: audio.samples, from: 12))))
    }

    /// Sample index in the middle of the last ≥ 300 ms pause that starts after `after` seconds.
    static func lastPause(in s: [Float], after: Double) -> Int? {
        let r = Int(AudioTimeline.rate), hop = r / 50          // 20 ms frames
        guard s.count > hop * 20 else { return nil }
        var energies: [Float] = []
        var i = 0
        while i + hop <= s.count {
            var e: Float = 0
            for k in stride(from: i, to: i + hop, by: 2) { e += s[k] * s[k] }
            energies.append(sqrt(e / Float(hop / 2))); i += hop
        }
        let sorted = energies.sorted()
        let floor = sorted[sorted.count / 10], loud = sorted[sorted.count * 9 / 10]
        let threshold = max(0.004, floor + (loud - floor) * 0.12)
        var best: Int?, run = 0
        let minFrame = Int(after * 50)
        for (f, e) in energies.enumerated() {
            if e <= threshold { run += 1 } else {
                if run >= 15, f - run / 2 >= minFrame { best = (f - run / 2) * hop }
                run = 0
            }
        }
        return best
    }

    static func quietest(in s: [Float], from seconds: Int) -> Int {
        let r = Int(AudioTimeline.rate), hop = r / 20, win = r * 3 / 10
        var best = s.count, bestEnergy = Float.greatestFiniteMagnitude
        var i = seconds * r
        while i + win <= s.count {
            var e: Float = 0
            for k in stride(from: i, to: i + win, by: 4) { e += s[k] * s[k] }
            if e < bestEnergy { bestEnergy = e; best = i + win / 2 }
            i += hop
        }
        return best
    }

    private func spokenLanguage(for samples: [Float], duration: Double) async -> String {
        if let locked = language.locked { return locked }
        diagnostics.stage = "Working out which language is spoken…"
        guard let detector else { return config.candidates.first ?? language.best ?? "en" }
        guard let detected = try? await detector.detect(samples) else { return language.best ?? config.candidates.first ?? "en" }
        let pick = Self.choose(detected, among: config.candidates, previous: language.best)
        if duration >= 6 { language.vote(pick) }
        // Once settled, the detector's memory is better spent elsewhere.
        if language.locked != nil { await detector.unload() }
        return pick
    }

    private func transcribe(_ window: (start: Double, samples: [Float])) async {
        let duration = Double(window.samples.count) / AudioTimeline.rate
        let lang = await spokenLanguage(for: window.samples, duration: duration)
        diagnostics.language = lang
        var candidates: [any SpeechRecognizer] = []
        for r in recognizers where await r.supports(lang) { candidates.append(r) }
        guard var recognizer = candidates.first else {
            diagnostics.problem = "No speech engine for \(lang) is ready yet."
            coverage.insert(window.start, window.start + duration); timeline.dropCovered(coverage)
            return
        }
        diagnostics.recognizer = recognizer.name
        let span = "\(Self.clock(window.start))–\(Self.clock(window.start + duration))"
        diagnostics.stage = cues.isEmpty && !setUpLanguages.contains(lang)
            ? "Setting up \(recognizer.name) for \(Locale(identifier: "en").localizedString(forLanguageCode: lang) ?? lang) (first time can take a minute)…"
            : "Writing down \(span)…"
        setUpLanguages.insert(lang)
        let apple: Translator? = await {
            guard lang != "en", config.preferAppleTranslation else { return nil }
            let t = translator(for: lang)
            return await t.isAvailable ? t : nil
        }()
        let refinerReady = config.natural && (refiner?.isReady() ?? false)
        do {
            let began = Date()
            var lines: [TimedLine] = []
            var lastError: Error?
            for (k, r) in candidates.enumerated() {
                do {
                    lines = try await r.transcribe(window.samples, language: lang)
                    recognizer = r; lastError = nil
                    diagnostics.recognizer = r.name
                    if k > 0 { diagnostics.problem = "\(candidates[0].name) failed (\(diagnostics.problem ?? "")); using \(r.name)." }
                    break
                } catch {
                    lastError = error
                    diagnostics.problem = "\(r.name) failed: \(error.localizedDescription)"
                }
            }
            if let lastError { throw lastError }
            #if DEBUG
            print(String(format: "LiveSubs ahead: %@ %@ window %.1f–%.1fs took %.1fs (%.1f× real time)", recognizer.name, lang,
                         window.start, window.start + duration, Date().timeIntervalSince(began),
                         duration / max(0.01, Date().timeIntervalSince(began))))
            #endif
            var new: [Cue] = []
            for line in lines {
                var english = line.text, original = "", waiting: String?
                if lang != "en" {
                    original = line.text
                    if let apple { english = await apple.translate(line.text) }
                    else if !refinerReady { waiting = lang }      // shows the "get the pack" bar
                }
                new.append(Cue(start: window.start + line.start, end: window.start + line.end,
                               english: english, original: original, untranslated: waiting,
                               polished: !refinerReady || lang == "en"))
            }
            diagnostics.stage = nil
            cues.removeAll { $0.start >= window.start - 0.05 && $0.start < window.start + duration }
            cues.append(contentsOf: new)
            cues.sort { $0.start < $1.start }
            coverage.insert(window.start, window.start + duration)
            coverGap(after: window.start + duration)
            timeline.dropCovered(coverage)
            onCues?(cues, coverage.end(at: playhead) ?? playhead)
        } catch {
            diagnostics.problem = "\(recognizer.name) failed on a stretch: \(error.localizedDescription)"
            // Skip this window rather than stall the whole video.
            coverage.insert(window.start, window.start + duration)
            timeline.dropCovered(coverage)
        }
    }

    /// Language whose translation pack is missing, if lines are waiting for it.
    func missingPack() -> String? { cues.first { $0.untranslated != nil }?.untranslated }

    /// After a pack is installed: translate every line that was waiting for it.
    func retranslate() async {
        for i in cues.indices {
            guard let lang = cues[i].untranslated else { continue }
            let t = translator(for: lang)
            guard await t.isAvailable else { return }
            cues[i].english = await t.translate(cues[i].original)
            cues[i].untranslated = nil
            cues[i].polished = !(config.natural && (refiner?.isReady() ?? false))
        }
        onCues?(cues, coverage.end(at: playhead) ?? playhead)
    }

    /// A stretch with no sound (sound resumes within 15 s) needs no subtitles: count it as done.
    private func coverGap(after end: Double) {
        if let next = timeline.nextAudio(after: end - 0.25), next > end + 0.25, next - end < 15 {
            coverage.insert(end, next)
        }
    }

    /// WhisperKit reports a score only for the language it picked, so the viewer's list is
    /// applied as a rule: their language if Whisper picked one; otherwise the usual mix-up
    /// partner (short Japanese often reads as Chinese); otherwise the language already heard.
    static func choose(_ detected: String, among candidates: [String], previous: String?) -> String {
        guard !candidates.isEmpty, !candidates.contains(detected) else { return detected }
        let confusable: [String: [String]] = ["zh": ["ja", "yue"], "yue": ["zh", "ja"], "ja": ["zh"], "ko": ["ja"],
                                               "nn": ["no"], "no": ["nn", "da", "sv"], "pt": ["es", "gl"], "gl": ["pt", "es"],
                                               "ms": ["id"], "id": ["ms"], "hi": ["ur"], "ur": ["hi"], "sr": ["hr", "bs"], "hr": ["sr", "bs"]]
        if let match = confusable[detected]?.first(where: candidates.contains) { return match }
        if let previous, candidates.contains(previous) { return previous }
        return detected   // genuinely another language: trust Whisper rather than force a wrong one
    }

    private func translator(for code: String) -> Translator {
        if let t = translators[code] { return t }
        let t = Translator(source: Locale.Language(identifier: code))
        translators[code] = t
        return t
    }
}
