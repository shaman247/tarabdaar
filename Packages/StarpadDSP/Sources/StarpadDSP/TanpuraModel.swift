import Foundation

/// The complete tanpura instrument: four harmonic-resolved strings, a
/// sympathetic cross-excitation table, a 3-band body-resonance filter with
/// tilt shelf, and per-string stereo panning.
///
/// Real-time contract: every call (including `renderAdd`) must happen under
/// the owner's lock; `renderAdd` allocates nothing and adds into the
/// caller's buffers (which the caller zeroes). The offline renderer drives
/// the same code single-threaded with sample-accurate plucks via
/// `pluckAt(sample:string:velocity:)`.
public final class TanpuraModel {
    public static let stringCount = 4
    private static let maxBlock = 4096
    private static let queueCapacity = 256

    private let fs: Double
    private var p = TanpuraParams()
    private var strings: [TanpuraString] = []

    /// Times the model recovered from a non-finite state (should stay 0).
    public private(set) var recoveryCount = 0
    /// Plucks dropped because the schedule queue was full (should stay 0).
    public private(set) var droppedPluckCount = 0

    // Scheduled plucks (offline path). Fixed slots, scanned at segment
    // boundaries; `at < 0` marks a free slot.
    private struct PendingPluck { var at: Int64; var string: Int; var velocity: Double }
    private var queue = [PendingPluck](repeating: .init(at: -1, string: 0, velocity: 0),
                                       count: TanpuraModel.queueCapacity)
    private var queuedCount = 0
    private var sampleClock: Int64 = 0

    // Cross-string sympathetic coincidences: per source string, the
    // (target string, target harmonic) pairs within crossTolCents.
    private var crossTable: [[(string: Int, harmonic: Int)]] = [[], [], [], []]

    // Per-string equal-power pan gains.
    private var panL = [Double](repeating: 0.7071, count: 4)
    private var panR = [Double](repeating: 0.7071, count: 4)

    // Body filter: 3 parallel RBJ bandpass biquads per channel + dry path
    // + first-order high shelf (tiltDB at 1.5 kHz).
    private var bodyB0 = [Double](repeating: 0, count: 3)
    private var bodyA1 = [Double](repeating: 0, count: 3)
    private var bodyA2 = [Double](repeating: 0, count: 3)
    private var bodyGain = [Double](repeating: 0, count: 3)
    private var bodyX1 = [Double](repeating: 0, count: 6)  // [band*2 + ch]
    private var bodyX2 = [Double](repeating: 0, count: 6)
    private var bodyY1 = [Double](repeating: 0, count: 6)
    private var bodyY2 = [Double](repeating: 0, count: 6)
    private var shelfZ = [Double](repeating: 0, count: 2)
    private var shelfA: Double = 0
    private var shelfGainMinus1: Double = 0

    // Scratch (preallocated; renderAdd is allocation-free).
    private var monoScratch = [Double](repeating: 0, count: TanpuraModel.maxBlock)
    private var mixL = [Double](repeating: 0, count: TanpuraModel.maxBlock)
    private var mixR = [Double](repeating: 0, count: TanpuraModel.maxBlock)

    // Room: small Schroeder reverb (predelay → 4 damped feedback combs →
    // 2 series allpasses, per channel, decorrelated delays), wet-added
    // after body/shelf and BEFORE master gain + limiter. The reference
    // recording's room is part of the matched sound — a bone-dry render
    // plateaued at ~6.8 dB specres (run 9) with the residual spread
    // diffusely across every band.
    private static let combMsL: [Double] = [29.7, 37.1, 41.1, 43.7]
    private static let combMsR: [Double] = [30.7, 35.9, 42.3, 45.0]
    private static let apMs: [Double] = [5.0, 1.7]
    private var combBuf: [[Double]] = []     // [ch*4 + c]
    private var combIdx = [Int](repeating: 0, count: 8)
    private var combLen = [Int](repeating: 1, count: 8)
    private var combFb = [Double](repeating: 0, count: 8)
    private var combFilt = [Double](repeating: 0, count: 8)
    private var apBuf: [[Double]] = []       // [ch*2 + a]
    private var apIdx = [Int](repeating: 0, count: 4)
    private var apLen = [Int](repeating: 1, count: 4)
    private var preBuf: [[Double]] = []      // [ch]
    private var preIdx = [Int](repeating: 0, count: 2)
    private var preLen = [Int](repeating: 1, count: 2)
    private var roomWet: Double = 0
    private var roomDampCoef: Double = 0.45

