import Foundation
import SwiftUI

/// User preferences (UserDefaults-backed, never leave the device).
@MainActor
final class AppSettings: ObservableObject {
    enum CaptureMethod: String, CaseIterable, Identifiable {
        /// iOS 27+: ScreenCaptureKit in-process; iOS 26: ReplayKit extension.
        case automatic
        /// Force the ReplayKit broadcast extension (works on iOS 26 and 27).
        case broadcastExtension
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .broadcastExtension: "Broadcast extension (classic)"
            }
        }
    }

    @AppStorage("source") var source: AudioSourceKind = .otherApps
    @AppStorage("engine") var engine: EngineKind = .whisper
    @AppStorage("whisperModel") var whisperModel: String = WhisperModel.recommended.variant
    /// Empty = auto-detect (Whisper only).
    @AppStorage("spokenLanguage") var spokenLanguage: String = ""
    /// Apple engine needs an explicit language.
    @AppStorage("appleLanguage") var appleLanguage: String = "es-ES"
    @AppStorage("preferAppleTranslation") var preferAppleTranslation: Bool = true
    @AppStorage("captureMethod") var captureMethod: CaptureMethod = .automatic
    @AppStorage("fontScale") var fontScale: Double = 1.0
    @AppStorage("showOriginalLanguageBadge") var showBadge: Bool = true
    @AppStorage("onboarded") var onboarded: Bool = false

    // MARK: Simple choices (v2). These drive the engine keys above.

    @AppStorage("quality") var quality: Quality = .balanced
    /// Languages the user usually watches, comma-separated Whisper codes ("ja,ko").
    @AppStorage("usualLanguages") var usualLanguagesRaw: String = ""
    @AppStorage("subtitleStyle") var subtitleStyle: SubtitleStyle = .automatic
    @AppStorage("showOriginal") var showOriginal: Bool = false
    /// Stop after this many minutes without speech; 0 = never.
    @AppStorage("autoStopMinutes") var autoStopMinutes: Int = 10
    /// The language heard most recently (shown on the main screen, seeds Fastest).
    @AppStorage("lastLanguage") var lastLanguage: String = ""
    /// Mirror subtitles into the Dynamic Island and Lock Screen.
    @AppStorage("islandSubtitles") var islandSubtitles: Bool = true
    /// Briefly pop the island open for every finished line.
    @AppStorage("islandPopOpen") var islandPopOpen: Bool = false
    /// Rewrite literal translations as natural, conversational English (Apple Intelligence).
    @AppStorage("naturalEnglish") var naturalEnglish: Bool = true
    /// Private browser: use Whisper (slower, most accurate) instead of Parakeet / Apple's recogniser.
    @AppStorage("browserUseWhisper") var browserUseWhisper: Bool = false
    /// Private browser: block ads, trackers and pop-ups.
    @AppStorage("blockAds") var blockAds: Bool = true
    /// Private browser: pause the video for a moment until the first lines are ready.
    @AppStorage("holdForSubtitles") var holdForSubtitles: Bool = true
    /// The "how starting works" guide has been shown once.
    @AppStorage("startGuideSeen") var startGuideSeen: Bool = false

    var usualLanguages: [String] {
        get { usualLanguagesRaw.split(separator: ",").map(String.init) }
        set { usualLanguagesRaw = newValue.joined(separator: ",") }
    }

    var model: WhisperModel { WhisperModel.find(whisperModel) ?? .recommended }

    /// Quality → engine, model and translation route, from the Japanese/Korean benchmark
    /// (Tests/Harness/bench.sh, 2026-11-17, Mac): Small mistranslated a Korean negation;
    /// Turbo + Apple Translation and the Apple engine got all lines right; the Apple engine
    /// showed first words soonest but finished lines latest.
    func applyQuality(_ q: Quality) {
        quality = q
        preferAppleTranslation = true
        switch q {
        case .fastest:
            // Apple's recognizer streams words almost instantly but needs one known language.
            if let lang = singleKnownLanguage, let locale = Self.appleLocale(for: lang) {
                engine = .apple
                appleLanguage = locale
            } else {
                // Without one known language Apple can't help; Small is the quick Whisper.
                engine = .whisper
                whisperModel = WhisperModel.recommended.variant
            }
        case .balanced:
            engine = .whisper
            whisperModel = WhisperModel.recommended.variant
        case .accurate:
            engine = .whisper
            whisperModel = "openai_whisper-large-v3-v20240930_626MB"
        }
    }

    /// The one language to assume when Automatic isn't needed.
    var singleKnownLanguage: String? {
        if !spokenLanguage.isEmpty { return spokenLanguage }
        if usualLanguages.count == 1 { return usualLanguages[0] }
        return nil
    }

    /// Whether finished lines only should be shown for this language.
    func steady(for language: String?) -> Bool {
        switch subtitleStyle {
        case .live: false
        case .steady: true
        // Apple's engine finishes lines late but guesses early: keep its live guesses.
        case .automatic: engine == .apple ? false : (language.map(SubtitleStyle.verbFinal.contains) ?? false)
        }
    }

    static func appleLocale(for code: String) -> String? {
        let map = ["ja": "ja-JP", "ko": "ko-KR", "es": "es-ES", "fr": "fr-FR", "de": "de-DE", "it": "it-IT",
                   "pt": "pt-BR", "zh": "zh-CN", "yue": "yue-CN", "en": "en-US"]
        return map[code]
    }

    /// Whether to use the in-process ScreenCaptureKit path.
    var useScreenCaptureKit: Bool {
        if #available(iOS 27.0, *) { return captureMethod == .automatic }
        return false
    }
}

