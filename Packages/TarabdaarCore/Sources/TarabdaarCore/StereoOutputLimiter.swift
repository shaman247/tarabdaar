import Foundation

public enum FinalOutputControl: Sendable {
    case gain, limiterCeiling, limiterLookahead, limiterRelease
}

struct OutputLimiterSettings: Equatable {
    static let ceilingSpec = ParamRegistry.spec("output_limiter_ceiling_db")!
    static let lookaheadSpec = ParamRegistry.spec("output_limiter_lookahead_ms")!
    static let releaseSpec = ParamRegistry.spec("output_limiter_release_ms")!
    var ceilingDB = ceilingSpec.def
    var lookaheadMS = lookaheadSpec.def
    var releaseMS = releaseSpec.def
}

/// Linked sample-peak protection with a soft knee and a smoothed lookahead envelope.
final class StereoOutputLimiter {
    static let ceilingDB = OutputLimiterSettings.ceilingSpec.def
    static let ceiling = pow(10, ceilingDB / 20)
    private static let kneeDB = 3.0
    private var ceiling = StereoOutputLimiter.ceiling
    private var kneeStart = pow(10, (ceilingDB - kneeDB / 2) / 20)
    private var kneeEnd = pow(10, (ceilingDB + kneeDB / 2) / 20)

    private let sampleRate: Double
    private(set) var settings = OutputLimiterSettings()
    private(set) var currentGain = 1.0
    private(set) var delayFrames = 0
    private var releaseStep = 0.0
    private var delayLeft: [Double]
    private var delayRight: [Double]
    private var delayIndex = 0
    private var minimumValues: [Double]
    private var minimumIndices: [Int]
    private var minimumHead = 0
    private var minimumCount = 0
    private var sampleIndex = 0
    private var envelope = 1.0
    private var firstAverage: MovingAverage
    private var secondAverage: MovingAverage

    static func delayFrames(sampleRate: Double, lookaheadMS: Double) -> Int {
        2 * max(1, Int((sampleRate * lookaheadMS / 2000).rounded()))
    }

    init(sampleRate: Double, settings: OutputLimiterSettings = .init()) {
        self.sampleRate = sampleRate
        let capacity = Self.delayFrames(sampleRate: sampleRate,
                                       lookaheadMS: OutputLimiterSettings.lookaheadSpec.hi)
        delayLeft = .init(repeating: 0, count: capacity)
        delayRight = .init(repeating: 0, count: capacity)
        minimumValues = .init(repeating: 1, count: capacity + 2)
        minimumIndices = .init(repeating: 0, count: capacity + 2)
        firstAverage = MovingAverage(capacity: capacity / 2 + 1)
        secondAverage = MovingAverage(capacity: capacity / 2 + 1)
        configure(settings)
    }

    /// Reuses maximum-sized storage; only the inactive lane is reconfigured while rendering.
    func configure(_ settings: OutputLimiterSettings, initialGain: Double = 1) {
        self.settings = settings
        ceiling = pow(10, settings.ceilingDB / 20)
        kneeStart = pow(10, (settings.ceilingDB - Self.kneeDB / 2) / 20)
        kneeEnd = pow(10, (settings.ceilingDB + Self.kneeDB / 2) / 20)
        delayFrames = Self.delayFrames(sampleRate: sampleRate, lookaheadMS: settings.lookaheadMS)
        releaseStep = 1 - exp(-1 / (sampleRate * settings.releaseMS / 1000))
        reset(initialGain: initialGain)
    }

    func reset(initialGain: Double = 1) {
        for i in 0..<delayFrames { delayLeft[i] = 0; delayRight[i] = 0 }
        delayIndex = 0
        minimumHead = 0
        minimumCount = 0
        sampleIndex = 0
        envelope = initialGain
        currentGain = initialGain
        firstAverage.reset(width: delayFrames / 2 + 1, value: initialGain)
        secondAverage.reset(width: delayFrames / 2 + 1, value: initialGain)
    }

