import AVFoundation
import Foundation
import WhisperKit

// Usage: Bench <arm> <wav> <lang>
//   arm: whisper:<variant>[:apple][:forced]  |  apple
// Streams the wav in real time (100 ms chunks) through the app's real pipeline and
// reports: first-text latency, per-sentence lag (speech end → yellow line), and the
// final English lines. Speech-end times come from a simple energy gate on the input.

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: Bench <arm> <wav> <lang>"); exit(2) }
let arm = args[1], wavURL = URL(fileURLWithPath: args[2]), lang = args[3]

let file = try! AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false)
let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try! file.read(into: buf)
let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
let sr = Shared.sampleRate

// Speech onsets / ends at 50 ms resolution: a gap of ≥ 0.4 s of quiet ends a sentence.
var onsets: [Double] = [], ends: [Double] = []
do {
    let hop = Int(sr * 0.05); var inSpeech = false; var quiet = 0.0; var lastLoud = 0.0
    var i = 0
    while i + hop <= samples.count {
        let rms = sqrt(samples[i..<i + hop].reduce(0) { $0 + $1 * $1 } / Float(hop))
        let t = Double(i) / sr
        if rms > 0.01 {
            if !inSpeech { onsets.append(t); inSpeech = true }
            lastLoud = t + 0.05; quiet = 0
        } else if inSpeech {
            quiet += 0.05
            if quiet >= 0.4 { ends.append(lastLoud); inSpeech = false }
        }
        i += hop
    }
    if inSpeech { ends.append(lastLoud) }
}

final class Box<T>: @unchecked Sendable {
    private let l = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } }
}

