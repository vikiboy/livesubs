import Accelerate
import Foundation

/// Turns a continuous 16 kHz stream into speech segments for chunked Whisper inference.
///
/// - Energy-based VAD with an adaptive noise floor (cheap, no model).
/// - While someone is speaking, emits `.partial` snapshots of the growing segment
///   so subtitles appear before the sentence ends.
/// - Emits `.final` at a pause, or when the segment hits `maxSegment`, cutting at
///   the quietest point near the end so words aren't chopped in half.
final class SpeechSegmenter {
    enum Event {
        case partial([Float])
        case final([Float])
    }

    struct Config {
        var frame = 480                    // 30 ms
        var minSpeech: Double = 0.6        // s of speech before the first partial
        var partialInterval: Double = 1.0  // s of new audio between partials
        var endSilence: Double = 0.55      // s of silence that ends a segment
        var maxSegment: Double = 9.0       // s, hard cap (Whisper's window is 30 s)
        var preRoll: Double = 0.25         // s kept before speech onset
    }

    var config = Config()
    private let rate = Shared.sampleRate

    private var pending: [Float] = []          // not yet framed
    private var segment: [Float] = []
    private var frameEnergies: [Float] = []    // per frame, aligned with `segment`
    private var preRoll: [Float] = []
    private var inSpeech = false
    private var silenceFrames = 0
    private var speechFrames = 0
    private var lastPartialAt = 0
    private var noiseFloor: Float = 0.003

    func reset() {
        pending.removeAll(); segment.removeAll(); frameEnergies.removeAll(); preRoll.removeAll()
        inSpeech = false; silenceFrames = 0; speechFrames = 0; lastPartialAt = 0
    }

    /// Feed audio; returns zero or more events in order.
    func append(_ samples: [Float]) -> [Event] {
        pending.append(contentsOf: samples)
        var events: [Event] = []
        let f = config.frame
        var offset = 0
        while pending.count - offset >= f {
            let frame = Array(pending[offset..<(offset + f)])
            offset += f
            if let e = process(frame) { events.append(contentsOf: e) }
        }
        pending.removeFirst(offset)
        return events
    }

    /// Flush whatever speech is buffered (e.g. on stop).
    func flush() -> Event? {
        defer { reset() }
        return segment.count > Int(rate * 0.4) ? .final(segment) : nil
    }

    private func process(_ frame: [Float]) -> [Event]? {
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
        let threshold = max(0.006, noiseFloor * 3.2)
        let voiced = rms > threshold

        if !voiced {
            // Track the noise floor slowly during non-speech.
            noiseFloor = noiseFloor * 0.97 + rms * 0.03
        }

        if !inSpeech {
            preRoll.append(contentsOf: frame)
            let keep = Int(config.preRoll * rate)
            if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
            guard voiced else { return nil }
            inSpeech = true
            segment = preRoll
            frameEnergies = Array(repeating: 0, count: preRoll.count / config.frame)
            preRoll.removeAll()
            silenceFrames = 0
            speechFrames = 0
            lastPartialAt = 0
        }

        segment.append(contentsOf: frame)
        frameEnergies.append(rms)
        if voiced { speechFrames += 1; silenceFrames = 0 } else { silenceFrames += 1 }

        let frameDur = Double(config.frame) / rate
        var events: [Event] = []

        if Double(silenceFrames) * frameDur >= config.endSilence {
            // End of utterance. Ignore blips that were almost all silence.
            if Double(speechFrames) * frameDur >= 0.3 {
                let trimmed = Array(segment.dropLast(max(0, (silenceFrames - 6)) * config.frame))
                events.append(.final(trimmed))
            }
            inSpeech = false
            segment.removeAll(); frameEnergies.removeAll()
            return events
        }

        if Double(segment.count) / rate >= config.maxSegment {
            // Cut at the quietest frame within the last 2 s, carry the rest forward.
            let window = min(frameEnergies.count - 1, Int(2.0 / frameDur))
            let start = frameEnergies.count - window
            var cutFrame = frameEnergies.count
            var best = Float.greatestFiniteMagnitude
            for i in start..<frameEnergies.count where frameEnergies[i] < best {
                best = frameEnergies[i]; cutFrame = i
            }
            let cut = cutFrame * config.frame
            events.append(.final(Array(segment[..<cut])))
            segment = Array(segment[cut...])
            frameEnergies = Array(frameEnergies[cutFrame...])
            lastPartialAt = 0
            speechFrames = frameEnergies.count
            return events
        }

        let dur = Double(segment.count) / rate
        if Double(speechFrames) * frameDur >= config.minSpeech,
           Double(segment.count - lastPartialAt) / rate >= config.partialInterval || lastPartialAt == 0 {
            lastPartialAt = segment.count
            _ = dur
            events.append(.partial(segment))
        }
        return events
    }
}
