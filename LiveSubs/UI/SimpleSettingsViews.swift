import SwiftUI
import Translation
import UniformTypeIdentifiers

/// Fastest / Balanced / Most accurate. Picking one sets the engine, model and
/// translation route; what it needs (model, language packs) is listed underneath.
struct QualityView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var models: ModelManager

    var body: some View {
        List {
            Section {
                ForEach(Quality.allCases) { q in
                    Button {
                        settings.applyQuality(q)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: settings.quality == q ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(settings.quality == q ? Theme.subtitle : Theme.tertiaryText)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(q.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                Text(q.detail).font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityAddTraits(settings.quality == q ? .isSelected : [])
                }
            } footer: {
                if settings.quality == .fastest, settings.singleKnownLanguage == nil {
                    Text("Fastest needs one language. Pick it under What you watch, or set Language on the main screen; until then it works like Balanced.")
                } else if settings.quality != .accurate, watchesVerbFinal {
                    Text("For Japanese and Korean, Most accurate is recommended: in tests, the other settings sometimes turned “nobody came” into “someone came”.")
                }
            }
            ReadinessSection()
        }
        .navigationTitle("Quality")
    }
}

extension QualityView {
    var watchesVerbFinal: Bool {
        let langs = settings.usualLanguages + [settings.spokenLanguage, settings.lastLanguage]
        return langs.contains { ["ja", "ko"].contains($0) }
    }
}

/// What the current choice still needs, with one button to get it all.
struct ReadinessSection: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var models: ModelManager
    @State private var missingPacks: [String] = []
    @State private var packConfig: TranslationSession.Configuration?
    @State private var queue: [String] = []

    var body: some View {
        Section {
            if settings.engine == .whisper {
                row(title: "Speech model: \(settings.model.displayName.replacingOccurrences(of: " (recommended)", with: ""))",
                    ready: models.isReady(settings.model), detail: modelDetail)
            } else {
                row(title: "Apple speech recognition", ready: true,
                    detail: "Downloads by itself the first time you start.")
            }
            ForEach(packLanguages, id: \.self) { code in
                row(title: "\(WhisperLanguages.name(code)) → English pack", ready: !missingPacks.contains(code),
                    detail: missingPacks.contains(code) ? "From Apple, stored on this iPhone." : "Installed")
            }
            if !allReady {
                Button {
                    getEverything()
                } label: {
                    Label("Get everything", systemImage: "arrow.down.circle.fill").font(.body.weight(.semibold))
                }
                .disabled(isDownloading)
            }
        } header: {
            Text("Ready to go")
        } footer: {
            if settings.quality == .accurate, !missingPacks.isEmpty {
                Text("Most accurate translates through Apple's language packs. Without one, that language shows in its original words.")
            }
        }
        .task(id: packLanguages) { await refreshPacks() }
        .translationTask(packConfig) { session in
            try? await session.prepareTranslation()
            await refreshPacks()
            nextPack()
        }
    }

    private var packLanguages: [String] {
        var langs = settings.usualLanguages
        if let l = settings.singleKnownLanguage, !langs.contains(l) { langs.append(l) }
        return langs.filter { $0 != "en" }
    }

    private var allReady: Bool {
        (settings.engine == .apple || models.isReady(settings.model)) && missingPacks.isEmpty
    }


    private var isDownloading: Bool {
        if case .downloading = models.phase(settings.model) { return true }
        return models.phase(settings.model) == .preparing || packConfig != nil
    }

    private var modelDetail: String {
        switch models.phase(settings.model) {
        case .ready: "Downloaded"
        case .downloading(let p): "Downloading… \(Int(p * 100))%"
        case .preparing: "Tuning for this iPhone…"
        case .failed(let e): e
        case .notDownloaded: "\(settings.model.approxMB) MB, once"
        }
    }

    private func row(title: String, ready: Bool, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(ready ? Theme.subtitle : Theme.tertiaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func getEverything() {
        if settings.engine == .whisper, !models.isReady(settings.model) { models.download(settings.model) }
        queue = missingPacks
        nextPack()
    }

    /// Language packs install one at a time; iOS shows its own download sheet for each.
    private func nextPack() {
        guard !queue.isEmpty else { packConfig = nil; return }
        let code = queue.removeFirst()
        packConfig = .init(source: Locale.Language(identifier: code), target: Locale.Language(identifier: "en"))
    }

    private func refreshPacks() async {
        let availability = LanguageAvailability()
        var missing: [String] = []
        for code in packLanguages {
            let status = await availability.status(from: Locale.Language(identifier: code), to: Locale.Language(identifier: "en"))
            if status != .installed { missing.append(code) }
        }
        missingPacks = missing
    }
}

/// "What do you usually watch?" — a short list of common languages first.
struct UsualLanguagesView: View {
    @EnvironmentObject private var settings: AppSettings
    private let common = ["ja", "ko", "zh", "es", "fr", "de", "it", "pt", "hi", "ar", "ru", "tr", "th", "vi", "id"]

    var body: some View {
        List {
            Section {
                ForEach(common, id: \.self, content: row)
            } footer: {
                Text("LiveSubs prepares these languages and translates them best. It still recognises any language you play.")
            }
            Section("More languages") {
                ForEach(WhisperLanguages.sortedByName.filter { !common.contains($0) && $0 != "en" }, id: \.self, content: row)
            }
        }
        .navigationTitle("What you watch")
        // Fastest uses Apple's recognizer only when there is exactly one language to expect.
        .onDisappear { if settings.quality == .fastest { settings.applyQuality(.fastest) } }
    }

    private func row(_ code: String) -> some View {
        let on = settings.usualLanguages.contains(code)
        return Button {
            var l = settings.usualLanguages
            if on { l.removeAll { $0 == code } } else { l.append(code) }
            settings.usualLanguages = l
        } label: {
            HStack {
                Text(WhisperLanguages.name(code)).foregroundStyle(.primary)
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(Theme.subtitle) }
            }
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct SubtitleStyleView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List {
            Section {
                ForEach(SubtitleStyle.allCases) { style in
                    Button { settings.subtitleStyle = style } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: settings.subtitleStyle == style ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(settings.subtitleStyle == style ? Theme.subtitle : Theme.tertiaryText)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(style.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                Text(style.detail).font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityAddTraits(settings.subtitleStyle == style ? .isSelected : [])
                }
            } footer: {
                Text("Japanese and Korean put the verb, “not” and the tense at the end of a sentence, so a live guess can change a lot right before the line is finished.")
            }
        }
        .navigationTitle("Subtitle style")
    }
}

/// Shown once, before the first time iOS asks to share screen audio.
struct StartGuideView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("iOS will ask to share your screen's sound")
                .font(.title2.weight(.bold))
                .padding(.top, 36)
            VStack(alignment: .leading, spacing: 20) {
                step(1, "Choose **LiveSubs** in the list.")
                step(2, "Tap **Start Broadcast**. A red pill appears at the top of the screen.")
                step(3, "Open your video app. The subtitles float on top.")
            }
            Text("LiveSubs only listens to the sound. Nothing is recorded or sent anywhere. iOS asks every time; no app can skip that.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Button(action: onContinue) {
                Text("Continue").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(.black)
        }
        .padding(24)
        .presentationDetents([.large])
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(n)").font(Theme.subtitle(.headline, size: 18)).foregroundStyle(Theme.subtitle)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The session's lines as a SubRip (.srt) file for "Save subtitles".
struct SubtitleExport: Transferable {
    let lines: [LiveSession.SessionLine]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { export in
            Data(export.srt.utf8)
        }
        .suggestedFileName("LiveSubs.srt")
    }

    var srt: String {
        lines.enumerated().map { i, l in
            var block = "\(i + 1)\n\(Self.stamp(l.start)) --> \(Self.stamp(l.end))\n\(l.english)"
            if !l.original.isEmpty { block += "\n\(l.original)" }
            return block
        }.joined(separator: "\n\n") + "\n"
    }

    private static func stamp(_ t: TimeInterval) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}


/// Natural English subtitles with TranslateGemma: on/off, and its one-time download.
struct NaturalEnglishRow: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var gemma = GemmaDownloader.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Natural English", isOn: $settings.naturalEnglish)
            Text("Lines are re-translated by Google's TranslateGemma on this iPhone: conversational English that keeps the meaning. Private browser only for now.")
                .font(.footnote).foregroundStyle(Theme.secondaryText)
            switch gemma.phase {
            case .ready:
                Label("TranslateGemma downloaded", systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(Theme.subtitle)
            case .downloading(let p):
                ProgressView(value: p) { Text("Downloading TranslateGemma… \(Int(p * 100))%").font(.footnote) }
            case .failed(let e):
                Button("Retry download") { gemma.download() }.font(.footnote)
                Text(e).font(.caption).foregroundStyle(Theme.stop)
            default:
                Button {
                    gemma.download()
                } label: {
                    Label("Get TranslateGemma (\(GemmaTranslator.approxMB / 1000).\(GemmaTranslator.approxMB % 1000 / 100) GB, once)", systemImage: "arrow.down.circle.fill")
                        .font(.footnote.weight(.semibold))
                }
            }
        }
    }
}
