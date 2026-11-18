import ActivityKit
import Foundation

// Shared by the app (starts/updates the activity) and LiveSubsControls (draws it).

/// Live subtitles in the Dynamic Island and on the Lock Screen.
struct SubtitleActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Newest English line (finished, or the live guess).
        var line: String
        /// The same line as spoken, when known (e.g. Japanese). May be empty.
        var original: String
        /// "Japanese → English", or a short status.
        var label: String
        /// true while the line is still a guess (drawn white, not yellow).
        var isGuess: Bool
    }
}

/// The last few words of a line, for the narrow compact island.
enum IslandText {
    static func tail(_ line: String, maxChars: Int = 18) -> String {
        guard line.count > maxChars else { return line }
        var words = line.split(separator: " ")
        var out = ""
        while let w = words.popLast() {
            let next = out.isEmpty ? String(w) : "\(w) \(out)"
            if next.count > maxChars { break }
            out = next
        }
        // Scripts without spaces: keep the last characters.
        return out.isEmpty ? String(line.suffix(maxChars)) : out
    }
}
