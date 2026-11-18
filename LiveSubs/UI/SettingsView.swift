import Speech
import SwiftUI
import Translation

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var models: ModelManager
    @Environment(\.dismiss) private var dismiss
    @State private var appleLocales: [Locale] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        UsualLanguagesView()
                    } label: {
                        LabeledContent("What you watch", value: usualSummary)
                    }
                    NavigationLink {
                        QualityView()
                    } label: {
                        LabeledContent("Quality", value: settings.quality.title)
                    }
                }

                ReadinessSection()

                Section("Subtitles") {
                    NavigationLink {
                        SubtitleStyleView()
                    } label: {
                        LabeledContent("Style", value: settings.subtitleStyle.title)
                    }
                    NaturalEnglishRow()
                    Toggle("Show the original words", isOn: $settings.showOriginal)
                    VStack(alignment: .leading) {
                        Text("Text size")
                        Slider(value: $settings.fontScale, in: 0.7...1.4, step: 0.1) {
                            Text("Text size")
                        } minimumValueLabel: { Image(systemName: "textformat.size.smaller") }
                          maximumValueLabel: { Image(systemName: "textformat.size.larger") }
                    }
                    Toggle("Show detected language", isOn: $settings.showBadge)
                }

                Section {
                    Toggle("Subtitles in the Dynamic Island", isOn: $settings.islandSubtitles)
                    Toggle("Pop open for each new line", isOn: $settings.islandPopOpen)
                        .disabled(!settings.islandSubtitles)
                } header: {
                    Text("Dynamic Island and Lock Screen")
                } footer: {
                    Text("The newest words ride beside the camera; long-press the island for the whole line. On the Lock Screen the full line shows, which is handy with Microphone mode. Popping open may light up the screen.")
                }

                Section {
                    Toggle("Wait for subtitles", isOn: $settings.holdForSubtitles)
                    Toggle("Block ads and pop-ups", isOn: $settings.blockAds)
                    Toggle("Use Whisper instead of Apple's recogniser", isOn: $settings.browserUseWhisper)
                } header: {
                    Text("Private browser")
                } footer: {
                    Text("Wait for subtitles: at the start and after you skip ahead, the video pauses a moment until its first lines are ready. Blocking uses about 150,000 built-in rules (EasyList, EasyPrivacy and 76,000 ad and tracker domains), hides ad boxes, skips YouTube ads, and stops pop-ups and jumps to other apps. It all runs on this iPhone. Speech is recognised by Apple's recogniser, the most accurate on long Japanese and Korean audio in our tests; the Whisper switch (all modes) is slower and turns off natural English to save memory. Whisper is still used to detect the language when several are ticked.")
                }

                Section {
                    Picker("Stop when quiet for", selection: $settings.autoStopMinutes) {
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("30 minutes").tag(30)
                        Text("Never").tag(0)
                    }
                } footer: {
                    Text("Saves battery if you forget to stop.")
                }

                Section {
                    NavigationLink("Advanced") { advanced }
                }

                Section {
                    Label("Audio and subtitles never leave this iPhone. The internet is only used to download models and language packs.", systemImage: "lock.shield")
                        .font(.footnote)
                    Label("Protected (DRM) streams such as Netflix or Apple TV+ may block audio capture — that's an iOS protection this app does not bypass.", systemImage: "info.circle")
                        .font(.footnote)
                } header: { Text("Privacy") } footer: {
                    Text("LiveSubs \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · built \(Bundle.main.object(forInfoDictionaryKey: "LiveSubsBuildStamp") as? String ?? "")")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { appleLocales = await SpeechTranscriber.supportedLocales.sorted { name($0) < name($1) } }
        }
    }

    private var usualSummary: String {
        let l = settings.usualLanguages
        switch l.count {
        case 0: return "Any"
        case 1, 2: return l.map(WhisperLanguages.name).joined(separator: ", ")
        default: return "\(l.count) languages"
        }
    }

    /// The engine-level controls, for people who want them. Quality sets these for you.
    private var advanced: some View {
        Form {
            Section {
                Picker("Engine", selection: $settings.engine) {
                    ForEach(EngineKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Speech engine")
            } footer: {
                Text(settings.engine == .whisper
                     ? "Whisper detects the spoken language automatically (about 100 languages) and translates to English on-device."
                     : "Apple's built-in recognizer is the fastest and most battery-friendly, but you choose the spoken language and fewer languages are available.")
            }

            if settings.engine == .whisper { whisperSection } else { appleSection }

            if #available(iOS 27.0, *) {
                Section {
                    Picker("Capture method", selection: $settings.captureMethod) {
                        ForEach(AppSettings.CaptureMethod.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("Automatic uses iOS 27 screen capture. If a video app's sound doesn't come through, try the classic broadcast extension.")
                }
            }
        }
        .navigationTitle("Advanced")
    }

    private var whisperSection: some View {
        Group {
            Section("Whisper") {
                NavigationLink {
                    ModelsView()
                } label: {
                    LabeledContent("Speech model", value: settings.model.displayName)
                }
                Picker("Language", selection: $settings.spokenLanguage) {
                    Text("Automatic").tag("")
                    ForEach(WhisperLanguages.sortedByName, id: \.self) { Text(WhisperLanguages.name($0)).tag($0) }
                }
            }
            Section {
                Toggle("Use Apple Translation when available", isOn: $settings.preferAppleTranslation)
                NavigationLink("Apple language packs") { TranslationPacksView() }
            } footer: {
                Text("When a language pack is installed, Whisper transcribes and Apple translates — usually more natural English. Otherwise Whisper translates by itself.")
            }
        }
    }

    private var appleSection: some View {
        Section {
            Picker("Language", selection: $settings.appleLanguage) {
                ForEach(appleLocales, id: \.identifier) { Text(name($0)).tag($0.identifier) }
            }
            NavigationLink("Apple language packs") { TranslationPacksView() }
        } header: {
            Text("Apple")
        } footer: {
            Text("The speech model for this language downloads automatically the first time. Install its translation pack below for English subtitles.")
        }
    }

    private func name(_ l: Locale) -> String {
        Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier
    }
}

struct ModelsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var models: ModelManager

    var body: some View {
        List {
            Section {
                ForEach(WhisperModel.catalog) { m in row(m) }
            } footer: {
                Text("Models come from huggingface.co/argmaxinc/whisperkit-coreml (OpenAI Whisper, MIT license) and are stored only on this iPhone. Larger models are more accurate but slower and use more battery.")
            }
        }
        .navigationTitle("Speech models")
        .onAppear { models.refresh() }
    }

    @ViewBuilder private func row(_ m: WhisperModel) -> some View {
        let selected = settings.whisperModel == m.variant
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(m.displayName).font(.body.weight(.semibold))
                Text(m.summary).font(.caption).foregroundStyle(.secondary)
                status(m)
            }
            Spacer()
            action(m)
        }
        .contentShape(Rectangle())
        .onTapGesture { settings.whisperModel = m.variant }
        .swipeActions {
            if models.isReady(m) {
                Button("Delete", role: .destructive) { models.delete(m) }
            }
        }
    }

    @ViewBuilder private func status(_ m: WhisperModel) -> some View {
        switch models.phase(m) {
        case .ready:
            Text("Downloaded · \(ByteCountFormatter.string(fromByteCount: ModelStore.sizeOnDisk(m), countStyle: .file))")
                .font(.caption2).foregroundStyle(.green)
        case .downloading(let p):
            ProgressView(value: p).frame(maxWidth: 160)
        case .preparing:
            Text("Optimizing for this iPhone…").font(.caption2).foregroundStyle(.secondary)
        case .failed(let e):
            Text(e).font(.caption2).foregroundStyle(.red)
        case .notDownloaded:
            Text("\(m.approxMB) MB").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func action(_ m: WhisperModel) -> some View {
        switch models.phase(m) {
        case .notDownloaded, .failed:
            Button { models.download(m) } label: { Image(systemName: "arrow.down.circle").font(.title2) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download \(m.displayName)")
        case .downloading:
            Button { models.cancel(m) } label: { Image(systemName: "xmark.circle").font(.title2) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel download")
        case .preparing:
            ProgressView()
        case .ready:
            Button(role: .destructive) { models.delete(m) } label: { Image(systemName: "trash").font(.body) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(m.displayName)")
        }
    }
}

/// Lists Apple Translation languages → English and lets the user install packs.
/// Downloads must go through a SwiftUI `.translationTask` (iOS shows its own consent sheet).
struct TranslationPacksView: View {
    @State private var rows: [(Locale.Language, LanguageAvailability.Status)] = []
    @State private var config: TranslationSession.Configuration?
    private let english = Locale.Language(identifier: "en")

    var body: some View {
        List {
            Section {
                ForEach(rows, id: \.0.minimalIdentifier) { lang, status in
                    HStack {
                        Text(Locale.current.localizedString(forIdentifier: lang.minimalIdentifier) ?? lang.minimalIdentifier)
                        Spacer()
                        switch status {
                        case .installed:
                            Label("Installed", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                        case .supported:
                            Button("Get") { config = .init(source: lang, target: english) }
                                .buttonStyle(.bordered).controlSize(.small)
                        default:
                            EmptyView()
                        }
                    }
                }
            } footer: {
                Text("Language packs are provided by Apple, stored on-device, and shared with the Translate app. Manage them in Settings ▸ Apps ▸ Translate.")
            }
        }
        .navigationTitle("Language packs")
        .task { await load() }
        .translationTask(config) { session in
            try? await session.prepareTranslation()
            await load()
        }
    }

    private func load() async {
        let availability = LanguageAvailability()
        var out: [(Locale.Language, LanguageAvailability.Status)] = []
        for lang in await availability.supportedLanguages where lang.languageCode != english.languageCode {
            out.append((lang, await availability.status(from: lang, to: english)))
        }
        rows = out.sorted {
            (Locale.current.localizedString(forIdentifier: $0.0.minimalIdentifier) ?? "") <
            (Locale.current.localizedString(forIdentifier: $1.0.minimalIdentifier) ?? "")
        }
    }
}
