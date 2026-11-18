import AVFoundation
import CoreMedia
import Foundation

// Usage: Harness <model-variant> <16k-mono-f32.wav> [forcedLang]
// Exercises: AudioRingBuffer, AppAudioConverter (big-endian Int16 stereo 48k),
// SpeechSegmenter + WhisperPipeline (download → prepare → streaming translate).

func check(_ cond: Bool, _ msg: String) {
    print(cond ? "PASS  \(msg)" : "FAIL  \(msg)")
    if !cond { failures += 1 }
}
var failures = 0

// 1. Ring buffer round trip incl. wrap-around and overflow.
do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ring-\(UUID()).bin")
    let w = AudioRingBuffer(url: url, capacity: 1000)!
    let r = AudioRingBuffer(url: url, capacity: 1000)! // separate mapping, like the other process
    w.beginSession()
    var idx: UInt64 = 0
    let a = (0..<700).map { Float($0) }
    a.withUnsafeBufferPointer { w.write($0) }
    let got1 = r.read(from: &idx)
    check(got1 == a, "ring: first read returns written samples")
    let b = (700..<1500).map { Float($0) } // wraps
    b.withUnsafeBufferPointer { w.write($0) }
    let got2 = r.read(from: &idx)
    check(got2 == b, "ring: wrap-around read is contiguous and ordered")
    let c = (0..<2500).map { Float($0) } // overflow → newest 1000 kept
    c.withUnsafeBufferPointer { w.write($0) }
    let got3 = r.read(from: &idx)
    check(got3 == Array(c.suffix(1000)), "ring: overflow keeps newest audio")
    try? FileManager.default.removeItem(at: url)
}

// 2. Converter: 48 kHz stereo big-endian Int16 sine → 16 kHz mono float.
do {
    let frames = 4800
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
    var fmt: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
    var data = Data(count: frames * 4)
    data.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: Int16.self)
        for i in 0..<frames {
            let v = Int16(sin(Double(i) * 2 * .pi * 440 / 48_000) * 16_000)
            p[i * 2] = v.bigEndian; p[i * 2 + 1] = v.bigEndian
        }
    }
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
    data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: data.count) }
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt!, sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sb)
    let conv = AppAudioConverter()
    var out: [Float] = []
    for _ in 0..<3 { out += conv.convert(sb!) ?? [] }
    let peak = out.dropFirst(200).map(abs).max() ?? 0
    check(abs(out.count - 4800) < 200, "converter: 3×100 ms @48k → ~4800 samples @16k (got \(out.count))")
    check(peak > 0.4 && peak < 0.55, "converter: big-endian decoded with correct amplitude (peak \(String(format: "%.3f", peak)), expect ≈0.49)")
}

// 3. End-to-end Whisper pipeline.
let args = CommandLine.arguments
guard args.count >= 3, let model = WhisperModel.find(args[1]) else {
    print("usage: Harness <variant> <wav> [lang]"); exit(failures == 0 ? 0 : 1)
}
let wavURL = URL(fileURLWithPath: args[2])
let forced = args.count > 3 ? args[3] : nil

do {
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
    check(ModelStore.localFolder(for: model) != nil, "model downloaded + prepared")

    let file = try! AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try! file.read(into: buf)
    let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    print("Audio: \(String(format: "%.1f", Double(samples.count) / 16_000)) s")
    do { // segmenter trace
        let seg = SpeechSegmenter(); var t = 0
        while t < samples.count { let e = min(t + 1600, samples.count)
            for ev in seg.append(Array(samples[t..<e])) {
                switch ev { case .partial(let a): print(String(format: "  seg @%.1fs partial %.1fs", Double(e)/16000, Double(a.count)/16000))
                case .final(let a): print(String(format: "  seg @%.1fs FINAL %.1fs", Double(e)/16000, Double(a.count)/16000)) } }
            t = e }
        for _ in 0..<10 { for ev in seg.append([Float](repeating: 0, count: 1600)) { if case .final(let a) = ev { print(String(format: "  seg tail FINAL %.1fs", Double(a.count)/16000)) } } }
    }

    let pipeline = WhisperPipeline(options: .init(model: model, forcedLanguage: forced, preferAppleTranslation: false))
    let t0 = Date()
    let lastCommitted = LockedBox<[String]>([])
    let firstTextAt = LockedBox<Double?>(nil)
    pipeline.onUpdate = { u in
        let t = Date().timeIntervalSince(t0)
        if firstTextAt.value == nil, !(u.tentative.isEmpty && u.committed.isEmpty) { firstTextAt.value = t }
        if u.committed != lastCommitted.value {
            print(String(format: "[%5.1fs] FINAL (%@): %@", t, u.sourceLanguage ?? "?", u.committed.last ?? ""))
            lastCommitted.value = u.committed
        } else if !u.tentative.isEmpty {
            print(String(format: "[%5.1fs]   ~ %@", t, u.tentative))
        } else if let s = u.status { print("[status] \(s)") }
    }
    try! await pipeline.start()
    let t0Audio = Date()
    // Real-time feed in 100 ms chunks, as the broadcast reader does.
    var i = 0
    while i < samples.count {
        let end = min(i + 1600, samples.count)
        pipeline.append(Array(samples[i..<end]))
        i = end
        try? await Task.sleep(for: .milliseconds(100))
    }
    // trailing silence so the last utterance finalises
    for _ in 0..<10 { pipeline.append([Float](repeating: 0, count: 1600)); try? await Task.sleep(for: .milliseconds(100)) }
    await pipeline.stop()
    print(String(format: "Wall time %.1fs for %.1fs of audio; first text after %.1fs",
                 Date().timeIntervalSince(t0Audio), Double(samples.count) / 16_000, firstTextAt.value ?? -1))
    check(!lastCommitted.value.isEmpty, "pipeline produced committed English subtitles")
    print("\nTranscript:\n" + lastCommitted.value.joined(separator: "\n"))
}
print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