    public init(sampleRate: Double, seed: UInt64 = 0x5EED_1A4B, params: TanpuraParams = TanpuraParams()) {
        self.fs = sampleRate
        self.p = params
        for i in 0..<TanpuraModel.stringCount {
            strings.append(TanpuraString(sampleRate: sampleRate,
                                         seed: seed &+ UInt64(i) &* 0x9E37_79B9_7F4A_7C15,
                                         params: params,
                                         stringParams: params.strings[i]))
        }
        // Room buffers (fixed delay lengths; only gains change on
        // reconfigure, so render stays allocation-free).
        for ch in 0..<2 {
            let ms = ch == 0 ? TanpuraModel.combMsL : TanpuraModel.combMsR
            for c in 0..<4 {
                let n = max(8, Int(ms[c] * 0.001 * fs))
                combLen[ch * 4 + c] = n
                combBuf.append([Double](repeating: 0, count: n))
            }
            for a in 0..<2 {
                let n = max(4, Int(TanpuraModel.apMs[a] * 0.001 * fs * (ch == 0 ? 1.0 : 1.07)))
                apLen[ch * 2 + a] = n
                apBuf.append([Double](repeating: 0, count: n))
            }
            preBuf.append([Double](repeating: 0, count: max(4, Int(0.045 * fs))))
        }
        configure()
    }

    /// Current parameters (read-only mirror for UI/state inspection).
    public var params: TanpuraParams { p }

    /// Swap in a new parameter set; recomputes all derived coefficients.
    public func setParams(_ newParams: TanpuraParams) {
        p = newParams
        configure()
    }

    private func configure() {
        for i in 0..<TanpuraModel.stringCount {
            strings[i].apply(params: p, stringParams: p.strings[i])
        }

        // Pans: strings spread at (-1, -1/3, 1/3, 1) × panSpread.
        let positions: [Double] = [-1, -1.0 / 3.0, 1.0 / 3.0, 1]
        for i in 0..<4 {
            let angle = (positions[i] * p.panSpread + 1) * Double.pi / 4
            panL[i] = cos(angle)
            panR[i] = sin(angle)
        }

        // Body bands.
        for b in 0..<3 {
            let band = p.body[b]
            let w0 = 2 * Double.pi * min(band.freq, 0.45 * fs) / fs
            let alpha = sin(w0) / (2 * max(0.3, band.q))
            let a0 = 1 + alpha
            bodyB0[b] = alpha / a0
            bodyA1[b] = (-2 * cos(w0)) / a0
            bodyA2[b] = (1 - alpha) / a0
            bodyGain[b] = band.gain
        }

        // Tilt shelf (first-order high shelf, pivot 1.5 kHz).
        shelfA = exp(-2 * Double.pi * 1500 / fs)
        shelfGainMinus1 = pow(10, p.tiltDB / 20) - 1

        // Room: comb feedbacks from the RT60-style decay, predelay length.
        roomWet = p.roomWetDB > -59.9 ? pow(10, p.roomWetDB / 20) : 0
        roomDampCoef = min(max(p.roomDamp, 0), 0.98)
        for i in 0..<8 {
            let delayS = Double(combLen[i]) / fs
            combFb[i] = pow(10, -3 * delayS / max(0.15, p.roomDecayS))
        }
        for ch in 0..<2 {
            preLen[ch] = max(1, min(preBuf[ch].count,
                                    Int(p.roomPredelayMs * 0.001 * fs)))
        }

        // Cross-excitation coincidence table.
        crossTable = [[], [], [], []]
        if p.crossExcite > 0 {
            let freqs = strings.map { $0.harmonicFrequencies }
            for src in 0..<4 {
                var entries: [(string: Int, harmonic: Int)] = []
                for fm in freqs[src] where fm > 0 {
                    for dst in 0..<4 where dst != src {
                        for (k, fk) in freqs[dst].enumerated() where fk > 0 {
                            let cents = abs(1200 * log2(fk / fm))
                            if cents <= p.crossTolCents,
                               !entries.contains(where: { $0.string == dst && $0.harmonic == k }) {
                                entries.append((dst, k))
                            }
                        }
                    }
                }
                crossTable[src] = entries
            }
        }
    }

