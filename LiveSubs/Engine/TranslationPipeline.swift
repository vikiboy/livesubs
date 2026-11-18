import Foundation

/// What the subtitle surfaces render.
struct SubtitleUpdate: Equatable, Sendable {
    /// Finished English lines, oldest first (the UI shows the last one or two).
    var committed: [String] = []
    /// English for the sentence currently being spoken; may still change.
    var tentative: String = ""
    /// BCP-47 code of the detected/selected spoken language, e.g. "es".
    var sourceLanguage: String?
    /// Short status for the user ("Listening…", "Loading model…").
    var status: String?
    /// The newest line as it was spoken (e.g. Japanese), when the engine transcribed
    /// before translating. Empty when Whisper translated directly.
    var original: String = ""
}

/// Audio in → English subtitles out. Implementations own their threading.
protocol TranslationPipeline: AnyObject {
    var onUpdate: (@Sendable (SubtitleUpdate) -> Void)? { get set }
    func start() async throws
    /// 16 kHz mono Float32. Called from a background queue.
    func append(_ samples: [Float])
    func stop() async
}

enum EngineKind: String, CaseIterable, Identifiable, Codable {
    /// Whisper (via WhisperKit): auto-detects ~99 languages, translates on-device.
    case whisper
    /// Apple SpeechAnalyzer + Translation: very fast and power-efficient,
    /// but you pick the spoken language and fewer languages are supported.
    case apple

    var id: String { rawValue }
    var title: String {
        switch self {
        case .whisper: "Whisper: detects the language"
        case .apple: "Apple: fastest, you pick the language"
        }
    }
}

/// Removes the classic Whisper hallucinations on music/silence.
enum HallucinationFilter {
    private static let blocked: [String] = [
        "thank you for watching", "thanks for watching", "please subscribe", "subscribe to",
        "like and subscribe", "subtitles by", "amara.org", "transcribed by", "captioned by",
        "see you next time", "see you in the next video", "translated by", "copyright",
        // Whisper's silence habits in Japanese and Korean ("thanks for watching", "subtitles by…").
        "ご視聴ありがとうございました", "チャンネル登録", "字幕作成", "字幕は", "最後までご視聴",
        "시청해 주셔서 감사합니다", "시청해주셔서 감사합니다", "구독과 좋아요", "자막 제공",
    ]
    /// Lines that are only these words are dropped (Whisper says them over music or silence).
    private static let aloneOnly: Set<String> = ["はい", "ありがとうございました", "ありがとうございます", "うん", "えー",
                                                 "네", "감사합니다", "고맙습니다", "음"]

    static func clean(_ raw: String) -> String {
        // Strip Whisper special tokens / bracketed sound tags like [Music] (♪).
        var text = raw.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|♪+|♫+"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if blocked.contains(where: { lower.contains($0) }) { return "" }
        if lower.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).isEmpty { return "" }
        if [ "you", "thank you", "thank you.", "bye", "bye.", "okay.", "so" ].contains(lower) { return "" }
        if aloneOnly.contains(lower.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces).union(CharacterSet(charactersIn: "。、！？")))) { return "" }
        return collapseRepeats(text)
    }

    /// "I don't know. I don't know. I don't know." → "I don't know."
    private static func collapseRepeats(_ s: String) -> String {
        let words = s.split(separator: " ")
        guard words.count >= 6 else { return s }
        for n in 1...min(8, words.count / 3) {
            let unit = words.suffix(n)
            var reps = 0
            var i = words.count
            while i - n >= 0, Array(words[(i - n)..<i]) == Array(unit) { reps += 1; i -= n }
            if reps >= 3 { return (words[..<i] + unit).joined(separator: " ") }
        }
        return s
    }
}
