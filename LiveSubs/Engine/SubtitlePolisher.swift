import Foundation
import FoundationModels

/// Turns a literal translation into the natural, conversational English a professional
/// subtitler would write, with Apple's on-device language model (Apple Intelligence).
/// Nothing leaves the iPhone. One line at a time, with the previous lines as context only,
/// and a meaning check: if the rewrite loses or adds a negation, or balloons, the literal
/// line is kept.
actor SubtitlePolisher {
    static let instructions = """
    You write English subtitles for films and shows. For the CURRENT line you get the original words and a stiff \
    literal translation; write what a native English speaker would naturally say in that moment, as a professional \
    subtitler would. Earlier lines are context only: never repeat or mix in their words.
    Rules:
    - Meaning first: keep who does what to whom, every negation, number and name. If unsure, stay close to the literal line.
    - Same attitude: casual stays casual, angry stays angry, polite stays polite. Never add facts.
    - Contractions and everyday phrasing; drop filler and repetitions.
    - Short: at most about 80 characters.
    Examples:
    "Even so, do not eat other people's things without permission." → "That doesn't mean you can eat my stuff!"
    "It cannot be helped." → "Oh well, what can you do."
    "Is that so? I did not know." → "Really? I had no idea."
    """

    @Generable struct Subtitle {
        @Guide(description: "The natural English subtitle for the CURRENT line only.")
        var text: String
    }

    /// Why natural English isn't available, if it isn't (shown in Settings).
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to use this."
        case .unavailable(.deviceNotEligible): return "This iPhone doesn't support Apple Intelligence."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading. Try again later."
        case .unavailable: return "Apple Intelligence isn't available right now."
        }
    }

    static var isAvailable: Bool { unavailableReason == nil }

    func polish(original: String, literal: String, context: [String]) async -> String {
        guard Self.isAvailable, !literal.isEmpty else { return literal }
        let session = LanguageModelSession(instructions: Self.instructions)
        var prompt = ""
        if !context.isEmpty { prompt += "Earlier lines (context): " + context.suffix(3).joined(separator: " / ") + "\n" }
        if !original.isEmpty { prompt += "CURRENT original: \(original)\n" }
        prompt += "CURRENT literal: \(literal)"
        do {
            let r = try await session.respond(to: prompt, generating: Subtitle.self, options: GenerationOptions(samplingMode: .greedy))
            return Self.checked(r.content.text, literal: literal)
        } catch {
            return literal   // guardrails, busy model, etc.: the literal line is still right
        }
    }

    /// Keeps the literal line when the rewrite is empty, much longer, or flips a negation.
    static func checked(_ out: String, literal: String) -> String {
        let o = out.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        guard !o.isEmpty, o.count <= max(90, literal.count * 2) else { return literal }
        if hasNegation(literal) != hasNegation(o) { return literal }
        return o
    }

    private static func hasNegation(_ s: String) -> Bool {
        let l = s.lowercased()
        if l.contains("n't") || l.contains("n’t") { return true }
        let words = Set(l.components(separatedBy: CharacterSet.letters.inverted))
        return !words.isDisjoint(with: ["not", "no", "never", "nobody", "nothing", "none", "nowhere", "neither", "nor"])
    }
}