    // MARK: - Excitation

    /// Pluck a string now (live/UI path). Applies immediately; the next
    /// rendered block picks it up.
    public func pluck(string: Int, velocity: Double) {
        guard strings.indices.contains(string) else { return }
        doPluck(string: string, velocity: velocity)
    }

    /// Schedule a sample-accurate pluck (offline render path).
    public func pluckAt(sample: Int64, string: Int, velocity: Double) {
        guard strings.indices.contains(string) else { return }
        for i in 0..<TanpuraModel.queueCapacity where queue[i].at < 0 {
            queue[i] = PendingPluck(at: max(sample, sampleClock), string: string, velocity: velocity)
            queuedCount += 1
            return
        }
        droppedPluckCount += 1
    }

    private func doPluck(string: Int, velocity: Double) {
        strings[string].pluck(velocity: velocity)
        if p.crossExcite > 0 {
            for entry in crossTable[string] {
                strings[entry.string].exciteHarmonic(entry.harmonic,
                                                     amount: velocity * p.crossExcite)
            }
        }
    }

    /// Apply every queued pluck due at the current sample clock; returns
    /// the next due time after `sampleClock`, or nil.
    private func applyDueAndFindNext() -> Int64? {
        var next: Int64? = nil
        guard queuedCount > 0 else { return nil }
        for i in 0..<TanpuraModel.queueCapacity {
            let at = queue[i].at
            if at < 0 { continue }
            if at <= sampleClock {
                doPluck(string: queue[i].string, velocity: queue[i].velocity)
                queue[i].at = -1
                queuedCount -= 1
            } else if next == nil || at < next! {
                next = at
            }
        }
        return next
    }

    // MARK: - Render

    /// Render and ADD into the caller's stereo Float buffers.
    public func renderAdd(intoL: UnsafeMutablePointer<Float>,
                          intoR: UnsafeMutablePointer<Float>,
                          frames: Int) {
        var offset = 0
        while offset < frames {
            let n = min(frames - offset, TanpuraModel.maxBlock)
            renderChunk(intoL: intoL + offset, intoR: intoR + offset, frames: n)
            offset += n
        }
    }

    private func renderChunk(intoL: UnsafeMutablePointer<Float>,
                             intoR: UnsafeMutablePointer<Float>,
                             frames: Int) {
        for s in strings { s.tickModulation(blockFrames: frames) }

        var done = 0
        while done < frames {
            let next = applyDueAndFindNext()
            var segLen = frames - done
            if let next, next > sampleClock {
                segLen = min(segLen, Int(next - sampleClock))
            }
            if segLen <= 0 { segLen = 1 }
            renderSegment(intoL: intoL + done, intoR: intoR + done, frames: segLen)
            sampleClock += Int64(segLen)
            done += segLen
        }

        // NaN guard: a non-finite state would otherwise ring forever.
        var finite = bodyY1[0].isFinite && shelfZ[0].isFinite && shelfZ[1].isFinite
            && combFilt[0].isFinite && combFilt[4].isFinite
        for s in strings where !s.isFinite { finite = false }
        if !finite {
            for s in strings { s.clearState() }
            resetFilterState()
            recoveryCount += 1
        }
    }

    private func renderSegment(intoL: UnsafeMutablePointer<Float>,
                               intoR: UnsafeMutablePointer<Float>,
                               frames: Int) {
        for f in 0..<frames {
            mixL[f] = 0
            mixR[f] = 0
        }
        for i in 0..<TanpuraModel.stringCount {
            for f in 0..<frames { monoScratch[f] = 0 }
            strings[i].renderAdd(mono: &monoScratch, frames: frames)
            let gl = panL[i], gr = panR[i]
            for f in 0..<frames {
                mixL[f] += monoScratch[f] * gl
                mixR[f] += monoScratch[f] * gr
            }
        }

        // Body + tilt → room wet → master gain + limiter, per channel.
        processBody(&mixL, ch: 0, frames: frames)
        processBody(&mixR, ch: 1, frames: frames)
        if roomWet > 0 {
            processRoom(&mixL, ch: 0, frames: frames)
            processRoom(&mixR, ch: 1, frames: frames)
        }
        finalize(&mixL, frames: frames)
        finalize(&mixR, frames: frames)

        for f in 0..<frames {
            intoL[f] += Float(mixL[f])
            intoR[f] += Float(mixR[f])
        }
    }

