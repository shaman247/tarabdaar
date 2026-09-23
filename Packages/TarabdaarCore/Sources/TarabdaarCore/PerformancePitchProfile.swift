import Foundation
import SarangiKit

/// Event-timed pitch occupancy; callers serialize access, timestamps are monotonic seconds.
public struct PerformancePitchProfile {
    public static let binCount = 120
    public struct Snapshot {
        public let short: [Double]
        public let medium: [Double]
        public let performance: [Double]
        public let seededDegrees: Set<Int>
        public let seeding: Bool
        public let activeSeconds: Double
    }
    private struct Bucket {
        var tick = Int.min
        var bins = [Double](repeating: 0, count: binCount)
    }
    private var buckets = [Bucket](repeating: Bucket(), count: 602)
    private var total = [Double](repeating: 0, count: binCount)
    private var held: [UInt16: Double] = [:]
    private var dwell: [UInt16: (degree: Int, seconds: Double)] = [:]
    private var lastTime: Double?
    private var tonic = 0.0
    private var ratios: [Double] = []
    private var seeded = Set<Int>()
    private var seeding = false

    public init() {}

    public mutating func configure(tonicSemis: Double, ratios: [Double], at time: Double) {
        guard tonicSemis.isFinite, ratios.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        guard tonic != tonicSemis || self.ratios != ratios else { return }
        tonic = tonicSemis
        self.ratios = ratios
        reset(at: time)
    }

    public mutating func setPitch(_ pitch: Double?, for id: UInt16, at time: Double) {
        advance(to: time)
        held[id] = pitch.flatMap { $0.isFinite ? $0 : nil }
        if pitch == nil { dwell[id] = nil }
    }

    public mutating func releaseAll(at time: Double) {
        advance(to: time)
        held.removeAll()
        dwell.removeAll()
    }

    public mutating func reset(at time: Double, seed: Bool = false) {
        buckets = [Bucket](repeating: Bucket(), count: 602)
        total = [Double](repeating: 0, count: Self.binCount)
        dwell.removeAll()
        seeded.removeAll()
        seeding = seed
        lastTime = time
    }

    public mutating func finishSeed(at time: Double) {
        advance(to: time)
        guard seeding else { return }
        total = [Double](repeating: 0, count: Self.binCount)
        for degree in seeded {
            total[bin(for: tonic + 12 * log2(ratios[degree]))] += 2
        }
        buckets = [Bucket](repeating: Bucket(), count: 602)
        seeding = false
        dwell.removeAll()
    }

    private func bin(for pitch: Double) -> Int {
        let octaves = (pitch - tonic) / 12
        let phase = octaves - floor(octaves)
        return Int((phase * Double(Self.binCount)).rounded()) % Self.binCount
    }

    public static func nearestDegree(ratio: Double, scale: [Double], corridor: Double = 50) -> Int? {
        guard ratio.isFinite, ratio > 0 else { return nil }
        var best: (Int, Double)?
        for (i, r) in scale.enumerated() where r.isFinite && r > 0 {
            let d = log2(ratio / r)
            let cents = abs(d - d.rounded()) * 1200
            if cents <= corridor && (best == nil || cents < best!.1) { best = (i, cents) }
        }
        return best?.0
    }

    private mutating func advance(to time: Double) {
        guard time.isFinite else { return }
        guard let start = lastTime else { lastTime = time; return }
        guard time > start else { return }
        lastTime = time
        guard !held.isEmpty, !ratios.isEmpty else { return }
        let dt = time - start
        var weights: [Int: Double] = [:]
        for (id, pitch) in held {
            weights[bin(for: pitch), default: 0] += 1 / Double(held.count)
            if seeding {
                let degree = Self.nearestDegree(ratio: pow(2, (pitch - tonic) / 12),
                                               scale: ratios, corridor: 30)
                if let degree {
                    let previous = dwell[id]
                    let seconds = (previous?.degree == degree ? previous!.seconds : 0) + dt
                    dwell[id] = (degree, seconds)
                    if seconds >= 0.18 { seeded.insert(degree) }
                } else { dwell[id] = nil }
            }
        }
        for (bin, weight) in weights { total[bin] += dt * weight }
        // Only the most recent minute needs storage, even after a long idle UI interval.
        var cursor = max(start, time - 60.1)
        var tick = Int(floor(cursor * 10))
        while cursor < time {
            let end = min(time, Double(tick + 1) / 10)
            guard end > cursor else { tick += 1; continue }
            let slot = ((tick % buckets.count) + buckets.count) % buckets.count
            if buckets[slot].tick != tick { buckets[slot] = Bucket(tick: tick) }
            for (bin, weight) in weights { buckets[slot].bins[bin] += (end - cursor) * weight }
            cursor = end
            tick += 1
        }
    }

    public mutating func snapshot(at time: Double) -> Snapshot {
        advance(to: time)
        func window(_ seconds: Double) -> [Double] {
            var result = [Double](repeating: 0, count: Self.binCount)
            for bucket in buckets where bucket.tick != Int.min {
                let start = Double(bucket.tick) / 10
                let fraction = max(0, min(start + 0.1, time) - max(start, time - seconds)) / max(1e-9, min(0.1, time - start))
                guard fraction > 0 else { continue }
                for i in result.indices { result[i] += bucket.bins[i] * min(1, fraction) }
            }
            return result
        }
        return Snapshot(short: window(10), medium: window(60), performance: total,
                        seededDegrees: seeded, seeding: seeding, activeSeconds: total.reduce(0, +))
    }

    /// Octave-folded evidence near each scale degree; unrepresented pitches stay unassigned.
    public static func degreeWeights(_ bins: [Double], scale: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: scale.count)
        for (bin, seconds) in bins.enumerated() {
            if let d = nearestDegree(ratio: pow(2, Double(bin) / Double(binCount)), scale: scale) {
                result[d] += seconds
            }
        }
        return result
    }

    /// Relative salience is an attenuation only, with a floor for incidental notes.
    public static func gains(snapshot: Snapshot, scale: [Double]) -> [Double] {
        if snapshot.seeding {
            return scale.indices.map { snapshot.seededDegrees.isEmpty || snapshot.seededDegrees.contains($0) ? 1 : 0.15 }
        }
        let windows = [snapshot.performance, snapshot.medium, snapshot.short]
        let mix = [0.6, 0.25, 0.15]
        var scores = [Double](repeating: 0, count: scale.count)
        for (bins, weight) in zip(windows, mix) {
            let evidence = degreeWeights(bins, scale: scale)
            let sum = evidence.reduce(0, +)
            guard sum > 0 else { continue }
            for i in scores.indices { scores[i] += weight * evidence[i] / sum }
        }
        guard let peak = scores.max(), peak > 0 else { return scores.map { _ in 1 } }
        return scores.map { 0.15 + 0.85 * sqrt($0 / peak) }
    }
}
