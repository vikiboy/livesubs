import AVFoundation
import CommonCrypto
import Foundation

/// For sites whose player hands iOS a playlist (`video.src = …m3u8`) instead of streaming
/// through the page: LiveSubs reads the same playlist, fetches the audio ahead of the
/// playhead with the page's own cookies and referrer, and decodes it in memory.
///
/// Handles master playlists (prefers an audio-only rendition, else the lightest variant),
/// AES-128 segments (the key is published in the playlist; this is not DRM), fMP4 and
/// MPEG-TS segments with AAC audio. SAMPLE-AES / FairPlay (real DRM) is refused.
actor HLSAudioReader {
    struct Segment { let url: URL; let start: Double; let duration: Double; let key: Key?; let sequence: Int }
    struct Key: Equatable { let url: URL; let iv: Data? }
    enum ReadError: Error, Equatable { case protected, unsupported(String), network }

    private let playlistURL: URL
    private let session: URLSession
    private var segments: [Segment] = []
    private var mapURL: URL?
    private var keys: [URL: Data] = [:]
    private var playhead: Double = 0
    private var running = false
    private var fmp4: FMP4AudioDecoder?
    private var decodedAny = false
    var totalDuration: Double { segments.last.map { $0.start + $0.duration } ?? 0 }
    private var ts: TSAudioDecoder?
    private var onAudio: (@Sendable (Double, [Float]) -> Void)?
    private var onError: (@Sendable (ReadError) -> Void)?
    /// Fetching is paced by transcription, not playback: LiveSubs says when about two
    /// minutes of audio are already waiting, and the reader pauses until they're used.
    private var paused = false
    private var fetched = Set<Int>()

    init(playlistURL: URL, referer: URL?, userAgent: String?, cookies: [HTTPCookie]) {
        self.playlistURL = playlistURL
        let config = URLSessionConfiguration.ephemeral          // memory only: no cache, no cookie jar on disk
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        var headers: [String: String] = [:]
        if let referer {
            headers["Referer"] = referer.absoluteString
            if let scheme = referer.scheme, let host = referer.host { headers["Origin"] = "\(scheme)://\(host)" }
        }
        if let userAgent { headers["User-Agent"] = userAgent }
        config.httpAdditionalHeaders = headers
        cookies.forEach { config.httpCookieStorage?.setCookie($0) }
        session = URLSession(configuration: config)
    }

    func start(onAudio: @escaping @Sendable (Double, [Float]) -> Void, onError: @escaping @Sendable (ReadError) -> Void) async {
        self.onAudio = onAudio; self.onError = onError
        running = true
        do {
            try await loadPlaylist(playlistURL)
        } catch let e as ReadError { onError(e); return } catch { onError(.network); return }
        await loop()
    }

    func stop() { running = false; session.invalidateAndCancel() }

    func setPaused(_ p: Bool) { paused = p }

    func setPlayhead(_ t: Double) { playhead = t }

    /// The whole video, in the order that matters: from the playhead to the end, then the start.
    private func nextSegment() -> Int? {
        let here = segments.lastIndex(where: { $0.start <= playhead + 0.01 }) ?? 0
        if let i = (here..<segments.count).first(where: { !fetched.contains($0) }) { return i }
        return (0..<here).first { !fetched.contains($0) }
    }

    // MARK: Playlist

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ReadError.network }
        return data
    }

    private func loadPlaylist(_ url: URL) async throws {
        let text = String(decoding: try await fetch(url), as: UTF8.self)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first?.hasPrefix("#EXTM3U") == true else { throw ReadError.unsupported("not a playlist") }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            // Master playlist: an audio-only rendition if offered, else the lightest variant
            // (its audio is the same, and it downloads the least).
            if let audio = lines.first(where: { $0.hasPrefix("#EXT-X-MEDIA") && $0.contains("TYPE=AUDIO") && $0.contains("URI=") }),
               let uri = Self.attribute("URI", in: audio), let next = URL(string: uri, relativeTo: url) {
                return try await loadPlaylist(next.absoluteURL)
            }
            var best: (Int, URL)?
            for (i, l) in lines.enumerated() where l.hasPrefix("#EXT-X-STREAM-INF") {
                let bw = Int(Self.attribute("BANDWIDTH", in: l) ?? "") ?? .max
                if let next = lines[(i + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                   let u = URL(string: next, relativeTo: url), best == nil || bw < best!.0 { best = (bw, u.absoluteURL) }
            }
            guard let best else { throw ReadError.unsupported("empty playlist") }
            return try await loadPlaylist(best.1)
        }

        var start = 0.0, duration = 0.0, sequence = 0, key: Key?
        var list: [Segment] = []
        for l in lines {
            if l.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { sequence = Int(l.dropFirst(22)) ?? 0 }
            else if l.hasPrefix("#EXT-X-KEY:") {
                let method = Self.attribute("METHOD", in: l) ?? "NONE"
                switch method {
                case "NONE": key = nil
                case "AES-128":
                    guard let uri = Self.attribute("URI", in: l), let u = URL(string: uri, relativeTo: url) else { throw ReadError.unsupported("key") }
                    key = Key(url: u.absoluteURL, iv: Self.attribute("IV", in: l).flatMap(Self.hexData))
                default: throw ReadError.protected      // SAMPLE-AES, FairPlay: real DRM
                }
            } else if l.hasPrefix("#EXT-X-MAP:"), let uri = Self.attribute("URI", in: l) {
                mapURL = URL(string: uri, relativeTo: url)?.absoluteURL
            } else if l.hasPrefix("#EXTINF:") {
                duration = Double(l.dropFirst(8).split(separator: ",").first ?? "") ?? 0
            } else if !l.isEmpty, !l.hasPrefix("#"), let u = URL(string: l, relativeTo: url) {
                list.append(Segment(url: u.absoluteURL, start: start, duration: duration, key: key, sequence: sequence))
                start += duration; sequence += 1
            }
        }
        guard !list.isEmpty else { throw ReadError.unsupported("no segments") }
        segments = list
    }

    // MARK: Fetching ahead

    private func loop() async {
        while running {
            guard !paused, let index = nextSegment() else {
                try? await Task.sleep(for: .milliseconds(500)); continue
            }
            fetched.insert(index)
            let seg = segments[index]
            do {
                var data = try await fetch(seg.url)
                if let key = seg.key { data = try await decrypt(data, key: key, sequence: seg.sequence) }
                try await decode(data, segment: seg)
            } catch let e as ReadError where e == .protected {
                onError?(e); running = false
            } catch {
                // A failed segment is skipped; later ones still get subtitles.
            }
        }
    }

    private func decrypt(_ data: Data, key: Key, sequence: Int) async throws -> Data {
        let k: Data
        if let cached = keys[key.url] { k = cached } else { k = try await fetch(key.url); keys[key.url] = k }
        guard k.count == 16 else { throw ReadError.unsupported("key size") }
        var iv = key.iv ?? Data(count: 16)
        if key.iv == nil { var s = UInt64(sequence).bigEndian; iv.replaceSubrange(8..<16, with: Data(bytes: &s, count: 8)) }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in data.withUnsafeBytes { d in k.withUnsafeBytes { kb in iv.withUnsafeBytes { ib in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    kb.baseAddress, 16, ib.baseAddress, d.baseAddress, data.count, o.baseAddress, outCount, &moved)
        } } } }
        guard status == kCCSuccess else { throw ReadError.unsupported("decrypt") }
        return out.prefix(moved)
    }

    private func decode(_ data: Data, segment: Segment) async throws {
        let isTS = data.first == 0x47
        if isTS {
            let dec = ts ?? TSAudioDecoder(); ts = dec
            let samples = try dec.decode(data, continuous: segment.sequence == (dec.lastSequence ?? -2) + 1)
            if !samples.isEmpty { decodedAny = true }
            dec.lastSequence = segment.sequence
            if !samples.isEmpty { onAudio?(segment.start, samples) }
        } else {
            if fmp4 == nil {
                let dec = FMP4AudioDecoder()
                if let mapURL { _ = try dec.append(try await fetch(mapURL)) }
                fmp4 = dec
            }
            // fMP4 fragments carry their own times; the playlist position is the fallback.
            for run in try fmp4!.append(data) { onAudio?(run.start > 0 || segment.start == 0 ? run.start : segment.start, run.samples) }
        }
    }

    // MARK: Helpers

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let r = line.range(of: name + "=") else { return nil }
        let rest = line[r.upperBound...]
        if rest.hasPrefix("\"") { return rest.dropFirst().split(separator: "\"", maxSplits: 1).first.map(String.init) }
        return rest.split(separator: ",", maxSplits: 1).first.map(String.init)
    }

    private static func hexData(_ s: String) -> Data? {
        let hex = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
        guard hex.count == 32 else { return nil }
        var d = Data(); var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }; d.append(b); i = j }
        return d
    }
}

