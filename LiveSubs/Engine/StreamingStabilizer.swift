import Foundation

/// Turns a growing, re-recognised sentence into stable subtitles, the way live-caption
/// systems do it (whisper_streaming's LocalAgreement-2; Google Translate's re-translation
/// with a masked tail):
///
/// 1. Source side: text two passes agree on is settled. When a settled stretch ends at a
///    clause boundary (、。，,!?…), that clause is committed at once as its own yellow
///    line instead of waiting for the end of the sentence.
/// 2. English side: the unsettled rest is re-translated on every pass, but its last
///    `maskWords` words stay hidden until two passes agree on them, so the white guess
///    grows instead of flickering.
struct StreamingStabilizer {
    var maskWords = 2
    /// Shortest clause worth its own line, in characters.
    var minClause = 6

    /// Source text of the current sentence already committed as clause lines.
    private(set) var committedSource = ""
    private var previousRemainder = ""
    private var previousEnglish: [Substring] = []

    static let clauseMarks: Set<Character> = ["、", "。", "，", ",", "！", "？", "!", "?", ".", "；", ";", "…"]

    mutating func reset() {
        committedSource = ""; previousRemainder = ""; previousEnglish = []; clauseCount = 0
    }

    /// The part of `source` not yet committed. nil if the recogniser has rewritten
    /// what was already committed (then the caller keeps waiting for the final).
    func remainder(of source: String) -> String? {
        if committedSource.isEmpty { return source }
        if source.hasPrefix(committedSource) { return String(source.dropFirst(committedSource.count)) }
        // Small rewrites (punctuation, spacing) still count as the same prefix.
        let lcp = Self.commonPrefixLength(Array(source), Array(committedSource))
        guard Double(lcp) >= Double(committedSource.count) * 0.8 else { return nil }
        return String(source.dropFirst(min(source.count, committedSource.count)))
    }

    /// A clause both of the last two passes agree on, ready to show as a final line.
    mutating func takeSettledClause(from source: String) -> String? {
        guard let rest = remainder(of: source) else { return nil }
        defer { previousRemainder = rest }
        let agreed = Array(rest).prefix(Self.commonPrefixLength(Array(rest), Array(previousRemainder)))
        guard let cut = agreed.lastIndex(where: { Self.clauseMarks.contains($0) }) else { return nil }
        let clause = String(agreed[...cut]).trimmingCharacters(in: .whitespaces)
        guard clause.count >= minClause else { return nil }
        committedSource += String(agreed[...cut])
        previousRemainder = String(rest.dropFirst(cut + 1))
        previousEnglish = []
        return clause
    }

    /// The English guess to show: words two passes agree on, plus everything except the
    /// last `maskWords` words of the newest pass.
    mutating func visibleGuess(_ english: String) -> String {
        let words = english.split(separator: " ")
        let agreed = Self.commonPrefixLength(words, previousEnglish)
        previousEnglish = words
        let show = max(agreed, words.count - maskWords)
        return words.prefix(max(0, show)).joined(separator: " ")
    }

    /// For the final pass: what is left to translate, and whether the committed clauses
    /// no longer match (then the caller should replace them with the whole sentence).
    mutating func finish(_ source: String) -> (text: String, replacesClauses: Int)? {
        defer { reset() }
        guard !committedSource.isEmpty else { return (source, 0) }
        if let rest = remainder(of: source) {
            return (rest.trimmingCharacters(in: .whitespaces), 0)
        }
        return (source, clauseCount)
    }

    /// Clause lines committed for the current sentence.
    private(set) var clauseCount = 0
    mutating func noteClauseCommitted() { clauseCount += 1 }

    static func commonPrefixLength<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return i
    }
}