// Apple Translation through a helper process (the SwiftPM binary gets "notInstalled").
actor TranslateHelper {
    let proc = Process(); let inPipe = Pipe(); let outPipe = Pipe()
    var buffer = Data()
    init?(path: String) {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        proc.executableURL = URL(fileURLWithPath: path); proc.arguments = ["--raw"]
        proc.standardInput = inPipe; proc.standardOutput = outPipe
        try? proc.run()
    }
    func translate(_ lang: String, _ text: String) -> String? {
        let line = "\(lang)\t\(text.replacingOccurrences(of: "\n", with: " "))\n"
        inPipe.fileHandleForWriting.write(line.data(using: .utf8)!)
        while true {
            if let nl = buffer.firstIndex(of: 10) {
                let out = String(decoding: buffer[..<nl], as: UTF8.self)
                buffer.removeSubrange(...nl)
                return out.isEmpty ? nil : out
            }
            let chunk = outPipe.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}
let helperPath = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .appendingPathComponent("../translate-lines").standardized.path
if let helper = TranslateHelper(path: helperPath) {
    Translator.externalBackend = { lang, text in await helper.translate(lang, text) }
}

// Whole-file mode: "file:<variant>" transcribes everything at once (no streaming),
// then translates each segment — the ahead-of-time path.
if arm.hasPrefix("file:") {
    import_whole: do {
        let variant = String(arm.dropFirst(5))
        guard let model = WhisperModel.find(variant), let folder = ModelStore.localFolder(for: model) else { print("model missing"); exit(2) }
        let kit = try await WhisperKit(WhisperKitConfig(model: variant, downloadBase: ModelStore.baseURL, modelFolder: folder.path,
                                                        tokenizerFolder: ModelStore.baseURL, verbose: false, logLevel: .error,
                                                        prewarm: false, load: true, download: false))
        let t0 = Date()
        let opts = DecodingOptions(task: .transcribe, language: lang, temperature: 0, usePrefillPrompt: true,
                                   detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: false)
        let res = try await kit.transcribe(audioArray: samples, decodeOptions: opts)
        let asr = Date().timeIntervalSince(t0)
        let segs = res.flatMap(\.segments)
        let t1 = Date()
        var lines: [String] = []
        for seg in segs {
            let src = HallucinationFilter.clean(seg.text)
            guard !src.isEmpty else { continue }
            let en = await Translator(source: Locale.Language(identifier: lang)).translate(src)
            lines.append(String(format: "  [%5.1f–%5.1f] %@  ←  %@", seg.start, seg.end, en, src))
        }
        let tr = Date().timeIntervalSince(t1)
        let dur = Double(samples.count) / sr
        print(String(format: "RESULT arm=%@ lang=%@ audio=%.1fs recognise=%.2fs (%.1f× real time) translate=%.2fs total=%.2fs",
                     arm, lang, dur, asr, dur / asr, tr, asr + tr))
        lines.forEach { print($0) }
        exit(0)
    }
}

// "ahead:<variant>[:candidates]" runs the private browser's engine on the file, as if
// the page delivered it, and reports the language it settled on and the first lines.
// "ahead:<engine>:<lang>" runs the private browser's engine on the file as if a page delivered
// it (4 s pieces), with one engine: parakeet | apple | whisper-turbo. Prints the recognised
// lines (for CER), Apple's English, and how long the whole file took.
if arm.hasPrefix("ahead:") {
    let parts = arm.split(separator: ":").map(String.init)
    let recognizer: any SpeechRecognizer
    switch parts[1] {
    case "parakeet": recognizer = ParakeetRecognizer()
    case "apple": recognizer = AppleRecognizer()
    default: recognizer = WhisperRecognizer(model: WhisperModel.find("openai_whisper-large-v3-v20240930_626MB")!)
    }
    if parts[1] == "parakeet", !ParakeetRecognizer.isDownloaded { try await ParakeetRecognizer.download { _ in } }
    let engine = AheadTranscriber(config: .init(language: lang, candidates: [lang]), recognizers: [recognizer])
    let got = Box<[Cue]>([])
    await engine.setHandler { cues, _ in got.value = cues }
    try await engine.load()
    await engine.setPlayhead(0)
    let t0 = Date()
    var i = 0
    while i < samples.count {      // deliver as fast as a playlist reader would
        let end = min(i + Int(sr * 4), samples.count)
        await engine.addAudio(start: Double(i) / sr, samples: Array(samples[i..<end]))
        i = end
    }
    let total = Double(samples.count) / sr
    while await engine.status().done < total - 2, Date().timeIntervalSince(t0) < 1800 { try? await Task.sleep(for: .milliseconds(200)) }
    let wall = Date().timeIntervalSince(t0)
    print(String(format: "RESULT engine=%@ lang=%@ audio=%.0fs wall=%.1fs (%.1f× real time) lines=%d", parts[1], lang, total, wall, total / wall, got.value.count))
    for c in got.value { print("LINE\t\(String(format: "%.2f", c.start))\t\(c.original.isEmpty ? c.english : c.original)\t\(c.english)") }
    await engine.stop()
    exit(0)
}

// Build the pipeline.
let parts = arm.split(separator: ":").map(String.init)
var pipeline: TranslationPipeline
if parts[0] == "apple" {
    pipeline = ApplePipeline(sourceLocale: Locale(identifier: lang == "ja" ? "ja_JP" : lang == "ko" ? "ko_KR" : lang))
} else {
    guard let model = WhisperModel.find(parts[1]) else { print("unknown model"); exit(2) }
    if ModelStore.localFolder(for: model) == nil {
        print("Downloading \(model.variant)…")
        let mgr = await MainActor.run { ModelManager() }
        await mgr.download(model)
        while true {
            let ph = await mgr.phase(model)
            if ph == .ready { break }
            if case .failed(let e) = ph { print("download failed: \(e)"); exit(1) }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
    pipeline = WhisperPipeline(options: .init(model: model, forcedLanguage: parts.contains("forced") ? lang : nil,
                                              preferAppleTranslation: parts.contains("apple"),
                                              streaming: !parts.contains("nostream")))
}

let commits = Box<[(Double, String)]>([])
let shown = Box<[(Double, String)]>([])     // every change of visible English (guess or line)
let erased = Box(0)
let lastGuess = Box("")
let firstText = Box<Double?>(nil)
let partialCount = Box(0)
let detected = Box<String?>(nil)
let clock = Box(Date())
pipeline.onUpdate = { u in
    let t = Date().timeIntervalSince(clock.value)
    if let l = u.sourceLanguage { detected.value = l }
    if firstText.value == nil, !(u.tentative.isEmpty && u.committed.isEmpty) { firstText.value = t }
    if let last = u.committed.last, last != commits.value.last?.1 {
        commits.value.append((t, last)); shown.value.append((t, last)); lastGuess.value = ""
    } else if !u.tentative.isEmpty {
        partialCount.value += 1
        // Flicker: words of the previous guess that are no longer at its start.
        let old = lastGuess.value.split(separator: " "), new = u.tentative.split(separator: " ")
        erased.value += old.count - StreamingStabilizer.commonPrefixLength(old, new)
        lastGuess.value = u.tentative
        shown.value.append((t, u.tentative))
    }
}
try await pipeline.start()
clock.value = Date()
var i = 0
while i < samples.count {
    let end = min(i + 1600, samples.count)
    pipeline.append(Array(samples[i..<end])); i = end
    try? await Task.sleep(for: .milliseconds(100))
}
for _ in 0..<20 { pipeline.append([Float](repeating: 0, count: 1600)); try? await Task.sleep(for: .milliseconds(100)) }
await pipeline.stop()
try? await Task.sleep(for: .milliseconds(300))

// Per sentence (energy gate): first English after it starts, first yellow line after it
// starts, and the last yellow line after it ends.
var firstEnglish: [Double] = [], firstYellow: [Double] = [], endToFinal: [Double] = []
for (k, on) in onsets.enumerated() {
    let next = k + 1 < onsets.count ? onsets[k + 1] : .infinity
    let end = k < ends.count ? ends[k] : on
    if let f = shown.value.first(where: { $0.0 >= on && $0.0 < next + 2 }) { firstEnglish.append(f.0 - on) }
    let lines = commits.value.filter { $0.0 >= on && $0.0 < min(next + 1.5, end + 4) }
    if let f = lines.first { firstYellow.append(f.0 - on) }
    if let l = lines.last(where: { $0.0 >= end }) { endToFinal.append(l.0 - end) }
}
func avg(_ a: [Double]) -> Double { a.isEmpty ? -1 : a.reduce(0, +) / Double(a.count) }
print(String(format: "RESULT arm=%@ lang=%@ firstEnglish=%.2fs firstYellow=%.2fs endToLastYellow=%.2fs erasedWords=%d lines=%d",
             arm, lang, avg(firstEnglish), avg(firstYellow), avg(endToFinal), erased.value, commits.value.count))
for (t, s) in commits.value { print(String(format: "  [%5.1fs] %@", t, s)) }

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
