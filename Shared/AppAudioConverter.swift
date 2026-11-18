import AVFoundation
import CoreMedia

/// Converts ReplayKit `.audioApp` / ScreenCaptureKit `.audio` sample buffers (usually 44.1/48 kHz, 1–2 ch,
/// Int16 — sometimes big-endian) into 16 kHz mono Float32.
///
/// Decoding the raw PCM by hand (rather than trusting AVAudioPCMBuffer) avoids the
/// well-known big-endian `.audioApp` quirk; only the final mono resample uses
/// AVAudioConverter, which is always given a standard native format.
final class AppAudioConverter {
    private var converter: AVAudioConverter?
    private var converterInputRate: Double = 0
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: Shared.sampleRate,
                                             channels: 1, interleaved: false)!
    private var mono: [Float] = []

    func convert(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        let channels = Int(max(asbd.mChannelsPerFrame, 1))
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bufferCount = nonInterleaved ? channels : 1

        // Fetch raw PCM into an AudioBufferList.
        var blockBuffer: CMBlockBuffer?
        let ablSize = MemoryLayout<AudioBufferList>.size + max(0, bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablRaw.deallocate() }
        let abl = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: ablSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isBigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let bits = Int(asbd.mBitsPerChannel)

        // Downmix to mono Float32 at the source rate.
        if mono.count != frames { mono = [Float](repeating: 0, count: frames) }
        for i in 0..<frames { mono[i] = 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let scale = 1 / Float(channels)

        for (bIndex, buffer) in buffers.enumerated() {
            guard let data = buffer.mData else { continue }
            let chInBuffer = nonInterleaved ? 1 : channels
            _ = bIndex
            for f in 0..<frames {
                for c in 0..<chInBuffer {
                    let idx = f * chInBuffer + c
                    let v: Float
                    switch (isFloat, bits) {
                    case (true, 32):
                        var raw = data.load(fromByteOffset: idx * 4, as: UInt32.self)
                        if isBigEndian { raw = raw.byteSwapped }
                        v = Float(bitPattern: raw)
                    case (false, 16):
                        var raw = data.load(fromByteOffset: idx * 2, as: Int16.self)
                        if isBigEndian { raw = raw.byteSwapped }
                        v = Float(raw) / 32768
                    case (false, 32):
                        var raw = data.load(fromByteOffset: idx * 4, as: Int32.self)
                        if isBigEndian { raw = raw.byteSwapped }
                        v = Float(raw) / 2_147_483_648
                    default:
                        return nil
                    }
                    mono[f] += v * scale
                }
            }
        }

        return resample(mono, from: asbd.mSampleRate)
    }

    private func resample(_ input: [Float], from rate: Double) -> [Float]? {
        if rate == Shared.sampleRate { return input }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return nil }
        if converter == nil || converterInputRate != rate {
            converter = AVAudioConverter(from: inFormat, to: outputFormat)
            converterInputRate = rate
        }
        guard let converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(input.count)) else { return nil }
        inBuf.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: input.count) }

        let outCap = AVAudioFrameCount(Double(input.count) * Shared.sampleRate / rate) + 32
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCap) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard error == nil, let ch = outBuf.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
}
