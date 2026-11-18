// Translates stdin lines <lang>\t<text> to English with Apple's on-device Translation,
// printing the English and the time each took. Built with swiftc (see bench.sh): the
// SwiftPM-built Bench binary gets "notInstalled" from Translation on macOS for reasons
// outside LiveSubs' code, so the bench measures this step separately.
import Foundation
import Translation

var sessions: [String: TranslationSession] = [:]
while let line = readLine() {
    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { continue }
    let lang = parts[0], text = parts[1]
    let s = sessions[lang] ?? TranslationSession(installedSource: Locale.Language(identifier: lang), target: Locale.Language(identifier: "en"))
    sessions[lang] = s
    let t0 = Date()
    do {
        let r = try await s.translate(text)
        if CommandLine.arguments.contains("--raw") { print(r.targetText.replacingOccurrences(of: "\n", with: " ")) }
        else { print(String(format: "  %4.0f ms  %@", Date().timeIntervalSince(t0) * 1000, r.targetText)) }
    } catch { print(CommandLine.arguments.contains("--raw") ? "" : "  ERR \(error)") }
    fflush(stdout)
}
