import Accelerate
import AVFoundation
import Foundation
import ReplayKit
import SwiftUI

/// Orchestrates one translation session: audio source → pipeline → subtitles (PiP + in-app).
@MainActor
final class LiveSession: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing(String)
        /// Classic ReplayKit path: waiting for the user to confirm "Start Broadcast".
        case waitingForBroadcast
        case running
        case paused
        case failed(String)

        var isActive: Bool {
            switch self {
            case .idle, .failed: false
            default: true
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var subtitle = SubtitleUpdate()
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var hint: String?
    /// Everything said this session, oldest first (kept after Stop until the next Start).
    @Published private(set) var history: [SessionLine] = []
    /// Set while the built-in practice clip is playing.
    @Published private(set) var practiceLanguage: String?
    /// Measured on the last practice clip: average seconds from end of speech to yellow line.
    @Published private(set) var practiceDelay: Double?
    private var practiceSource: SampleAudioSource?
    /// What the last practice clip showed: how it was prepared and by which engines.
    @Published private(set) var practiceReport: String?
    private var practiceEngine: AheadTranscriber?
    private var practicePlayer: AVAudioPlayer?
    private var practiceTimer: Timer?
    private var practiceCues: [Cue] = []
    private var practiceLags: [Double] = []
    private var clipStartedAt: Date?

    /// iPhone is hot: transcription may fall behind.
    @Published private(set) var isHot = false

    struct SessionLine: Identifiable, Equatable {
        let id = UUID()
        /// Seconds since the session started.
        let start: TimeInterval
        var end: TimeInterval
        let english: String
        let original: String
    }

    let pip = SubtitlePiPController()
    let island = IslandSubtitles()
    private let settings: AppSettings
    private var source: AudioSource?
    private var pipeline: TranslationPipeline?
    private var usingBroadcast = false
    private var silentSeconds: Double = 0
    private var levelThrottle = Date.distantPast
    private var startTask: Task<Void, Never>?
    private var sessionStart = Date()
    private var lastSpeechAt = Date()
    private var autoStopTimer: Timer?
    private var lineStartedAt: TimeInterval?
    private var thermalObserver: NSObjectProtocol?

    /// Set by the UI: the hidden RPSystemBroadcastPickerView we "tap" programmatically.
    weak var broadcastPicker: RPSystemBroadcastPickerView?

    init(settings: AppSettings) {
        self.settings = settings
        pip.onPlayPauseToggled = { [weak self] playing in
            guard let self else { return }
            if playing, self.state == .paused { self.state = .running }
            else if !playing, self.state == .running { self.state = .paused }
            self.refreshPiP()
        }
        pip.onClosedByUser = { [weak self] in self?.stop() }

        let notifier = DarwinNotifier.shared
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateThermal() }
        }
        updateThermal()

        notifier.observe(Shared.Note.broadcastStarted) { [weak self] in self?.broadcastDidStart() }
        notifier.observe(Shared.Note.broadcastStopped) { [weak self] in
            guard let self, self.usingBroadcast, self.state.isActive else { return }
            self.stop(endBroadcast: false)
        }
    }

    // MARK: Public controls

    func toggle() { state.isActive ? stop() : start() }

    func start() {
        guard !state.isActive else { return }
        practiceLanguage = nil
        begin()
    }

    /// Plays a built-in clip through the real engine, no other app needed.
    func startPractice(language: String) {
        guard !state.isActive else { return }
        practiceLanguage = language
        begin()
    }

    private func begin() {
        hint = nil
        subtitle = SubtitleUpdate()
        history = []
        lineStartedAt = nil
        sessionStart = Date()
        lastSpeechAt = Date()
        startTask = Task { await self.startSession() }
    }

    func stop(endBroadcast: Bool = true) {
        startTask?.cancel()
        startTask = nil
        source?.stop()
        source = nil
        if usingBroadcast, endBroadcast { DarwinNotifier.shared.post(Shared.Note.requestStop) }
        usingBroadcast = false
        let p = pipeline
        pipeline = nil
        Task { await p?.stop() }
        pip.stop()
        pip.setPaused(false)
        island.end()
        autoStopTimer?.invalidate(); autoStopTimer = nil
        practiceLanguage = nil
        practiceSource = nil
        clipStartedAt = nil
        practiceTimer?.invalidate(); practiceTimer = nil
        practicePlayer?.stop(); practicePlayer = nil
        let pe = practiceEngine; practiceEngine = nil
        Task { await pe?.stop() }
        state = .idle
        refreshPiP()
        audioLevel = 0
        UIApplication.shared.isIdleTimerDisabled = false
    }

    #if DEBUG
    /// Design-review only: renders a representative subtitle frame (synthetic text).
    func showDemoSubtitles() {
        state = .running
        settings.showOriginal = true
        history = [
            SessionLine(start: 0.4, end: 3.9, english: "Today I'll introduce an old shopping street in Tokyo.", original: "今日は東京の古い商店街を紹介します。"),
            SessionLine(start: 4.6, end: 8.8, english: "This ramen shop has been open for fifty years.", original: "このラーメン屋は五十年前から営業しています。"),
            SessionLine(start: 9.5, end: 13.6, english: "It rained yesterday, so nobody came.", original: "昨日は雨が降ったので、誰も来ませんでした。"),
        ]
        subtitle = SubtitleUpdate(committed: history.map(\.english), tentative: "",
                                  sourceLanguage: "ja", original: "昨日は雨が降ったので、誰も来ませんでした。")
        audioLevel = 0.4
        if ProcessInfo.processInfo.arguments.contains("-reviewIsland") { island.start(label: "Japanese → English") }
        refreshPiP()
    }
    #endif

    // MARK: Start sequence

    private func startSession() async {
        if let lang = practiceLanguage { await startPreparedPractice(lang); return }
        // 1. Engine. Apple's recogniser when the language is known (most accurate on long
        // Japanese/Korean audio in our tests); Whisper when it must detect the language, or
        // when "Use Whisper instead" is on.
        let pipeline: TranslationPipeline
        let known = settings.singleKnownLanguage
        let useApple = !settings.browserUseWhisper && known.flatMap(AppSettings.appleLocale(for:)) != nil
        switch useApple ? EngineKind.apple : settings.engine {
        case .whisper:
            // Whisper here only detects the language: Small does that well. The large models
            // load only when "Use Whisper instead" is on.
            let small = WhisperModel.recommended
            let model = !settings.browserUseWhisper && settings.model.approxMB >= 600 && ModelStore.localFolder(for: small) != nil
                ? small : settings.model
            guard ModelStore.localFolder(for: model) != nil else {
                state = .failed("Download a speech model first — open Settings ▸ Speech models.")
                return
            }
            state = .preparing("Loading \(model.displayName) model…")
            // The first load after installing optimizes the model for this iPhone's Neural
            // Engine, which can take minutes for the large models. Say so instead of looking stuck.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, case .preparing = self.state else { return }
                self.state = .preparing("First start after an update: optimizing \(model.displayName) for this iPhone. This happens once and can take a few minutes; keep LiveSubs open.")
            }
            let forced = practiceLanguage ?? (settings.spokenLanguage.isEmpty ? nil : settings.spokenLanguage)
            pipeline = WhisperPipeline(options: .init(
                model: model,
                forcedLanguage: forced,
                preferAppleTranslation: settings.preferAppleTranslation,
                partials: !settings.steady(for: forced)))
        case .apple:
            state = .preparing("Preparing Apple speech recognition…")
            let id = known.flatMap(AppSettings.appleLocale(for:)) ?? settings.appleLanguage
            let code = Locale(identifier: id).language.languageCode?.identifier
            pipeline = ApplePipeline(sourceLocale: Locale(identifier: id), partials: !settings.steady(for: code))
        }
        pipeline.onUpdate = { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
        do {
            try await pipeline.start()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { await pipeline.stop(); return }
        self.pipeline = pipeline

        // 2. Audio source
        if let lang = practiceLanguage {
            let sample = SampleAudioSource(language: lang)
            practiceSource = sample
            practiceLags = []
            sample.onFinished = { [weak self] in
                // Hold the last line on screen for a moment, as a subtitle would.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2.5))
                    guard let self, self.practiceLanguage == lang, self.state.isActive else { return }
                    if !self.practiceLags.isEmpty {
                        self.practiceDelay = self.practiceLags.reduce(0, +) / Double(self.practiceLags.count)
                    }
                    self.stop()
                }
            }
            await attach(sample)
            return
        }
        switch settings.source {
        case .microphone:
            await attach(MicrophoneAudioSource())
        case .otherApps:
            if settings.useScreenCaptureKit, #available(iOS 27.0, *), let sck = makeScreenCaptureSource() {
                state = .preparing("Choose “Entire Screen” to share audio…")
                sck.onEnded = { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.state.isActive else { return }
                        self.stop()
                        if let error, (error as NSError).code != -3817 { // -3817 = user stopped
                            self.state = .failed("Screen audio capture ended: \(error.localizedDescription)")
                        }
                    }
                }
                await attach(sck)
            } else {
                usingBroadcast = true
                // If a broadcast is already live (started from Control Center), just attach.
                if let url = Shared.ringBufferURL, let ring = AudioRingBuffer(url: url),
                   CFAbsoluteTimeGetCurrent() - ring.lastWriteTime < 2 {
                    broadcastDidStart()
                } else {
                    state = .waitingForBroadcast
                    triggerBroadcastPicker()
                }
            }
        }
    }

    // MARK: Practice clip, prepared ahead

    /// Runs the whole clip through the private browser's engine first (Apple's recogniser →
    /// Apple Translation → TranslateGemma), then plays it with every line on time.
    private func startPreparedPractice(_ lang: String) async {
        guard let url = SampleAudioSource.url(for: lang), let samples = try? SampleAudioSource.decode(url) else {
            state = .failed("The practice clip is missing from this build."); return
        }
        practiceReport = nil
        state = .preparing("Preparing subtitles for the whole clip…")
        var recognizers: [any SpeechRecognizer] = settings.browserUseWhisper ? [WhisperRecognizer(model: settings.model)] : [AppleRecognizer()]
        if let fallback = ([WhisperModel.recommended] + WhisperModel.catalog.reversed()).first(where: { ModelStore.localFolder(for: $0) != nil && $0.approxMB < 600 }) {
            recognizers.append(WhisperRecognizer(model: fallback))
        }
        let natural = settings.naturalEnglish && !settings.browserUseWhisper && GemmaTranslator.isDownloaded
        let refiner: AheadTranscriber.Refiner? = natural ? .init(
            name: "TranslateGemma", isReady: { GemmaTranslator.isDownloaded && GemmaTranslator.allowed },
            translate: { text, l in try await GemmaTranslator.shared.translate(text, from: l) }) : nil
        // Start loading TranslateGemma now, alongside speech recognition (its first load is the slow part).
        if natural { Task.detached { _ = try? await GemmaTranslator.shared.load() } }
        let engine = AheadTranscriber(config: .init(language: lang, candidates: [lang], natural: natural),
                                      recognizers: recognizers, refiner: refiner)
        practiceEngine = engine
        await engine.setHandler { [weak self] cues, _ in Task { @MainActor in self?.practiceCues = cues } }
        try? await engine.load()
        await engine.setPlayhead(0)
        await engine.addAudio(start: 0, samples: samples)
        let total = Double(samples.count) / Shared.sampleRate
        let began = Date()
        // Wait until the whole clip is subtitled (and made natural, if that's on), at most a minute.
        while Date().timeIntervalSince(began) < 60, practiceEngine === engine {
            let s = await engine.status(), d = await engine.currentDiagnostics()
            if s.done >= total - 1.5, !natural || d.natural >= d.lines || d.problem != nil || d.lines == 0 { break }
            if s.done >= total - 1.5, natural { state = .preparing("Making the English natural with TranslateGemma… \(d.natural) of \(d.lines) lines") }
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard practiceEngine === engine else { return }
        let d = await engine.currentDiagnostics()
        let seconds = Date().timeIntervalSince(began)
        var report = String(format: "Prepared the whole %.0f s clip in %.1f s with %@", total, seconds, d.recognizer ?? "the speech engine")
        if natural {
            let speed = await GemmaTranslator.shared.speedSummary()
            report += " + TranslateGemma (\(d.natural) of \(d.lines) lines\(speed.map { "; " + $0 } ?? ""))."
        } else { report += " + Apple Translation." }
        if let p = d.problem { report += " " + p }
        report += " Lines then appear exactly as they're spoken."
        practiceReport = report

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let player = try? AVAudioPlayer(contentsOf: url) else { stop(); return }
        practicePlayer = player
        player.play()
        state = .running
        practiceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.practicePlayer else { return }
                // Finished: the player rewinds to 0, so don't look up a line any more.
                if !player.isPlaying {
                    self.practiceTimer?.invalidate(); self.practiceTimer = nil
                    try? await Task.sleep(for: .seconds(2))
                    if self.practicePlayer === player { self.stop() }
                    return
                }
                let t = player.currentTime
                let cue = self.practiceCues.last { $0.start <= t + 0.05 && t < max($0.end, $0.start + 1.2) + 0.4 }
                let next = SubtitleUpdate(committed: cue.map { [$0.english] } ?? [], tentative: "",
                                          sourceLanguage: lang, status: nil, original: cue?.original ?? "")
                if next != self.subtitle { self.apply(next) }
            }
        }
    }

    @available(iOS 27.0, *)
    private func makeScreenCaptureSource() -> ScreenCaptureSourceType? {
        #if canImport(ScreenCaptureKit)
        return ScreenCaptureAudioSource.isAvailable ? ScreenCaptureAudioSource() : nil
        #else
        return nil
        #endif
    }

    private func attach(_ src: AudioSource) async {
        src.onSamples = { [weak self] samples in
            guard let self else { return }
            self.feed(samples)
        }
        do {
            try await src.start()
        } catch is CancellationError {
            stop(); return
        } catch {
            await pipeline?.stop(); pipeline = nil
            state = .failed(error.localizedDescription)
            return
        }
        source = src
        if src is SampleAudioSource { clipStartedAt = Date() }
        state = .running
        UIApplication.shared.isIdleTimerDisabled = true
        refreshPiP()
        if practiceLanguage == nil { pip.start() }
        if settings.islandSubtitles {
            island.expandOnNewLine = settings.islandPopOpen
            island.start(label: "Listening")
        }
        startAutoStop()
    }

    private func broadcastDidStart() {
        guard usingBroadcast, state == .waitingForBroadcast || state.isActive, source == nil, pipeline != nil else { return }
        Task { await attach(BroadcastAudioSource()) }
    }

    func triggerBroadcastPicker() {
        // RPSystemBroadcastPickerView has no public "present" API; tapping its
        // internal button is the standard way to open the system sheet from our own UI.
        guard let picker = broadcastPicker else { return }
        for case let button as UIButton in picker.subviews {
            button.sendActions(for: .allTouchEvents)
        }
    }

    // MARK: Audio + subtitles

    /// Background queue.
    nonisolated private func feed(_ samples: [Float]) {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        let duration = Double(samples.count) / Shared.sampleRate
        Task { @MainActor in
            guard self.state == .running else { return }
            self.pipeline?.append(samples)
            self.trackLevel(rms, duration: duration)
        }
    }

    private func trackLevel(_ rms: Float, duration: Double) {
        if rms < 1e-6 { silentSeconds += duration } else { silentSeconds = 0; if hint != nil { hint = nil; refreshPiP() } }
        if silentSeconds > 20, hint == nil {
            hint = usingBroadcast || settings.source == .otherApps
                ? "No audio is coming through. Make sure a video is playing with sound. Some apps block audio capture — try Microphone mode for those."
                : "No sound detected from the microphone."
            refreshPiP()
        }
        if Date().timeIntervalSince(levelThrottle) > 0.1 {
            levelThrottle = Date()
            audioLevel = min(1, sqrt(rms) * 2.5)
        }
    }

    private func apply(_ update: SubtitleUpdate) {
        let t = Date().timeIntervalSince(sessionStart)
        if lineStartedAt == nil, !update.tentative.isEmpty { lineStartedAt = t }
        if let line = update.committed.last, line != subtitle.committed.last {
            // Subtitle timing: from the first guess (or ~3 s back in Steady mode) to now.
            let previousEnd = history.last?.end ?? 0
            let start = max(previousEnd, lineStartedAt ?? t - 3)
            history.append(SessionLine(start: start, end: max(t, start + 1), english: line, original: update.original))
            lineStartedAt = nil
            if let clip = practiceSource, let began = clipStartedAt {
                let now = Date().timeIntervalSince(began)
                if let end = clip.speechEnds.last(where: { $0 <= now }) { practiceLags.append(now - end) }
            }
        }
        if !update.tentative.isEmpty || update.committed.last != subtitle.committed.last {
            lastSpeechAt = Date()
        }
        if let lang = update.sourceLanguage, practiceLanguage == nil, lang != settings.lastLanguage {
            settings.lastLanguage = lang
        }
        subtitle = update
        refreshPiP()
    }

    // MARK: Battery and heat

    private func startAutoStop() {
        autoStopTimer?.invalidate()
        guard settings.autoStopMinutes > 0, practiceLanguage == nil else { return }
        autoStopTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .running else { return }
                let limit = Double(self.settings.autoStopMinutes) * 60
                if Date().timeIntervalSince(self.lastSpeechAt) > limit {
                    self.stop()
                    self.hint = "Stopped after \(self.settings.autoStopMinutes) minutes without speech, to save battery."
                }
            }
        }
    }

    private func updateThermal() {
        let s = ProcessInfo.processInfo.thermalState
        isHot = s == .serious || s == .critical
        if state.isActive { refreshPiP() }
    }

    private func refreshPiP() {
        guard state.isActive else {
            // After a session, the last line stays up until the next Start.
            let last = history.last
            pip.update(.init(committed: last?.english ?? "Subtitles appear here in English, as people speak.",
                             tentative: "", badge: "",
                             original: settings.showOriginal ? (last?.original ?? "") : "",
                             fontScale: settings.fontScale))
            return
        }
        let committed = subtitle.committed
        // The frame shows the sentence being spoken; when there is none, the last
        // finished line stays up the way a subtitle holds until the next one.
        // Lines that finished together (Apple's engine sends a few at once) show together.
        var text = committed.last ?? ""
        if let newest = history.last {
            let together = history.suffix(3).filter { newest.end - $0.end < 0.8 }
            if together.count > 1 { text = together.map(\.english).joined(separator: " ") }
        }
        // Status reads like an SDH sound caption: [ listening ].
        var badge: String
        if state == .paused {
            badge = "[ paused · tap play to resume ]"
        } else if hint != nil, practiceLanguage == nil {
            badge = "[ no sound · is the video muted? ]"
        } else if isHot {
            badge = "[ iPhone is warm · subtitles may lag ]"
        } else if let status = subtitle.status {
            badge = "[ \(status.lowercased()) ]"
        } else if settings.showBadge, let lang = subtitle.sourceLanguage {
            badge = lang == "en" ? "English" : "\(WhisperLanguages.name(lang)) → English"
        } else {
            badge = "[ listening ]"
        }
        // Steady: only finished lines. Automatic decides by the language being heard.
        let steady = settings.steady(for: subtitle.sourceLanguage)
        let tentative = steady ? "" : subtitle.tentative
        let original = settings.showOriginal ? subtitle.original : ""
        pip.update(.init(committed: text, tentative: tentative, badge: badge, original: original,
                         fontScale: settings.fontScale))
        let label = badge.hasPrefix("[") ? String(badge.dropFirst(2).dropLast(2)) : badge
        island.update(line: tentative.isEmpty ? (committed.last ?? "") : tentative,
                      original: settings.showOriginal ? subtitle.original : "",
                      label: label, isGuess: !tentative.isEmpty)
    }
}
