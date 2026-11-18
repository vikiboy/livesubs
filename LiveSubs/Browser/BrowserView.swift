import SwiftUI
import Translation
import WebKit

/// Private browser with subtitles prepared ahead of playback.
struct BrowserView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: BrowserModel
    @FocusState private var addressFocused: Bool
    @State private var typed = ""
    @State private var showExit = false
    @State private var packConfig: TranslationSession.Configuration?

    init(settings: AppSettings) {
        _model = StateObject(wrappedValue: BrowserModel(settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.inAppFullscreen { addressBar }
            ZStack(alignment: .topLeading) {
                WebViewHost(webView: model.webView)
                subtitleOverlay
                if model.address.isEmpty { emptyState }
                if model.inAppFullscreen {
                    // Tap anywhere to show or hide LiveSubs' controls.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showExit.toggle() } }
                    if showExit { FullscreenControls(model: model, hide: { showExit = false }) }
                }
            }
            if !model.inAppFullscreen, let lang = model.missingPack { packBanner(lang) }
            if !model.inAppFullscreen { statusBar }
        }
        .background(Color.black)
        .ignoresSafeArea(edges: model.inAppFullscreen ? .all : [])
        .statusBarHidden(model.inAppFullscreen)
        .persistentSystemOverlays(model.inAppFullscreen ? .hidden : .automatic)
        .onDisappear { OrientationLock.setFullscreen(false); model.setActive(true) }
        .onChange(of: scenePhase) { _, phase in model.setActive(phase == .active) }
        .onChange(of: model.inAppFullscreen) { _, on in showExit = on }
        // Apple shows its own download sheet for the language pack.
        .translationTask(packConfig) { session in
            do { try await session.prepareTranslation(); model.packInstalled() } catch {}
            packConfig = nil
        }
        // Cover the page whenever the app isn't in front, so the app-switcher snapshot
        // iOS saves never contains what you were watching.
        .overlay {
            if scenePhase != .active {
                ZStack {
                    Color.black
                    Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(Theme.tertiaryText)
                }
                .ignoresSafeArea()
            }
        }
        .onAppear {
            addressFocused = model.address.isEmpty
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-browserURL"), i + 1 < args.count {
                addressFocused = false; typed = args[i + 1]; model.open(args[i + 1])
            }
            #endif
        }
    }

    // MARK: Pieces

    private var addressBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.close(); dismiss() }
            } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 34, height: 34)
            }
            .accessibilityLabel("Close and forget this page")
            if model.canGoBack {
                Button { model.goBack() } label: { Image(systemName: "chevron.left").frame(width: 30, height: 34) }
                    .accessibilityLabel("Back")
            }
            HStack(spacing: 6) {
                Image(systemName: "eye.slash").font(.caption).foregroundStyle(Theme.tertiaryText)
                TextField("Paste a video link", text: $typed)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit { model.open(typed) }
                    .onChange(of: model.address) { _, new in if !addressFocused { typed = new } }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Theme.row, in: Capsule())
            PasteButton(payloadType: String.self) { strings in
                guard let s = strings.first else { return }
                typed = s
                model.open(s)
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .tint(Theme.subtitle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var subtitleOverlay: some View {
        GeometryReader { geo in
            if let cue = model.cue, !model.isFullscreen {
                let full = CGRect(origin: .zero, size: geo.size)
                let rect = model.inAppFullscreen ? full
                    : (model.videoRect ?? CGRect(x: 0, y: geo.size.height - 160, width: geo.size.width, height: 160))
                let scale = model.inAppFullscreen ? 1.45 : 1.0
                VStack(spacing: 4) {
                    if settings.showOriginal, !cue.original.isEmpty {
                        Text(cue.original)
                            .font(.system(size: 13 * settings.fontScale * scale, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Text(cue.english)
                        .font(Theme.subtitle(.body, size: 19 * settings.fontScale * scale))
                        .foregroundStyle(Theme.subtitle)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .shadow(color: .black, radius: 0, x: 1, y: 1)
                .shadow(color: .black, radius: 2)
                .padding(.horizontal, 10)
                .frame(width: max(160, min(rect.width, model.inAppFullscreen ? geo.size.width * 0.8 : rect.width)))
                .position(x: rect.midX, y: model.inAppFullscreen ? geo.size.height - 56 : min(geo.size.height - 30, rect.maxY - 34))
                .allowsHitTesting(false)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.12), value: cue)
                .accessibilityLabel("Subtitle")
                .accessibilityValue(cue.english)
            }
        }
    }

    /// Lines are in Japanese (say) because Apple's translation pack for it isn't installed.
    private func packBanner(_ lang: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Showing \(WhisperLanguages.name(lang)), not English").font(.subheadline.weight(.semibold))
                Text("Get Apple's \(WhisperLanguages.name(lang)) → English pack (one time, on this iPhone). Lines already done turn into English.")
                    .font(.footnote).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            Button("Get") {
                packConfig = .init(source: Locale.Language(identifier: lang), target: Locale.Language(identifier: "en"))
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(.black)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.row)
    }

    /// Fullscreen: a quiet exit control in the corner (always tappable, never over the subtitles).
    private var fullscreenExit: some View {
        Button {
            model.exitFullscreen()
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.35), in: Circle())
        }
        .padding(.top, 14).padding(.leading, 14)
        .accessibilityLabel("Exit full screen")
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon).foregroundStyle(statusColor)
                Text(statusText).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let detail = engineLine {
                Text(detail).font(.caption).foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black)
        .animation(.default, value: statusText)
    }

    /// Which engines are in use, and any problem, so nothing fails silently.
    private var engineLine: String? {
        let d = model.diagnostics
        if let problem = d.problem { return problem }
        guard let rec = d.recognizer else { return nil }
        var parts = [d.language.map(WhisperLanguages.name) ?? "", rec].filter { !$0.isEmpty }
        if settings.naturalEnglish, !settings.browserUseWhisper {
            parts.append(GemmaTranslator.isDownloaded ? "TranslateGemma: \(d.natural) of \(d.lines) lines natural"
                                                      : "Apple Translation (get TranslateGemma in Settings for natural English)")
        } else {
            parts.append("Apple Translation")
        }
        return parts.joined(separator: " · ")
    }

    private var statusText: String {
        switch model.phase {
        case .idle: return model.blockingAds ? "Private, ads blocked. Play a video to start."
                                             : "Private: no history, cookies or subtitles are kept. Play a video to start."
        case .loadingModel: return "Loading \(settings.model.displayName.replacingOccurrences(of: " (recommended)", with: ""))… (the first time after an update can take a few minutes)"
        case .preparing(let s):
            if let stage = model.diagnostics.stage { return stage }
            return s < 1 ? "Reading the video's sound…" : "Preparing the first lines… (\(Int(s)) s of audio downloaded so far)"
        case .ready(let ahead):
            let lead = ahead >= 90 ? "\(Int(ahead / 60)) min ahead" : "\(Int(ahead)) s ahead"
            guard model.duration > 60 else { return "Subtitles ready \(lead)" }
            let pct = min(100, Int(model.doneSeconds / model.duration * 100))
            return pct >= 99 ? "Whole video subtitled" : "Subtitles ready \(lead) · whole video \(pct)% done"
        case .catchingUp: return model.diagnostics.stage ?? "Catching up after a jump…"
        case .holding: return "Holding the video a moment while the first lines get ready…"
        case .cannotRead(let why): return why
        case .failed(let why): return why
        }
    }

    private var statusIcon: String {
        switch model.phase {
        case .ready: "checkmark.circle.fill"
        case .cannotRead, .failed: "exclamationmark.triangle.fill"
        case .idle: "eye.slash"
        default: "hourglass"
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .ready: Theme.subtitle
        case .cannotRead, .failed: Theme.stop
        default: Theme.tertiaryText
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Watch with subtitles ready in advance")
                .font(.title3.weight(.bold))
            Text("Paste a link to a page with a video. LiveSubs reads the sound the site has already downloaded, so English lines are ready before each one is spoken, and appear right on the video.")
                .foregroundStyle(Theme.secondaryText)
            Label("Nothing is saved: no history, cookies, cache or subtitles. Closing forgets the page.", systemImage: "eye.slash")
                .font(.footnote).foregroundStyle(Theme.tertiaryText)
            Label("Protected services (Netflix and the like) can't be read.", systemImage: "lock")
                .font(.footnote).foregroundStyle(Theme.tertiaryText)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
    }
}

private struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView {
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}


/// LiveSubs' fullscreen controls: play/pause, back/forward 10 s, and a scrub bar whose
/// yellow stretches show where subtitles are already ready.
private struct FullscreenControls: View {
    @ObservedObject var model: BrowserModel
    let hide: () -> Void
    @State private var dragging: Double?
    @State private var tick = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = max(model.duration, 1)
            let position = dragging ?? model.position
            VStack(spacing: 0) {
                HStack {
                    Button { model.exitFullscreen(); hide() } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Exit full screen")
                    Spacer()
                    Text(statusLine).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 16).padding(.top, 10)
                Spacer()
                HStack(spacing: 44) {
                    Button { model.control("skip", -10) } label: { Image(systemName: "gobackward.10") }
                        .accessibilityLabel("Back 10 seconds")
                    Button { model.control("toggle") } label: {
                        Image(systemName: model.isPaused ? "play.fill" : "pause.fill").font(.system(size: 40))
                    }
                    .accessibilityLabel(model.isPaused ? "Play" : "Pause")
                    Button { model.control("skip", 10) } label: { Image(systemName: "goforward.10") }
                        .accessibilityLabel("Forward 10 seconds")
                }
                .font(.system(size: 28, weight: .semibold))
                Spacer()
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        let w = geo.size.width
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                            ForEach(Array(model.covered.enumerated()), id: \.offset) { _, r in
                                Capsule().fill(Theme.subtitle.opacity(0.75))
                                    .frame(width: max(2, w * (r.upperBound - r.lowerBound) / duration), height: 4)
                                    .offset(x: w * r.lowerBound / duration)
                            }
                            Circle().fill(.white).frame(width: 14, height: 14)
                                .offset(x: max(0, min(w - 14, w * position / duration - 7)))
                        }
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { g in dragging = max(0, min(duration, g.location.x / w * duration)) }
                            .onEnded { _ in if let d = dragging { model.control("seek", d) }; dragging = nil })
                    }
                    .frame(height: 24)
                    .accessibilityElement()
                    .accessibilityLabel("Position")
                    .accessibilityValue("\(Self.time(position)) of \(Self.time(duration))")
                    .accessibilityAdjustableAction { dir in model.control("skip", dir == .increment ? 10 : -10) }
                    HStack {
                        Text(Self.time(position)); Spacer()
                        Text("yellow = subtitles ready").foregroundStyle(Theme.subtitle.opacity(0.8))
                        Spacer(); Text(Self.time(duration))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 20).padding(.bottom, 18)
            }
            .foregroundStyle(.white)
            .background(LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
        }
        .transition(.opacity)
        .task(id: tick) { try? await Task.sleep(for: .seconds(4)); if dragging == nil { hide() } }
    }

    private var statusLine: String {
        switch model.phase {
        case .ready(let a): return a >= 90 ? "Subtitles ready \(Int(a / 60)) min ahead" : "Subtitles ready \(Int(a)) s ahead"
        case .catchingUp: return "Catching up…"
        case .holding: return "Getting the first lines ready…"
        default: return ""
        }
    }

    static func time(_ t: Double) -> String {
        let s = Int(max(0, t)); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
