import Foundation

/// Single-producer / single-consumer stereo Float ring buffer used to
/// hand SWAM's audio output from the AVAudioEngine tap thread to the
/// modal source-node render thread, where it drives the sympathetic-
/// string pass.
///
/// Synchronization is intentionally minimal: an `NSLock` with `try()`
/// on the consumer (audio) side. NSLock isn't strictly realtime-safe,
/// but contention here is rare (tap fires ~once per ~10 ms, render
/// fires ~once per ~6 ms — they collide < 1 % of the time) and the
/// consumer falls back to "produce no samples this block" if it can't
/// grab the lock, which manifests as a single block of muted sym halo
/// and is inaudible. If profiling later shows trouble, this can be
/// rewritten with `swift-atomics` indices.
public final class SPSCAudioRing {
    /// Capacity in frames per channel (always a power of 2 so the
    /// index wrap is a bitmask).
    public let capacity: Int
    private let mask: Int
    private let bufL: UnsafeMutableBufferPointer<Float>
    private let bufR: UnsafeMutableBufferPointer<Float>
    private var writeIdx: Int = 0
    private var readIdx: Int = 0
    private let lock = NSLock()

    public init(capacityFrames: Int) {
        var cap = 1
        while cap < capacityFrames { cap <<= 1 }
        self.capacity = cap
        self.mask = cap - 1
        let l = UnsafeMutableBufferPointer<Float>.allocate(capacity: cap)
        let r = UnsafeMutableBufferPointer<Float>.allocate(capacity: cap)
        l.initialize(repeating: 0)
        r.initialize(repeating: 0)
        self.bufL = l
        self.bufR = r
    }

    deinit {
        bufL.deallocate()
        bufR.deallocate()
    }

    /// Producer side. Called from the AVAudioEngine tap thread. If the
    /// ring is full, the oldest data is silently dropped (writeIdx
    /// advances, readIdx is pulled forward to keep them within
    /// `capacity` of each other) — this is the right policy for an
    /// audio feed where stale data isn't useful.
    public func write(L: UnsafePointer<Float>,
                      R: UnsafePointer<Float>,
                      count: Int) {
        lock.lock()
        defer { lock.unlock() }
        let n = min(count, capacity)
        for i in 0..<n {
            bufL[writeIdx & mask] = L[i]
            bufR[writeIdx & mask] = R[i]
            writeIdx &+= 1
        }
        // If we overflowed, drop the oldest samples by jumping readIdx
        // forward. This keeps the live data window centered on the
        // newest input — sympathetic strings should hear what SWAM
        // *just* played, not stale audio from hundreds of ms ago.
        let occupied = writeIdx - readIdx
        if occupied > capacity {
            readIdx = writeIdx - capacity
        }
    }

    /// Consumer side. Called from the modal source-node render thread.
    /// Returns the number of frames actually copied; the caller is
    /// expected to zero the tail of its output buffers if `n < count`.
    /// On lock contention (rare) returns 0 so the audio thread never
    /// blocks.
    @discardableResult
    public func read(intoL outL: UnsafeMutablePointer<Float>,
                     intoR outR: UnsafeMutablePointer<Float>,
                     count: Int) -> Int {
        guard lock.try() else { return 0 }
        defer { lock.unlock() }
        let avail = writeIdx - readIdx
        let n = min(count, avail)
        for i in 0..<n {
            outL[i] = bufL[readIdx & mask]
            outR[i] = bufR[readIdx & mask]
            readIdx &+= 1
        }
        return n
    }

    /// Resets the indices without freeing the storage. Use on preset
    /// switch / AU reload so stale audio from a previous instance
    /// doesn't briefly drive the sym pool.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        readIdx = 0
        writeIdx = 0
        for i in 0..<capacity {
            bufL[i] = 0
            bufR[i] = 0
        }
    }
}
