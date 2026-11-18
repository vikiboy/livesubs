import Foundation

/// Single-producer / single-consumer ring buffer of 16 kHz mono Float32 samples,
/// backed by a memory-mapped file in the App Group container so the broadcast
/// extension (producer) and the app (consumer) share it with zero copies and
/// without sockets. The extension never holds more than this ~2 MB mapping,
/// keeping it far below the ReplayKit extension memory ceiling.
///
/// Layout (little-endian, 64-byte header):
///   0  UInt32 magic
///   4  UInt32 capacity (samples)
///   8  UInt64 writeIndex  – total samples ever written (monotonic)
///  16  UInt64 sessionID   – changes every broadcast so readers can resync
///  24  Float64 lastWriteTime (CFAbsoluteTime)
///  64… Float32 samples[capacity]
final class AudioRingBuffer {
    private static let magic: UInt32 = 0x4C53_5542 // "LSUB"
    private static let headerSize = 64

    let capacity: Int
    private let fd: Int32
    private let base: UnsafeMutableRawPointer
    private let mappedSize: Int

    private var samples: UnsafeMutablePointer<Float> {
        (base + Self.headerSize).assumingMemoryBound(to: Float.self)
    }

    /// Opens (creating if needed) the shared ring buffer file.
    init?(url: URL, capacity: Int = Shared.ringCapacitySamples) {
        self.capacity = capacity
        mappedSize = Self.headerSize + capacity * MemoryLayout<Float>.size
        fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        guard ftruncate(fd, off_t(mappedSize)) == 0,
              let ptr = mmap(nil, mappedSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              ptr != MAP_FAILED else {
            close(fd)
            return nil
        }
        base = ptr
        if base.load(as: UInt32.self) != Self.magic || base.load(fromByteOffset: 4, as: UInt32.self) != UInt32(capacity) {
            memset(base, 0, Self.headerSize)
            base.storeBytes(of: UInt32(capacity), toByteOffset: 4, as: UInt32.self)
            base.storeBytes(of: Self.magic, as: UInt32.self)
        }
    }

    deinit {
        munmap(base, mappedSize)
        close(fd)
    }

    // MARK: Header

    var writeIndex: UInt64 {
        let v = base.load(fromByteOffset: 8, as: UInt64.self)
        OSMemoryBarrier()
        return v
    }

    var sessionID: UInt64 { base.load(fromByteOffset: 16, as: UInt64.self) }
    var lastWriteTime: CFAbsoluteTime { base.load(fromByteOffset: 24, as: Double.self) }

    // MARK: Producer (broadcast extension)

    /// Starts a new session; readers will notice the changed ID and resync.
    func beginSession() {
        base.storeBytes(of: UInt64(0), toByteOffset: 8, as: UInt64.self)
        base.storeBytes(of: UInt64.random(in: 1...UInt64.max), toByteOffset: 16, as: UInt64.self)
        OSMemoryBarrier()
    }

    func write(_ input: UnsafeBufferPointer<Float>) {
        guard !input.isEmpty, let src = input.baseAddress else { return }
        var w = base.load(fromByteOffset: 8, as: UInt64.self)
        var remaining = input.count
        var offset = 0
        // If a write is larger than the buffer, keep only the newest audio.
        if remaining > capacity {
            offset = remaining - capacity
            w += UInt64(offset)
            remaining = capacity
        }
        while remaining > 0 {
            let pos = Int(w % UInt64(capacity))
            let n = min(remaining, capacity - pos)
            (samples + pos).update(from: src + offset, count: n)
            offset += n
            remaining -= n
            w += UInt64(n)
        }
        OSMemoryBarrier() // publish samples before the index
        base.storeBytes(of: w, toByteOffset: 8, as: UInt64.self)
        base.storeBytes(of: CFAbsoluteTimeGetCurrent(), toByteOffset: 24, as: Double.self)
    }

    // MARK: Consumer (app)

    /// Copies all samples written after `readIndex`, advancing it. If the reader
    /// fell more than `capacity` behind, older audio is skipped.
    func read(from readIndex: inout UInt64) -> [Float] {
        let w = writeIndex
        if w < readIndex { readIndex = 0 } // producer restarted
        var available = Int(w - readIndex)
        guard available > 0 else { return [] }
        if available > capacity {
            readIndex = w - UInt64(capacity)
            available = capacity
        }
        var out = [Float](repeating: 0, count: available)
        out.withUnsafeMutableBufferPointer { dst in
            var r = readIndex
            var copied = 0
            while copied < available {
                let pos = Int(r % UInt64(capacity))
                let n = min(available - copied, capacity - pos)
                (dst.baseAddress! + copied).update(from: samples + pos, count: n)
                copied += n
                r += UInt64(n)
            }
        }
        readIndex = w
        return out
    }
}