/// MPEG-TS → AAC (ADTS) → 16 kHz mono, in memory.
final class TSAudioDecoder {
    var lastSequence: Int?
    private var pmtPID: Int?
    private var audioPID: Int?
    private var aac: AACFrameDecoder?

    func decode(_ data: Data, continuous: Bool) throws -> [Float] {
        if !continuous { aac?.reset() }
        let b = [UInt8](data)
        var es: [UInt8] = []
        var i = 0
        while i + 188 <= b.count {
            defer { i += 188 }
            guard b[i] == 0x47 else { continue }
            let pusi = b[i + 1] & 0x40 != 0
            let pid = Int(b[i + 1] & 0x1F) << 8 | Int(b[i + 2])
            let afc = (b[i + 3] >> 4) & 0x3
            var p = i + 4
            if afc == 2 || afc == 3 { p += 1 + Int(b[p]) }
            guard afc != 2, p < i + 188 else { continue }
            if pid == 0, pusi {                                  // PAT
                let s = p + 1 + Int(b[p])
                if s + 12 <= i + 188 { pmtPID = Int(b[s + 10] & 0x1F) << 8 | Int(b[s + 11]) }
            } else if pid == pmtPID, pusi, audioPID == nil {     // PMT
                let s = p + 1 + Int(b[p])
                let sectionLength = Int(b[s + 1] & 0x0F) << 8 | Int(b[s + 2])
                let infoLength = Int(b[s + 10] & 0x0F) << 8 | Int(b[s + 11])
                var e = s + 12 + infoLength
                let end = min(s + 3 + sectionLength - 4, i + 188)
                while e + 5 <= end {
                    let type = b[e], epid = Int(b[e + 1] & 0x1F) << 8 | Int(b[e + 2])
                    let esInfo = Int(b[e + 3] & 0x0F) << 8 | Int(b[e + 4])
                    if type == 0x0F { audioPID = epid; break }   // AAC in ADTS
                    e += 5 + esInfo
                }
            } else if pid == audioPID {
                if pusi, p + 9 <= i + 188, b[p] == 0, b[p + 1] == 0, b[p + 2] == 1 {
                    p += 9 + Int(b[p + 8])                        // skip the PES header
                }
                if p < i + 188 { es.append(contentsOf: b[p..<(i + 188)]) }
            }
        }
        // ADTS frames.
        var frames: [Data] = []
        var j = 0
        while j + 7 <= es.count {
            guard es[j] == 0xFF, es[j + 1] & 0xF0 == 0xF0 else { j += 1; continue }
            let protectionAbsent = es[j + 1] & 0x01
            let profile = Int(es[j + 2] >> 6)
            let sfi = Int((es[j + 2] >> 2) & 0x0F)
            let channels = Int((es[j + 2] & 0x01) << 2 | es[j + 3] >> 6)
            let length = Int(es[j + 3] & 0x03) << 11 | Int(es[j + 4]) << 3 | Int(es[j + 5] >> 5)
            let header = protectionAbsent == 1 ? 7 : 9
            guard length > header, j + length <= es.count else { break }
            if aac == nil {
                let asc = UInt16(profile + 1) << 11 | UInt16(sfi) << 7 | UInt16(channels) << 3
                aac = try AACFrameDecoder(config: Data([UInt8(asc >> 8), UInt8(asc & 0xFF)]))
            }
            frames.append(Data(es[(j + header)..<(j + length)]))
            j += length
        }
        guard let aac, !frames.isEmpty else {
            if audioPID == nil, pmtPID != nil { throw HLSAudioReader.ReadError.unsupported("audio codec") }
            return []
        }
        return try aac.decode(frames)
    }
}

