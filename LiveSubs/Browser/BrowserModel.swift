import Foundation
import WebKit

/// The private browser: a WKWebView with no persistent storage, the audio-copying
/// hook, and the ahead-of-time subtitle engine. Nothing about what is watched is
/// written to disk, logged, or sent anywhere; closing the browser discards it all.
@MainActor
final class BrowserModel: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle                 // no video yet
        case preparing(Double)    // seconds of audio in hand, waiting for the first window
        case holding              // video paused for a moment until the first lines are ready
        case ready(ahead: Double) // subtitles exist this far ahead of the playhead
        case catchingUp           // playing past the subtitles (just seeked, or slow phone)
        case cannotRead(String)   // protected, or a player LiveSubs can't read ahead
        case loadingModel
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var cue: Cue?
    @Published private(set) var videoRect: CGRect?
    @Published private(set) var isFullscreen = false
    /// Which engines are working and how far along, for the status line.
    @Published private(set) var diagnostics = AheadTranscriber.Diagnostics()
    /// Covered stretches, for the fullscreen scrub bar.
    @Published private(set) var covered: [ClosedRange<Double>] = []
    /// Lines are waiting for this language's Apple translation pack (e.g. "ja").
    @Published private(set) var missingPack: String?
    /// Seconds of the video subtitled so far, and its length (from the page).
    @Published private(set) var doneSeconds: Double = 0
    @Published private(set) var duration: Double = 0
    /// LiveSubs' own fullscreen (video enlarged in the page, bars hidden, landscape allowed).
    @Published private(set) var inAppFullscreen = false
    @Published var address = ""
    @Published private(set) var pageTitle = ""
    @Published private(set) var canGoBack = false

    let webView: WKWebView
    private let settings: AppSettings
    private var engine: AheadTranscriber?
    private var decoders: [String: FMP4AudioDecoder] = [:]
    private var unsupported: String?
    private var cues: [Cue] = []
    private var playhead: Double = 0
    private var playheadAt = Date()
    private var rate: Double = 1
    private var paused = true
    private var sawChunks = false
    private var sawVideo: (kind: String, protected: Bool)?
    private var ticker: Timer?
    private var pushedToTrack = Set<Double>()
    private var engineLoaded = false
    private var videoInMainFrame = false
    private var playlistDelivering = false
    /// Playlist path: for players that hand iOS an .m3u8 instead of streaming through the page.
    private var hls: HLSAudioReader?
    private var hlsSource: String?
    private var holding = false
    private var holdStartedAt: Date?
    /// The viewer pressed play during a hold, or a hold timed out: don't hold again for this video.
    private var holdDisabledForVideo = false
    private var mainFrame: WKFrameInfo?
    private var titleObservation: NSKeyValueObservation?
    /// Ready once the ad-blocking rules are attached (pages wait for it, so the first
    /// page is already protected).
    private var blockerReady: Task<Void, Never>?
    @Published private(set) var blockingAds = false
    private var backObservation: NSKeyValueObservation?

    init(settings: AppSettings) {
        self.settings = settings
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()          // nothing reaches disk
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-browserAutoplay") { config.mediaTypesRequiringUserActionForPlayback = [] }
        #endif
        let weakHandler = WeakHandler()
        config.userContentController.add(weakHandler, name: BrowserScripts.handlerName)
        config.userContentController.addUserScript(WKUserScript(source: BrowserScripts.hook,
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        weakHandler.target = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if settings.blockAds {
            let controller = config.userContentController
            blockerReady = Task { [weak self] in
                let lists = await Self.adBlockers()
                lists.forEach(controller.add)
                self?.blockingAds = !lists.isEmpty
            }
        }
        titleObservation = webView.observe(\.title) { [weak self] w, _ in Task { @MainActor in self?.pageTitle = w.title ?? "" } }
        backObservation = webView.observe(\.canGoBack) { [weak self] w, _ in Task { @MainActor in self?.canGoBack = w.canGoBack } }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Navigation

    func open(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var url = URL(string: trimmed)
        if url?.scheme == nil { url = URL(string: "https://" + trimmed) }
        // Text that isn't an address: search for it (DuckDuckGo, no tracking cookies stored here anyway).
        if url?.host == nil || !trimmed.contains(".") {
            var c = URLComponents(string: "https://duckduckgo.com/")!
            c.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            url = c.url
        }
        guard let url else { return }
        resetVideo()
        Task {
            // Wait for blocking (normally ready instantly; compiled at launch), at most 8 s.
            if let ready = blockerReady {
                await withTaskGroup(of: Void.self) { g in
                    g.addTask { await ready.value }
                    g.addTask { try? await Task.sleep(for: .seconds(8)) }
                    await g.next(); g.cancelAll()
                }
            }
            webView.load(URLRequest(url: url))
        }
    }

    func goBack() { webView.goBack() }

    /// Called once Apple has installed the missing pack.
    func packInstalled() {
        missingPack = nil
        Task { await engine?.retranslate() }
    }

    /// Playback controls for LiveSubs' fullscreen, applied in the frame that plays the video.
    func control(_ action: String, _ value: Double = 0) {
        let js = "window.__liveSubsControl && window.__liveSubsControl('\(action)', \(value))"
        if let f = mainFrame { webView.evaluateJavaScript(js, in: f, in: .page, completionHandler: nil) }
        else { webView.evaluateJavaScript(js, completionHandler: nil) }
        if action == "seek" { playhead = value; playheadAt = Date() }
    }

    var isPaused: Bool { paused }
    var position: Double { paused ? playhead : playhead + Date().timeIntervalSince(playheadAt) * rate }

    func exitFullscreen() {
        webView.evaluateJavaScript("window.__liveSubsExitFS && window.__liveSubsExitFS()", completionHandler: nil)
        inAppFullscreen = false
        OrientationLock.setFullscreen(false)
    }

    /// Discards the page, its audio and subtitles, and all website data.
    func close() async {
        ticker?.invalidate(); ticker = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        await engine?.stop()
        engine = nil
        decoders.removeAll(); cues.removeAll(); cue = nil
        await webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    private func resetVideo() {
        decoders.removeAll(); cues.removeAll(); cue = nil; pushedToTrack.removeAll(); doneSeconds = 0; duration = 0
        sawChunks = false; sawVideo = nil; unsupported = nil
        let h = hls; hls = nil; hlsSource = nil; playlistDelivering = false
        Task { await h?.stop() }
        holding = false; holdStartedAt = nil; holdDisabledForVideo = false
        phase = .idle
        let e = engine; engine = nil
        Task { await e?.stop() }
    }

    // MARK: Messages from the page

    fileprivate func receive(_ body: [String: Any], frame: WKFrameInfo) {
        switch body["k"] as? String {
        case "debug":
            #if DEBUG
            print("LiveSubs browser:", body["msg"] ?? "")
            #endif
        case "playlist":
            // The player fetched a playlist: read the whole video from it (only the first
            // one per video; later ones are usually the variants it picked from it).
            if let url = body["url"] as? String, hlsSource == nil { startPlaylistReader(url, frame: frame) }
        case "fs":
            let on = body["on"] as? Bool ?? false
            if on != inAppFullscreen { inAppFullscreen = on; OrientationLock.setFullscreen(on) }
        case "frameRect":
            // Used when the video plays inside an embedded frame (no main-frame rect).
            if let w = body["w"] as? Double, let h = body["h"] as? Double, !videoInMainFrame {
                videoRect = CGRect(x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0, width: w, height: h)
            }
        case "reset":
            // An in-video ad finished: its audio isn't part of the programme.
            decoders.removeAll(); cues.removeAll(); cue = nil
            let e = engine; engine = nil
            Task { await e?.stop() }
        case "chunk":
            guard let id = body["id"] as? String, let b64 = body["data"] as? String, let data = Data(base64Encoded: b64) else { return }
            handleChunk(id: id, data: data)
        case "time":
            let t = body["t"] as? Double ?? 0
            let isMain = body["main"] as? Bool ?? false
            sawVideo = (body["kind"] as? String ?? "none", body["protected"] as? Bool ?? false)
            playhead = t; playheadAt = Date()
            paused = body["paused"] as? Bool ?? true
            rate = body["rate"] as? Double ?? 1
            if let d = body["d"] as? Double, d.isFinite, d > 0 { duration = d }
            isFullscreen = body["fullscreen"] as? Bool ?? false
            videoInMainFrame = isMain
            if isMain, let w = body["w"] as? Double, w > 40, let h = body["h"] as? Double {
                videoRect = CGRect(x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0, width: w, height: h)
            } else if isMain { videoRect = nil }
            if body["main"] as? Bool == true || mainFrame == nil { mainFrame = frame }
            if let src = body["src"] as? String, !src.isEmpty, !sawChunks, hlsSource != src, !paused {
                startPlaylistReader(src, frame: frame)
            }
            Task { await engine?.setPlayhead(t); await hls?.setPlayhead(t) }
            pushCuesToTrack(frame: frame)
        default:
            break
        }
    }

    private func handleChunk(id: String, data: Data) {
        sawChunks = true
        let decoder = decoders[id] ?? FMP4AudioDecoder()
        decoders[id] = decoder
        do {
            let runs = try decoder.append(data)
            #if DEBUG
            print("LiveSubs browser: chunk \(data.count) bytes → \(runs.count) runs \(runs.first.map { String(format: "@%.1fs", $0.start) } ?? "")")
            #endif
            guard !runs.isEmpty else { return }
            startEngineIfNeeded()
            for r in runs { Task { await engine?.addAudio(start: r.start, samples: r.samples) } }
        } catch FMP4AudioDecoder.DecodeError.unsupportedCodec(let c) {
            unsupported = "This site's audio format (\(c)) can't be read ahead yet."
        } catch {
            // A malformed chunk: skip it; the next fragment starts clean.
        }
    }

    private func startPlaylistReader(_ src: String, frame: WKFrameInfo) {
        guard let url = URL(string: src), ["http", "https"].contains(url.scheme ?? "") else { return }
        let old = hls
        hlsSource = src
        Task { await old?.stop() }
        Task {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let agent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
            let reader = HLSAudioReader(playlistURL: url, referer: frame.request.url, userAgent: agent, cookies: cookies)
            guard self.hlsSource == src else { return }
            self.hls = reader
            await reader.setPlayhead(self.playhead)
            await reader.start(
                onAudio: { [weak self] start, samples in
                    Task { @MainActor in
                        guard let self else { return }
                        #if DEBUG
                        if !self.playlistDelivering { print("LiveSubs browser: playlist reader delivering audio from \(start)s") }
                        #endif
                        self.sawChunks = true
                        self.playlistDelivering = true
                        self.startEngineIfNeeded()
                        await self.engine?.addAudio(start: start, samples: samples)
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        switch error {
                        case .protected: self.unsupported = "This video is protected (DRM), so its sound can't be read."
                        case .unsupported, .network:
                            if !self.sawChunks {
                                self.unsupported = "This site plays video in a way LiveSubs can't read ahead yet. Use Live mode on the main screen for it."
                            }
                        }
                    }
                })
        }
    }

    private func startEngineIfNeeded() {
        guard engine == nil else { return }
        engineLoaded = false
        let fixed = settings.spokenLanguage.isEmpty ? nil : settings.spokenLanguage
        let candidates = settings.usualLanguages
        // Speech engines in order of preference for each language.
        var recognizers: [any SpeechRecognizer] = []
        if settings.browserUseWhisper, ModelStore.localFolder(for: settings.model) != nil {
            recognizers.append(WhisperRecognizer(model: settings.model))
        } else {
            // Apple's recogniser: best on long audio in our Japanese/Korean tests (6% errors vs
            // 12–16% for Parakeet and Whisper Turbo), fast, nothing to download.
            recognizers.append(AppleRecognizer())
        }
        // Catch-all for languages neither supports: the smallest downloaded Whisper.
        if let fallback = ([WhisperModel.recommended] + WhisperModel.catalog.reversed()).first(where: { ModelStore.localFolder(for: $0) != nil && $0.approxMB < 600 }) {
            recognizers.append(WhisperRecognizer(model: fallback))
        }
        // Language detection is only needed when more than one language is possible.
        var detector: (any LanguageDetector)?
        if fixed == nil, candidates.count != 1,
           let small = ([WhisperModel.recommended] + WhisperModel.catalog).first(where: { ModelStore.localFolder(for: $0) != nil }) {
            detector = WhisperRecognizer(model: small)
        }
        // TranslateGemma, unless Whisper Turbo is the recogniser (both together won't fit in memory).
        var refiner: AheadTranscriber.Refiner?
        if settings.naturalEnglish, !settings.browserUseWhisper {
            refiner = .init(name: "TranslateGemma",
                            isReady: { GemmaTranslator.isDownloaded && GemmaTranslator.allowed },
                            translate: { text, lang in try await GemmaTranslator.shared.translate(text, from: lang) })
        }
        let e = AheadTranscriber(config: .init(language: fixed, candidates: candidates,
                                               preferAppleTranslation: settings.preferAppleTranslation,
                                               natural: settings.naturalEnglish),
                                 recognizers: recognizers, detector: detector, refiner: refiner)
        engine = e
        phase = .loadingModel
        Task {
            await e.setHandler { [weak self] cues, _ in Task { @MainActor in self?.cues = cues } }
            do { try await e.load(); self.engineLoaded = true } catch { self.phase = .failed(error.localizedDescription) }
            await e.setPlayhead(self.playhead)
        }
    }

    /// The app left or returned to the screen: TranslateGemma (GPU) must pause in the background.
    func setActive(_ active: Bool) {
        GemmaTranslator.allowed = active
        if active { Task { await engine?.poke() } }
    }

    // MARK: Display

    private func tick() {
        // Interpolate between the page's 4×/s reports so lines change on time.
        let now = paused ? playhead : playhead + Date().timeIntervalSince(playheadAt) * rate
        cue = cues.last { $0.start <= now + 0.05 && now < max($0.end, $0.start + 1.2) + 0.4 }
        Task { [weak self] in
            guard let self, let engine = self.engine else { self?.updatePhaseWithoutEngine(); return }
            let s = await engine.status()
            let missing = await engine.missingPack()
            let diag = await engine.currentDiagnostics()
            let ranges = await engine.coveredRanges()
            await MainActor.run {
                if self.diagnostics != diag { self.diagnostics = diag }
                if self.covered != ranges { self.covered = ranges }
            }
            await self.hls?.setPaused(s.pending > 120)
            await MainActor.run { if self.missingPack != missing { self.missingPack = missing } }
            await MainActor.run {
                self.doneSeconds = s.done
                self.updatePhase(ahead: s.ahead, buffered: s.buffered)
            }
        }
    }

    private func updatePhaseWithoutEngine() {
        if case .failed = phase { return }
        if let unsupported { phase = .cannotRead(unsupported); return }
        guard let v = sawVideo else { phase = .idle; return }
        if v.protected { phase = .cannotRead("This video is protected (DRM), so its sound can't be read."); return }
        if !sawChunks, v.kind == "stream", !paused, playhead > 3 {
            phase = .cannotRead("This site plays video in a way LiveSubs can't read ahead yet. Use Live mode on the main screen for it.")
            return
        }
        phase = .idle
    }

    private func updatePhase(ahead: Double, buffered: Double) {
        if case .failed = phase { return }
        if let unsupported { phase = .cannotRead(unsupported); setHold(false); return }
        // Smart start: while nothing is ready at the playhead, hold the video briefly
        // instead of letting the first lines go by unsubtitled. Never while the model is
        // still loading, never longer than 12 s, and not again if the viewer pressed play.
        let modelLoading = !engineLoaded
        // The page reports the pause up to 250 ms late; after that, playing means the viewer pressed play.
        if holding, !paused, Date().timeIntervalSince(holdStartedAt ?? .now) > 1.5 { holdDisabledForVideo = true; holding = false }
        if settings.holdForSubtitles, !holdDisabledForVideo, !modelLoading {
            if !holding, ahead < 0.5, !paused, buffered > 0 { setHold(true); holdStartedAt = Date() }
            else if holding, ahead >= 3 || Date().timeIntervalSince(holdStartedAt ?? .now) > 12 {
                if ahead < 3 { holdDisabledForVideo = true }
                setHold(false)
            }
            if holding { phase = .holding; return }
        } else if holding { setHold(false) }
        if !engineLoaded { phase = .loadingModel; return }
        if ahead >= 1 { phase = .ready(ahead: ahead) }
        else if cues.isEmpty { phase = .preparing(buffered) }
        else { phase = .catchingUp }
    }

    private func setHold(_ on: Bool) {
        guard on != holding else { return }
        holding = on
        let js = "window.__liveSubsHold && window.__liveSubsHold(\(on))"
        if let f = mainFrame { webView.evaluateJavaScript(js, in: f, in: .page, completionHandler: nil) }
        else { webView.evaluateJavaScript(js, completionHandler: nil) }
    }

    /// Fullscreen on iPhone uses the system player, which shows only the video's own text
    /// tracks: hand it the cues near the playhead.
    private func pushCuesToTrack(frame: WKFrameInfo) {
        guard isFullscreen else { return }
        for c in cues where c.start > playhead - 2 && c.start < playhead + 60 && !pushedToTrack.contains(c.start) {
            pushedToTrack.insert(c.start)
            let text = settings.showOriginal && !c.original.isEmpty ? "\(c.original)\n\(c.english)" : c.english
            webView.callAsyncJavaScript("window.__liveSubsCue && window.__liveSubsCue(s, e, t)",
                                        arguments: ["s": c.start, "e": max(c.end, c.start + 1.2), "t": text],
                                        in: frame, in: .page, completionHandler: nil)
        }
    }
}

extension BrowserModel {
    static let adBlockLists = ["blocklist-hosts", "blocklist-network", "blocklist-cosmetic"]

    /// The bundled ad, tracker and ad-element rules (StevenBlack/hosts, EasyList, EasyPrivacy;
    /// Tools/make-blocklist.py), compiled once by WebKit and reused. Only compiled rules are
    /// stored, never anything about pages. Called at app launch so the browser opens protected.
    static func adBlockers() async -> [WKContentRuleList] {
        if let ready = compiled { return ready }
        if let running = compiling { return await running.value }
        let task = Task { @MainActor () -> [WKContentRuleList] in
            guard let store = WKContentRuleListStore.default() else { return [] }
            var lists: [WKContentRuleList] = []
            let existing = await store.availableIdentifiers() ?? []
            for name in adBlockLists {
                guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
                      let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else { continue }
                let id = "livesubs-\(name)-\(size)"
                for old in existing where old.hasPrefix("livesubs-\(name)-") && old != id {
                    try? await store.removeContentRuleList(forIdentifier: old)
                }
                if let cached = try? await store.contentRuleList(forIdentifier: id) { lists.append(cached); continue }
                guard let json = try? String(contentsOf: url, encoding: .utf8),
                      let list = try? await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) else { continue }
                lists.append(list)
            }
            // Clean up the single list used by earlier builds.
            for old in existing where old.hasPrefix("livesubs-adblock-") { try? await store.removeContentRuleList(forIdentifier: old) }
            return lists
        }
        compiling = task
        let lists = await task.value
        compiled = lists
        return lists
    }

    private static var compiled: [WKContentRuleList]?
    private static var compiling: Task<[WKContentRuleList], Never>?
}

extension BrowserModel: WKUIDelegate {
    /// Pop-ups: a link you tapped opens here; windows a page opens by itself are blocked.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.navigationType == .linkActivated {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

extension BrowserModel: WKNavigationDelegate {
    /// Stay on the web: no redirects into the App Store or other apps.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        let allowed = ["http", "https", "about", "blob", "data", "javascript"].contains(scheme)
        decisionHandler(allowed ? .allow : .cancel)
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in
            self.address = webView.url?.absoluteString ?? self.address
            self.resetVideo()
        }
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: BrowserModel?
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any] else { return }
        let frame = m.frameInfo
        MainActor.assumeIsolated { target?.receive(body, frame: frame) }
    }
}