    /// A common gain preserves the stereo image; the returned gain drives the reduction meter.
    @inline(__always)
    func process(left: Double, right: Double) -> (left: Float, right: Float, gain: Double) {
        // Invalid source samples cannot poison the delay or envelope state.
        let left = left.isFinite ? left : 0
        let right = right.isFinite ? right : 0
        let peak = max(abs(left), abs(right))
        let required: Double
        if peak <= kneeStart {
            required = 1
        } else if peak >= kneeEnd {
            required = ceiling / peak
        } else {
            let over = 20 * log10(peak) - settings.ceilingDB + Self.kneeDB / 2
            required = pow(10, -over * over / (2 * Self.kneeDB * 20))
        }

        // Monotonic deque: the minimum required gain over the last delayFrames + 1 samples.
        let capacity = minimumValues.count
        while minimumCount > 0, minimumIndices[minimumHead] < sampleIndex - delayFrames {
            minimumHead = (minimumHead + 1) % capacity
            minimumCount -= 1
        }
        while minimumCount > 0 {
            let tail = (minimumHead + minimumCount - 1) % capacity
            if minimumValues[tail] < required { break }
            minimumCount -= 1
        }
        let tail = (minimumHead + minimumCount) % capacity
        minimumValues[tail] = required
        minimumIndices[tail] = sampleIndex
        minimumCount += 1
        sampleIndex += 1

        envelope = min(minimumValues[minimumHead], envelope + (1 - envelope) * releaseStep)
        if 1 - envelope < 1e-12 { envelope = 1 }
        let smooth = secondAverage.push(firstAverage.push(envelope))
        let gain = smooth > 1 - 1e-12 ? 1 : max(0, smooth)
        currentGain = gain
        let delayedLeft = delayLeft[delayIndex]
        let delayedRight = delayRight[delayIndex]
        delayLeft[delayIndex] = left
        delayRight[delayIndex] = right
        delayIndex = (delayIndex + 1) % delayFrames

        // A peak's required gain is held throughout the entire smoothing support before
        // that peak leaves the delay. Thus smoothing cannot relax its ceiling. The clamp
        // only guards floating-point roundoff (including extreme, malformed source levels).
        let outputLeft = min(ceiling, max(-ceiling, delayedLeft * gain))
        let outputRight = min(ceiling, max(-ceiling, delayedRight * gain))
        return (Float(outputLeft), Float(outputRight), gain)
    }

    private struct MovingAverage {
        private var values: [Double]
        private var index = 0
        private var width: Int
        private var sum: Double
        private var error = 0.0

        init(capacity: Int) {
            values = .init(repeating: 1, count: capacity)
            width = capacity
            sum = Double(capacity)
        }

        mutating func reset(width: Int, value: Double) {
            self.width = width
            for i in 0..<width { values[i] = value }
            index = 0
            sum = Double(width) * value
            error = 0
        }

        @inline(__always)
        mutating func push(_ value: Double) -> Double {
            // Compensated accumulation keeps long-running, very quiet gain envelopes stable.
            let change = (value - values[index]) - error
            let next = sum + change
            error = (next - sum) - change
            sum = next
            values[index] = value
            index = (index + 1) % width
            return min(1, max(0, sum / Double(width)))
        }
    }
}

/// Two preallocated lanes warm and crossfade parameter edits without resetting audible audio.
final class OutputLimiterTransition {
    private var active: StereoOutputLimiter
    private var incoming: StereoOutputLimiter
    private let fadeFrames: Int
    private var warming = 0
    private var fading = 0
    private var transitioning = false
    private var requested: OutputLimiterSettings

    init(sampleRate: Double, settings: OutputLimiterSettings = .init()) {
        active = StereoOutputLimiter(sampleRate: sampleRate, settings: settings)
        incoming = StereoOutputLimiter(sampleRate: sampleRate, settings: settings)
        requested = settings
        fadeFrames = max(1, Int(sampleRate * 0.020))
    }

    func request(_ settings: OutputLimiterSettings) {
        requested = settings
        guard !transitioning, settings != active.settings else { return }
        incoming.configure(settings, initialGain: active.currentGain)
        warming = incoming.delayFrames
        fading = 0
        transitioning = true
    }

    func reset() {
        active.configure(requested)
        incoming.configure(requested)
        transitioning = false
    }

    @inline(__always)
    func process(left: Double, right: Double) -> (left: Float, right: Float, gain: Double) {
        let old = active.process(left: left, right: right)
        guard transitioning else { return old }
        let new = incoming.process(left: left, right: right)
        if warming > 0 {
            warming -= 1
            return old
        }
        fading += 1
        let progress = Double(fading) / Double(fadeFrames)
        let weight = progress * progress * (3 - 2 * progress)
        let output = (left: Float(Double(old.left) * (1 - weight) + Double(new.left) * weight),
                      right: Float(Double(old.right) * (1 - weight) + Double(new.right) * weight),
                      gain: old.gain * (1 - weight) + new.gain * weight)
        if fading == fadeFrames {
            swap(&active, &incoming)
            transitioning = false
            // A newer request is adopted at the next render-block boundary.
        }
        return output
    }
}
