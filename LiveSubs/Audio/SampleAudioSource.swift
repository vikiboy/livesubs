import AVFoundation

/// Practice clip: plays a bundled recording out loud and feeds the same audio to the
/// pipeline in real time, so you can see subtitles working without another app.
final class SampleAudioSource: AudioSource {
    var onSamples: (([Float]) -> Void)?
    /// Called on the main queue when the clip has finished.
    var onFinished: (() -> Void)?

    let language: String
    /// Seconds from the start of the clip at which each sentence ends (energy gate),
    /// so the session can measure the real delay on this iPhone.
    private(set) var speechEnds: [TimeInterval] = []
    private var player: AVAudioPlayer?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "livesubs.sample", qos: .userInitiated)

    init(language: String) { self.language = language }

    static func url(for language: String) -> URL? {
        Bundle.main.url(forResource: "sample-\(language)", withExtension: "m4a")
    }

    static let languages = ["ja", "ko", "es"]

    func start() async throws {
        guard let url = Self.url(for: language) else { throw CaptureError.sampleMissing }
        let samples = try Self.decode(url)
        speechEnds = Self.sentenceEnds(samples)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        let player = try AVAudioPlayer(contentsOf: url)
        player.play()
        self.player = player

        // 100 ms chunks on the clock, like the capture paths deliver them.
        let chunk = Int(Shared.sampleRate / 10)
        var index = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if index < samples.count {
                let end = min(index + chunk, samples.count)
                self.onSamples?(Array(samples[index..<end]))
                index = end
            } else if index < samples.count + chunk * 15 {
                // 1.5 s of trailing silence so the last sentence is finished.
                self.onSamples?([Float](repeating: 0, count: chunk))
                index += chunk
            } else {
                self.timer?.cancel()
                DispatchQueue.main.async { self.onFinished?() }
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel(); timer = nil
        player?.stop(); player = nil
    }

    private static func sentenceEnds(_ samples: [Float]) -> [TimeInterval] {
        let hop = Int(Shared.sampleRate * 0.05)
        var ends: [TimeInterval] = []
        var inSpeech = false, quiet = 0.0, lastLoud = 0.0, i = 0
        while i + hop <= samples.count {
            var sum: Float = 0
            for k in i..<(i + hop) { sum += samples[k] * samples[k] }
            let t = Double(i) / Shared.sampleRate
            if sqrt(sum / Float(hop)) > 0.01 { inSpeech = true; lastLoud = t + 0.05; quiet = 0 }
            else if inSpeech { quiet += 0.05; if quiet >= 0.4 { ends.append(lastLoud); inSpeech = false } }
            i += hop
        }
        if inSpeech { ends.append(lastLoud) }
        return ends
    }

    /// File → 16 kHz mono Float32.
    static func decode(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Shared.sampleRate, channels: 1, interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: input)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return [] }
        let cap = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