enum Quality: String, CaseIterable, Identifiable {
    case fastest, balanced, accurate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fastest: "Fastest"
        case .balanced: "Balanced"
        case .accurate: "Most accurate"
        }
    }
    var detail: String {
        switch self {
        case .fastest: "First words appear soonest and it uses the least battery. Needs one language chosen; finished lines can lag."
        case .balanced: "Good accuracy with about a second of delay. Detects the language by itself."
        case .accurate: "Best for Japanese and Korean: gets “not” and the tense right. About a second more delay and more battery."
        }
    }
}

enum SubtitleStyle: String, CaseIterable, Identifiable {
    case automatic, live, steady
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .live: "Live"
        case .steady: "Steady"
        }
    }
    var detail: String {
        switch self {
        case .automatic: "Steady for Japanese and Korean, Live for everything else (always Live with Fastest)."
        case .live: "Shows a white first guess while people speak, then the yellow final line."
        case .steady: "Shows only finished yellow lines. About a second later, but nothing changes on screen."
        }
    }
    /// Languages that put the verb (and negation, tense) at the end of the sentence,
    /// so live guesses change most.
    static let verbFinal: Set<String> = ["ja", "ko", "tr", "hi"]
}

/// Languages Whisper can auto-detect. Shown as "force language" choices.
enum WhisperLanguages {
    static let codes: [String] = [
        "af","am","ar","as","az","ba","be","bg","bn","bo","br","bs","ca","cs","cy","da","de","el","en","es","et","eu",
        "fa","fi","fo","fr","gl","gu","ha","haw","he","hi","hr","ht","hu","hy","id","is","it","ja","jw","ka","kk","km",
        "kn","ko","la","lb","ln","lo","lt","lv","mg","mi","mk","ml","mn","mr","ms","mt","my","ne","nl","nn","no","oc",
        "pa","pl","ps","pt","ro","ru","sa","sd","si","sk","sl","sn","so","sq","sr","su","sv","sw","ta","te","tg","th",
        "tk","tl","tr","tt","uk","ur","uz","vi","yi","yo","yue","zh",
    ]

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    static var sortedByName: [String] { codes.sorted { name($0) < name($1) } }
}