    private func processBody(_ channel: inout [Double], ch: Int, frames: Int) {
        let dry = p.bodyDry
        var z = shelfZ[ch]
        channel.withUnsafeMutableBufferPointer { buf in
            for f in 0..<frames {
                let x = buf[f]
                var acc = dry * x
                for b in 0..<3 {
                    let i = b * 2 + ch
                    let y = bodyB0[b] * (x - bodyX2[i]) - bodyA1[b] * bodyY1[i] - bodyA2[b] * bodyY2[i]
                    bodyX2[i] = bodyX1[i]; bodyX1[i] = x
                    bodyY2[i] = bodyY1[i]; bodyY1[i] = y
                    acc += bodyGain[b] * y
                }
                // First-order high shelf: out = x + (G−1)·HP(x).
                z += (1 - shelfA) * (acc - z)
                buf[f] = acc + shelfGainMinus1 * (acc - z)
            }
        }
        shelfZ[ch] = z
    }

    /// Add the room wet signal in place (Schroeder: predelay → 4 damped
    /// feedback combs in parallel → 2 series allpasses).
    private func processRoom(_ channel: inout [Double], ch: Int, frames: Int) {
        let damp = roomDampCoef
        let wet = roomWet
        channel.withUnsafeMutableBufferPointer { buf in
            for f in 0..<frames {
                let dryIn = buf[f]
                // Predelay.
                var pi_ = preIdx[ch]
                let pn = preLen[ch]
                let x = preBuf[ch][pi_ % pn]
                preBuf[ch][pi_ % pn] = dryIn
                pi_ = (pi_ + 1) % pn
                preIdx[ch] = pi_
                // Parallel damped combs.
                var sum = 0.0
                for c in 0..<4 {
                    let i = ch * 4 + c
                    let n = combLen[i]
                    var idx = combIdx[i]
                    let out = combBuf[i][idx]
                    combFilt[i] = out * (1 - damp) + combFilt[i] * damp
                    combBuf[i][idx] = x + combFilt[i] * combFb[i]
                    idx += 1
                    if idx >= n { idx = 0 }
                    combIdx[i] = idx
                    sum += out
                }
                sum *= 0.25
                // Series allpasses (g = 0.5).
                for a in 0..<2 {
                    let i = ch * 2 + a
                    let n = apLen[i]
                    var idx = apIdx[i]
                    let bufOut = apBuf[i][idx]
                    let v = sum + 0.5 * bufOut
                    apBuf[i][idx] = v
                    sum = bufOut - 0.5 * v
                    idx += 1
                    if idx >= n { idx = 0 }
                    apIdx[i] = idx
                }
                buf[f] = dryIn + wet * sum
            }
        }
    }

    /// Master gain + the soft safety limiter (exactly linear below ±0.85,
    /// smooth saturation to a ±1.0 ceiling above — inaudible at normal
    /// levels; keeps extreme user params from blasting output).
    private func finalize(_ channel: inout [Double], frames: Int) {
        let master = p.masterGain
        channel.withUnsafeMutableBufferPointer { buf in
            for f in 0..<frames {
                var out = buf[f] * master
                let a = abs(out)
                if a > 0.85 {
                    out = (out < 0 ? -1.0 : 1.0) * (0.85 + 0.15 * tanh((a - 0.85) / 0.15))
                }
                buf[f] = out
            }
        }
    }

    private func resetFilterState() {
        for i in 0..<6 {
            bodyX1[i] = 0; bodyX2[i] = 0; bodyY1[i] = 0; bodyY2[i] = 0
        }
        shelfZ[0] = 0; shelfZ[1] = 0
        for i in combBuf.indices {
            for j in combBuf[i].indices { combBuf[i][j] = 0 }
            combFilt[i] = 0
        }
        for i in apBuf.indices {
            for j in apBuf[i].indices { apBuf[i][j] = 0 }
        }
        for i in preBuf.indices {
            for j in preBuf[i].indices { preBuf[i][j] = 0 }
        }
    }

    /// Silence everything immediately (envelopes, noise, filters, queued
    /// plucks). Parameters are kept.
    public func clearState() {
        for s in strings { s.clearState() }
        resetFilterState()
        for i in 0..<TanpuraModel.queueCapacity { queue[i].at = -1 }
        queuedCount = 0
    }
}
