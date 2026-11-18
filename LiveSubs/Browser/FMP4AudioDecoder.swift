import AVFoundation
import Foundation

/// Decodes the audio a web page's player appends through Media Source Extensions:
/// fragmented MP4 (init segment, then moof+mdat fragments) with AAC audio.
///
/// AVAssetReader stops after the first fragment and ignores fragment times, so this
/// parses the boxes itself: the AAC config from `esds`, each fragment's start time from
/// `tfdt`, frame sizes from `trun`. Frames are decoded with AVAudioConverter, entirely
/// in memory (nothing is written to disk), and returned as 16 kHz mono with media time.
final class FMP4AudioDecoder {
    struct Decoded {
        /// Media time (seconds) of the first sample.
        let start: Double
        let samples: [Float]
    }

    enum DecodeError: Error { case unsupportedCodec(String), noAudioTrack, converter }

    private var audioTrackID: UInt32?
    private var timescale: Double = 48_000
    private var defaultDuration: UInt32 = 1024
    private var defaultSize: UInt32 = 0
    private var aacConfig: Data?
    private var sampleRate: Double = 48_000
    private var channels: AVAudioChannelCount = 2
    private var decoder: AVAudioConverter?
    private var resampler: AVAudioConverter?
    private var aacFormat: AVAudioFormat?
    private var pcmFormat: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Shared.sampleRate, channels: 1, interleaved: false)!
    private var pending = Data()
    private var lastEnd: Double?

    var isReady: Bool { aacConfig != nil }

    /// Feed bytes exactly as the page appended them (any split). Returns decoded runs.
    func append(_ data: Data) throws -> [Decoded] {
        pending.append(data)
        var out: [Decoded] = []
        // Consume whole top-level boxes; a moof is processed together with its mdat.
        while let (type, size) = Self.box(at: 0, in: pending), size <= pending.count {
            switch type {
            case "ftyp", "styp", "sidx", "free", "prft", "emsg":
                pending.removeFirst(size)
            case "moov":
                try parseInit(pending.prefix(size))
                pending.removeFirst(size)
            case "moof":
                guard let (next, nsize) = Self.box(at: size, in: pending) else { return out }
                guard next == "mdat" else { pending.removeFirst(size); continue }
                guard size + nsize <= pending.count else { return out }
                let fragment = pending.prefix(size + nsize)
                pending.removeFirst(size + nsize)
                if let d = try decodeFragment(Data(fragment), moofSize: size) { out.append(d) }
            default:
                pending.removeFirst(size)
            }
        }
        return out
    }

    // MARK: Init segment

    private func parseInit(_ moov: Data) throws {
        let moov = Data(moov)
        var found = false
        for trak in Self.children(of: moov, at: 8, end: moov.count) where trak.type == "trak" {
            let t = trak.range
            guard let mdia = Self.child("mdia", in: moov, range: t),
                  let hdlr = Self.child("hdlr", in: moov, range: mdia),
                  String(decoding: moov[(hdlr.lowerBound + 16)..<(hdlr.lowerBound + 20)], as: UTF8.self) == "soun"
            else { continue }
            if let tkhd = Self.child("tkhd", in: moov, range: t) {
                let v = moov[tkhd.lowerBound + 8]
                audioTrackID = Self.u32(moov, tkhd.lowerBound + (v == 1 ? 28 : 20))
            }
            if let mdhd = Self.child("mdhd", in: moov, range: mdia) {
                let v = moov[mdhd.lowerBound + 8]
                timescale = Double(Self.u32(moov, mdhd.lowerBound + (v == 1 ? 28 : 20)))
            }
            guard let minf = Self.child("minf", in: moov, range: mdia),
                  let stbl = Self.child("stbl", in: moov, range: minf),
                  let stsd = Self.child("stsd", in: moov, range: stbl) else { continue }
            // stsd: full box (4) + entry count (4), then sample entries.
            let entryStart = stsd.lowerBound + 16
            guard let (codec, entrySize) = Self.box(at: entryStart, in: moov) else { continue }
            guard codec == "mp4a" else { throw DecodeError.unsupportedCodec(codec) }
            channels = AVAudioChannelCount(Self.u16(moov, entryStart + 24))
            sampleRate = Double(Self.u32(moov, entryStart + 32) >> 16)
            // Child boxes of mp4a start after its 28-byte sample entry body.
            let entry = entryStart..<(entryStart + entrySize)
            guard let esds = Self.child("esds", in: moov, range: entry, headerSkip: 36) else { continue }
            aacConfig = Self.audioSpecificConfig(moov[(esds.lowerBound + 12)..<esds.upperBound])
            found = true
            break
        }
        // Default sample duration/size for this track from mvex/trex.
        if let mvex = Self.child("mvex", in: moov, range: 0..<moov.count) {
            for trex in Self.children(of: moov, at: mvex.lowerBound + 8, end: mvex.upperBound) where trex.type == "trex" {
                let b = trex.range.lowerBound
                if Self.u32(moov, b + 12) == audioTrackID {
                    defaultDuration = Self.u32(moov, b + 20); defaultSize = Self.u32(moov, b + 24)
                }
            }
        }
        guard found, let config = aacConfig else { throw DecodeError.noAudioTrack }
        try makeConverters(config)
    }

    private func makeConverters(_ config: Data) throws {
        // Sample rate and channels from the AudioSpecificConfig when present.
        let bits = config.count >= 2 ? (UInt16(config[0]) << 8 | UInt16(config[1])) : 0
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let idx = Int((bits >> 7) & 0xF)
        if idx < rates.count { sampleRate = rates[idx] }
        let ch = AVAudioChannelCount((bits >> 3) & 0xF)
        if ch > 0 { channels = ch }

        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                               mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        guard let aac = AVAudioFormat(streamDescription: &asbd),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false),
              let dec = AVAudioConverter(from: aac, to: pcm),
              let res = AVAudioConverter(from: pcm, to: target) else { throw DecodeError.converter }
        dec.magicCookie = config
        aacFormat = aac; pcmFormat = pcm; decoder = dec; resampler = res
    }

    // MARK: Fragments

    private func decodeFragment(_ frag: Data, moofSize: Int) throws -> Decoded? {
        guard let decoder, let resampler, let aacFormat, let pcmFormat else { return nil }
        var baseTime: UInt64 = 0
        var sizes: [UInt32] = []
        var dataOffset = moofSize + 8 // default: right after mdat header
        var found = false
        for traf in Self.children(of: frag, at: 8, end: moofSize) where traf.type == "traf" {
            let r = traf.range
            var trackID: UInt32 = 0
            var tfDefaultSize = defaultSize
            if let tfhd = Self.child("tfhd", in: frag, range: r) {
                let flags = Self.u32(frag, tfhd.lowerBound + 8) & 0xFFFFFF
                trackID = Self.u32(frag, tfhd.lowerBound + 12)
                var p = tfhd.lowerBound + 16
                if flags & 0x01 != 0 { p += 8 }
                if flags & 0x02 != 0 { p += 4 }
                if flags & 0x08 != 0 { p += 4 }
                if flags & 0x10 != 0 { tfDefaultSize = Self.u32(frag, p); p += 4 }
            }
            if let id = audioTrackID, trackID != id { continue }
            if let tfdt = Self.child("tfdt", in: frag, range: r) {
                baseTime = frag[tfdt.lowerBound + 8] == 1 ? Self.u64(frag, tfdt.lowerBound + 12) : UInt64(Self.u32(frag, tfdt.lowerBound + 12))
            }
            if let trun = Self.child("trun", in: frag, range: r) {
                let flags = Self.u32(frag, trun.lowerBound + 8) & 0xFFFFFF
                let count = Int(Self.u32(frag, trun.lowerBound + 12))
                var p = trun.lowerBound + 16
                if flags & 0x01 != 0 { dataOffset = Int(Int32(bitPattern: Self.u32(frag, p))); p += 4 }
                if flags & 0x04 != 0 { p += 4 }
                for _ in 0..<count {
                    if flags & 0x100 != 0 { p += 4 }
                    if flags & 0x200 != 0 { sizes.append(Self.u32(frag, p)); p += 4 } else { sizes.append(tfDefaultSize) }
                    if flags & 0x400 != 0 { p += 4 }
                    if flags & 0x800 != 0 { p += 4 }
                }
            }
            found = true
            break
        }
        guard found, !sizes.isEmpty, dataOffset >= 0 else { return nil }
        let start = Double(baseTime) / timescale
        // Not continuous with what came before (a seek): reset the AAC decoder state.
        if let lastEnd, abs(start - lastEnd) > 0.05 { decoder.reset(); resampler.reset() }

        let total = sizes.reduce(0) { $0 + Int($1) }
        guard dataOffset + total <= frag.count else { return nil }
        let packets = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: AVAudioPacketCount(sizes.count),
                                              maximumPacketSize: Int(sizes.max() ?? 2048))
        var offset = 0
        frag.withUnsafeBytes { raw in
            let src = raw.baseAddress!.advanced(by: dataOffset)
            for (i, s) in sizes.enumerated() {
                packets.data.advanced(by: offset).copyMemory(from: src.advanced(by: offset), byteCount: Int(s))
                packets.packetDescriptions![i] = AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0,
                                                                              mDataByteSize: s)
                offset += Int(s)
            }
        }
        packets.packetCount = AVAudioPacketCount(sizes.count)
        packets.byteLength = UInt32(offset)

        let samples = try Self.drain(decoder, packets: packets, pcmFormat: pcmFormat, resampler: resampler, target: target)
        lastEnd = start + Double(sizes.count * 1024) / sampleRate
        return Decoded(start: start, samples: samples)
    }

    /// AVAudioConverter may stop partway through a large batch and expect to be called
    /// again; keep calling until all packets are decoded, then resample everything.
    static func drain(_ decoder: AVAudioConverter, packets: AVAudioCompressedBuffer, pcmFormat: AVAudioFormat,
                      resampler: AVAudioConverter, target: AVAudioFormat) throws -> [Float] {
        var fed = false
        var out: [Float] = []
        for _ in 0..<64 {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 8192) else { break }
            var err: NSError?
            let status = decoder.convert(to: pcm, error: &err) { _, s in
                if fed { s.pointee = .noDataNow; return nil }
                fed = true; s.pointee = .haveData; return packets
            }
            if let err { throw err }
            if pcm.frameLength > 0 { out += resampleAll(pcm, resampler: resampler, target: target) }
            if status != .haveData { break }
        }
        return out
    }

    static func resampleAll(_ pcm: AVAudioPCMBuffer, resampler: AVAudioConverter, target: AVAudioFormat) -> [Float] {
        var fed = false
        var out: [Float] = []
        for _ in 0..<16 {
            let cap = AVAudioFrameCount(Double(pcm.frameLength) * target.sampleRate / pcm.format.sampleRate) + 256
            guard let buf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { break }
            var err: NSError?
            let status = resampler.convert(to: buf, error: &err) { _, s in
                if fed { s.pointee = .noDataNow; return nil }
                fed = true; s.pointee = .haveData; return pcm
            }
            if err != nil { break }
            if let c = buf.floatChannelData, buf.frameLength > 0 { out += UnsafeBufferPointer(start: c[0], count: Int(buf.frameLength)) }
            if status != .haveData { break }
        }
        return out
    }

    private func resample(_ pcm: AVAudioPCMBuffer) -> [Float] {
        guard let resampler, pcm.frameLength > 0 else { return [] }
        let cap = AVAudioFrameCount(Double(pcm.frameLength) * target.sampleRate / pcm.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return [] }
        var fed = false
        var err: NSError?
        resampler.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return pcm
        }
        guard err == nil, let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    // MARK: Box helpers

    private static func box(at i: Int, in d: Data) -> (String, Int)? {
        guard i + 8 <= d.count else { return nil }
        var size = Int(u32(d, i))
        let type = String(decoding: d[(d.startIndex + i + 4)..<(d.startIndex + i + 8)], as: UTF8.self)
        if size == 1, i + 16 <= d.count { size = Int(u64(d, i + 8)) }
        guard size >= 8 else { return nil }
        return (type, size)
    }

    private static func children(of d: Data, at start: Int, end: Int) -> [(type: String, range: Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var i = start
        while i + 8 <= end, let (t, s) = box(at: i, in: d), i + s <= end {
            out.append((t, i..<(i + s))); i += s
        }
        return out
    }

    private static func child(_ type: String, in d: Data, range: Range<Int>, headerSkip: Int = 8) -> Range<Int>? {
        let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "mvex", "moof", "traf"]
        for c in children(of: d, at: range.lowerBound + headerSkip, end: range.upperBound) {
            if c.type == type { return c.range }
            if containers.contains(c.type), let r = child(type, in: d, range: c.range) { return r }
        }
        return nil
    }

    /// esds payload → DecoderSpecificInfo (tag 5) bytes.
    private static func audioSpecificConfig(_ esds: Data) -> Data? {
        let b = [UInt8](esds)
        var i = 0
        func len() -> Int {
            var n = 0
            for _ in 0..<4 where i < b.count { let x = b[i]; i += 1; n = (n << 7) | Int(x & 0x7F); if x & 0x80 == 0 { break } }
            return n
        }
        while i < b.count {
            let tag = b[i]; i += 1
            let l = len()
            switch tag {
            case 0x03: i += 3                    // ES_ID + flags (ignoring optional fields)
            case 0x04: i += 13                   // DecoderConfigDescriptor fixed part
            case 0x05: return i + l <= b.count ? Data(b[i..<(i + l)]) : nil
            default: i += l
            }
        }
        return nil
    }

    private static func u16(_ d: Data, _ i: Int) -> UInt16 {
        let s = d.startIndex + i; return UInt16(d[s]) << 8 | UInt16(d[s + 1])
    }
    private static func u32(_ d: Data, _ i: Int) -> UInt32 {
        let s = d.startIndex + i
        return UInt32(d[s]) << 24 | UInt32(d[s + 1]) << 16 | UInt32(d[s + 2]) << 8 | UInt32(d[s + 3])
    }
    private static func u64(_ d: Data, _ i: Int) -> UInt64 { UInt64(u32(d, i)) << 32 | UInt64(u32(d, i + 4)) }
}