/// Raw AAC frames + AudioSpecificConfig → 16 kHz mono Float32.
final class AACFrameDecoder {
    private let decoder: AVAudioConverter
    private let resampler: AVAudioConverter
    private let aacFormat: AVAudioFormat
    private let pcmFormat: AVAudioFormat
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Shared.sampleRate, channels: 1, interleaved: false)!

    init(config: Data) throws {
        let bits = UInt16(config[0]) << 8 | UInt16(config[1])
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let idx = Int((bits >> 7) & 0xF)
        let rate = idx < rates.count ? rates[idx] : 44100
        let ch = max(1, AVAudioChannelCount((bits >> 3) & 0xF))
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                               mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: ch, mBitsPerChannel: 0, mReserved: 0)
        guard let aac = AVAudioFormat(streamDescription: &asbd),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: ch, interleaved: false),
              let dec = AVAudioConverter(from: aac, to: pcm), let res = AVAudioConverter(from: pcm, to: target)
        else { throw FMP4AudioDecoder.DecodeError.converter }
        dec.magicCookie = config
        decoder = dec; resampler = res; aacFormat = aac; pcmFormat = pcm
    }

    func reset() { decoder.reset(); resampler.reset() }

    func decode(_ frames: [Data]) throws -> [Float] {
        let maxSize = frames.map(\.count).max() ?? 2048
        let packets = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: AVAudioPacketCount(frames.count), maximumPacketSize: maxSize)
        var offset = 0
        for (i, f) in frames.enumerated() {
            f.withUnsafeBytes { packets.data.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: f.count) }
            packets.packetDescriptions![i] = AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(f.count))
            offset += f.count
        }
        packets.packetCount = AVAudioPacketCount(frames.count); packets.byteLength = UInt32(offset)
        return try FMP4AudioDecoder.drain(decoder, packets: packets, pcmFormat: pcmFormat, resampler: resampler, target: target)
    }
}
