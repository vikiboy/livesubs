/*
 THESIS: The app is a darkened auditorium whose screen is the subtitle itself; it refuses
   the utility-app arrangement of a preview card over a blue round button.
 OWN-WORLD: True black house, a 2.39:1 frame edge to edge with a hairline projector gate,
   release-print subtitle yellow (#FFE14D) in Helvetica Bold with a black edge as the only
   bright thing; an Academy countdown leader is the single control; stock iOS inset lists
   below, yellow tint.
 STORY: The viewer sees their subtitles' exact look first, taps the leader, watches it
   sweep through standby, and leaves for their video app while the frame floats.
 FIRST VIEWPORT: Frame full-bleed under the large title; reel line under it; the leader
   centred at 184 pt below; status as one caption line; Listen-to / Language / Model rows.
 FORM: Burnt-in Cinema Subtitles, own-list position 1 (IMPECCABLE’S PICK); seed 7462b87f.
 FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review,
   the verdict, and DESIGN.md
 */
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: LiveSession
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var models: ModelManager
    @State private var showSettings = false
    @State private var showStartGuide = false
    @State private var showBrowser = false

    private var needsModel: Bool {
        settings.engine == .whisper && !models.isReady(settings.model)
    }

    var body: some View {
        NavigationStack {
            List {
                screen
                control
                if !session.history.isEmpty { historySection }
                options
                if !session.state.isActive { browserEntry; practice }
                guide
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("LiveSubs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "slider.horizontal.3") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: $showBrowser) {
                BrowserView(settings: settings)
                    .environmentObject(settings)
                    .preferredColorScheme(.dark)
                    .tint(Theme.subtitle)
            }
            .sheet(isPresented: $showStartGuide) {
                StartGuideView {
                    settings.startGuideSeen = true
                    showStartGuide = false
                    // Let the sheet go before iOS presents its own.
                    Task { try? await Task.sleep(for: .milliseconds(450)); session.start() }
                }
            }
            #if DEBUG
            .onAppear {
                // Screenshot hooks for design review (Debug builds only).
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-reviewSettings") { showSettings = true }
                if args.contains("-reviewDemo") { session.showDemoSubtitles() }
                if args.contains("-reviewDownloading") { models.showDemoDownload(settings.model) }
                if args.contains("-reviewGuide") { showStartGuide = true }
                if args.contains("-browserURL") { showBrowser = true }
                if let i = args.firstIndex(of: "-practice"), i + 1 < args.count { session.startPractice(language: args[i + 1]) }
            }
            #endif
            .background(alignment: .bottomLeading) {
                // System broadcast picker for the classic capture path; tapped in code.
                BroadcastPickerView(session: session)
                    .frame(width: 1, height: 1)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: The screen

    private var screen: some View {
        Section {
            PiPHostView(pip: session.pip)
                .aspectRatio(Theme.frameAspect, contentMode: .fit)
                .overlay {
                    Rectangle().strokeBorder(Theme.gate, lineWidth: 1)
                }
                .accessibilityElement()
                .accessibilityLabel("Subtitle preview")
                .accessibilityValue(session.subtitle.committed.last ?? session.subtitle.tentative)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.black)
        } footer: {
            HStack(spacing: 6) {
                Image(systemName: session.pip.isActive ? "pip.fill" : "pip")
                Text(reelLine)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .padding(.horizontal, 20)
            .animation(.default, value: reelLine)
        }
        .listSectionMargins(.horizontal, 0)
    }

    private var reelLine: String {
        if session.pip.isActive { return "Floating over your apps" }
        if let lang = session.subtitle.sourceLanguage, session.state.isActive {
            return lang == "en" ? "Hearing English" : "Hearing \(WhisperLanguages.name(lang)), showing English"
        }
        return "This frame floats over any video app"
    }

    // MARK: The leader

    private var control: some View {
        Section {
            VStack(spacing: 18) {
                LeaderControl(mode: leaderMode) {
                    if needsModel, !session.state.isActive {
                        models.download(settings.model)
                    } else if !session.state.isActive, settings.source == .otherApps, !settings.startGuideSeen {
                        showStartGuide = true
                    } else {
                        session.toggle()
                    }
                }
                statusLine
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    private var leaderMode: LeaderControl.Mode {
        switch session.state {
        case .preparing, .waitingForBroadcast: return .loading
        case .running: return .running(level: session.audioLevel)
        case .paused: return .paused
        case .idle, .failed:
            guard needsModel else { return .start }
            switch models.phase(settings.model) {
            case .downloading(let p): return .downloading(p)
            case .preparing: return .loading
            default: return .download
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        VStack(spacing: 8) {
            Group {
                switch session.state {
                case .idle:
                    Text(idleCopy)
                case .preparing(let msg):
                    Text(msg)
                case .waitingForBroadcast:
                    VStack(spacing: 6) {
                        Text("Choose **LiveSubs**, then **Start Broadcast**.")
                        Button("Show the sheet again") { session.triggerBroadcastPicker() }
                            .font(.subheadline.weight(.semibold))
                    }
                case .running:
                    if let lang = session.practiceLanguage {
                        Text("Playing the \(WhisperLanguages.name(lang)) practice clip with subtitles prepared ahead.")
                    } else {
                        Text(session.pip.isActive ? "Switch to your video. Subtitles follow you."
                                                  : "Swipe up to go home; the frame will float.")
                    }
                case .paused:
                    Text("Paused from the floating frame.")
                case .failed(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.stop)
                }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)

            if let report = session.practiceReport, !session.state.isActive {
                Text(report).font(.footnote).foregroundStyle(Theme.tertiaryText).multilineTextAlignment(.center)
            } else if let d = session.practiceDelay, !session.state.isActive {
                Text("On this iPhone, each finished line arrived about \(String(format: "%.1f", d)) s after it was spoken (\(settings.quality.title)).")
                    .font(.footnote).foregroundStyle(Theme.tertiaryText).multilineTextAlignment(.center)
            }
            if session.isHot, session.state.isActive {
                Text("Your iPhone is warm, so subtitles may lag. Quality ▸ Fastest uses less power.")
                    .font(.footnote).foregroundStyle(Theme.tertiaryText).multilineTextAlignment(.center)
            }
            if let hint = session.hint {
                Text(hint).font(.footnote).foregroundStyle(Theme.tertiaryText).multilineTextAlignment(.center)
            }
            if let err = session.pip.lastError, session.state.isActive {
                Text(err).font(.footnote).foregroundStyle(Theme.tertiaryText).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 12)
    }

    private var idleCopy: String {
        guard needsModel else {
            if settings.spokenLanguage.isEmpty, !settings.lastLanguage.isEmpty, settings.lastLanguage != "en" {
                return "Tap Start, then play a video in any app. Last time you watched \(WhisperLanguages.name(settings.lastLanguage))."
            }
            return "Tap Start, then play a video in any app."
        }
        switch models.phase(settings.model) {
        case .downloading: return "Downloading \(settings.model.displayName). This happens once."
        case .preparing: return "Tuning the model for this iPhone…"
        case .failed(let e): return e
        default: return "One-time download: \(settings.model.approxMB) MB. Then everything runs offline."
        }
    }

    // MARK: Options

    private var options: some View {
        Section {
            Picker("Listen to", selection: $settings.source) {
                Text("Videos on iPhone").tag(AudioSourceKind.otherApps)
                Text("Microphone").tag(AudioSourceKind.microphone)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Theme.row)

            NavigationLink {
                QualityView()
            } label: {
                LabeledContent {
                    Text(settings.quality.title)
                } label: {
                    Label("Quality", systemImage: "dial.medium")
                }
            }
            .listRowBackground(Theme.row)

            if settings.engine == .whisper {
                Picker(selection: $settings.spokenLanguage) {
                    Text("Automatic").tag("")
                    ForEach(WhisperLanguages.sortedByName, id: \.self) { Text(WhisperLanguages.name($0)).tag($0) }
                } label: {
                    Label("Language", systemImage: "waveform")
                }
                .pickerStyle(.navigationLink)
                .listRowBackground(Theme.row)
            } else {
                Button { showSettings = true } label: {
                    LabeledContent {
                        Text(Locale.current.localizedString(forIdentifier: settings.appleLanguage) ?? settings.appleLanguage)
                    } label: {
                        Label("Language", systemImage: "waveform")
                    }
                }
                .foregroundStyle(.primary)
                .listRowBackground(Theme.row)
            }
        } footer: {
            Label("Runs on this iPhone. Nothing is uploaded.", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(Theme.tertiaryText)
        }
        .disabled(session.state.isActive)
    }

    // MARK: History and practice

    private var historySection: some View {
        Section {
            ForEach(session.history.suffix(30).reversed()) { line in
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.english).font(.body)
                    if !line.original.isEmpty {
                        Text(line.original).font(.footnote).foregroundStyle(Theme.tertiaryText)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(Theme.row)
        } header: {
            HStack {
                Text(session.state.isActive ? "This session" : "Last session")
                Spacer()
                ShareLink(item: SubtitleExport(lines: session.history),
                          preview: SharePreview("LiveSubs subtitles")) {
                    Label("Save subtitles", systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .font(.footnote.weight(.semibold))
                .textCase(nil)
            }
        }
    }

    private var browserEntry: some View {
        Section {
            Button {
                showBrowser = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Private browser").foregroundStyle(.primary)
                        Text("Subtitles ready before each line is spoken").font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                } icon: {
                    Image(systemName: "eye.slash")
                }
            }
            .disabled(needsModel)
            .listRowBackground(Theme.row)
        } footer: {
            Text("Paste a link to any video page. Nothing is kept: no history, cookies or subtitles.")
                .font(.footnote)
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private var practice: some View {
        Section {
            Menu {
                ForEach(SampleAudioSource.languages, id: \.self) { code in
                    Button(WhisperLanguages.name(code)) { session.startPractice(language: code) }
                }
            } label: {
                Label("Try a practice clip", systemImage: "play.rectangle")
            }
            .disabled(needsModel)
            .listRowBackground(Theme.row)
        } footer: {
            Text("Plays a short clip out loud and subtitles it, so you can see how it works without another app.")
                .font(.footnote)
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private var guide: some View {
        Section("How it works") {
            step(1, "Tap Start. iOS asks to share screen audio; allow it.")
            step(2, "Open YouTube, Safari or TikTok and play a video.")
            step(3, "English subtitles float above it. Drag or pinch the frame.")
            step(4, "Stop here, close the frame, or tap the red recording pill.")
        }
        .listRowBackground(Theme.row)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(Theme.subtitle(.subheadline, size: 15))
                .foregroundStyle(Theme.subtitle)
                .frame(width: 16)
            Text(text).font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
