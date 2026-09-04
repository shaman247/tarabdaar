import Foundation
import QuartzCore

// MARK: - PitchPoint / PitchScale

/// One scale pitch: an exact ratio over the tonic (`num/den`), a layout-only
/// vertical position `y` (0…1) and an optional `label` (blank → the ratio).
public struct PitchPoint: Identifiable, Equatable {
    public let id: UUID
    public var num: Int
    public var den: Int
    public var y: Double
    public var label: String
    /// When false the pitch stays in the scale but is excluded from the pad
    /// (no cell, not playable).
    public var enabled: Bool

    /// Equality is CONTENT equality — `id` is UI identity (ForEach), not
    /// pitch identity, and every sync-blob decode mints fresh UUIDs. A
    /// re-pushed identical scale must compare equal, or `applySyncedState`
    /// would stop every sounding touch on every push.
    public static func == (a: PitchPoint, b: PitchPoint) -> Bool {
        a.num == b.num && a.den == b.den && a.y == b.y
            && a.label == b.label && a.enabled == b.enabled
    }

    public init(id: UUID = UUID(), num: Int, den: Int, y: Double,
                label: String = "", enabled: Bool = true) {
        self.id = id
        self.num = num
        self.den = max(1, den)
        self.y = min(max(0, y), 1)
        self.label = label
        self.enabled = enabled
    }

    public var ratio: Double { Double(num) / Double(max(1, den)) }
    /// X position inside the one-octave rectangle: `log2(ratio)` ∈ [0, 1].
    public var xFraction: Double { log2(ratio) }
    public var ratioString: String { "\(num)/\(den)" }
    /// The pitch's display name: `label` if set, else the ratio string.
    public var displayLabel: String { label.isEmpty ? ratioString : label }
}

public struct PitchScale: Equatable {
    public var points: [PitchPoint]

    public init(points: [PitchPoint]) {
        self.points = points
    }

    /// 12-tone just intonation laid out like a piano (white-key classes
    /// low at y 5/6, black-key classes high at y 2/6 — two command-snap
    /// rungs). Spans the half-open octave `[1, 2)`; 2/1 appears on the pad
    /// as the ghost of 1/1. Degrees are named in sargam (`S r R g G m M P
    /// d D n N`) — the names every fret, drone button and Strings row
    /// shows. **Must stay in step with the bundled `TarabdaarMac/
    /// Default.json`**, which is what actually loads; this is the fallback.
    public static var defaultJI: PitchScale {
        // (numerator, denominator, "black key" flag, label)
        let entries: [(Int, Int, Bool, String)] = [
            (1, 1, false, "S"),      // C   — tonic
            (16, 15, true, "r"),     // C#
            (9, 8, false, "R"),      // D
            (6, 5, true, "g"),       // D#
            (5, 4, false, "G"),      // E
            (4, 3, false, "m"),      // F
            (45, 32, true, "M"),     // F# — tritone
            (3, 2, false, "P"),      // G
            (8, 5, true, "d"),       // G#
            (5, 3, false, "D"),      // A
            (16, 9, true, "n"),      // A#
            (15, 8, false, "N"),     // B
        ]
        let whiteY = 5.0 / 6.0
        let blackY = 2.0 / 6.0
        let pts = entries.map { (n, d, black, label) in
            PitchPoint(num: n, den: d, y: black ? blackY : whiteY, label: label)
        }
        return PitchScale(points: pts)
    }
}

// MARK: - Fraction helpers

func gcd(_ a: Int, _ b: Int) -> Int {
    var (a, b) = (abs(a), abs(b))
    while b != 0 { (a, b) = (b, a % b) }
    return a
}

/// Tenney height = num * den in lowest terms. Alternate metric; the pad
/// uses `complexity(num:den:)`.
func tenneyHeight(num: Int, den: Int) -> Int {
    let g = gcd(num, den)
    return (num / g) * (den / g)
}

/// Ω(n): prime factors counted with multiplicity.
func omega(_ n: Int) -> Int {
    var n = abs(n)
    if n <= 1 { return 0 }
    var count = 0
    var d = 2
    while d * d <= n {
        while n % d == 0 {
            count += 1
            n /= d
        }
        d += 1
    }
    if n > 1 { count += 1 }
    return count
}

/// Pad complexity score (smaller = simpler), in lowest terms:
///   Ω(num) + Ω(den) + largestPrimeFactor(num) + largestPrimeFactor(den)
/// e.g. 1/1 = 2, 3/2 = 7, 4/3 = 8, 9/8 = 5/4 = 10, 45/32 = 15.
public func complexity(num: Int, den: Int) -> Int {
    let g = gcd(num, den)
    let n = num / g
    let d = den / g
    return omega(n) + omega(d) + largestPrimeFactor(n) + largestPrimeFactor(d)
}

/// Largest prime factor of `n` (1 for `|n| ≤ 1`); trial division.
func largestPrimeFactor(_ n: Int) -> Int {
    var n = abs(n)
    if n <= 1 { return 1 }
    var largest = 1
    var d = 2
    while d * d <= n {
        while n % d == 0 {
            largest = d
            n /= d
        }
        d += 1
    }
    if n > 1 { largest = n }
    return largest
}

/// The prime limit of `num/den` in lowest terms.
func largestPrime(num: Int, den: Int) -> Int {
    let g = gcd(num, den)
    return max(largestPrimeFactor(num / g), largestPrimeFactor(den / g))
}

/// Primes ≤ 31 — covers every value the Prime picker exposes.
private let smallPrimes: [Int] = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31]

/// All `primes`-smooth positive integers ≤ `limit`, ascending
/// (breadth-first frontier expansion; no Ω cap).
func smoothNumbersUpTo(_ limit: Int, primes: [Int]) -> [Int] {
    guard !primes.isEmpty else { return [1] }
    var all: Set<Int> = [1]
    var frontier: Set<Int> = [1]
    while !frontier.isEmpty {
        var next: Set<Int> = []
        for x in frontier {
            for p in primes {
                let v = x * p
                if v <= limit && !all.contains(v) {
                    next.insert(v)
                }
            }
        }
        all.formUnion(next)
        frontier = next
    }
    return all.sorted()
}

/// All coprime `maxPrime`-smooth fractions n/d in [1, 2], with pairs
/// closer than 10 cents collapsed to the simpler one
/// (`complexity(num:den:)`). Expensive — callers cache the result
/// (`PitchPadEngine.snapTargets()`).
func simpleFractions(maxPrime: Int) -> [(num: Int, den: Int)] {
    let primes = smallPrimes.filter { $0 <= maxPrime }
    // High enough that the gridline set is full for every prime limit
    // the picker exposes.
    let valueCap = 8192
    let nums = smoothNumbersUpTo(valueCap, primes: primes)

    // Every coprime (n, d) with both smooth and 1 ≤ n/d ≤ 2.
    var entries: [(num: Int, den: Int, logRatio: Double, cx: Int)] = []
    for d in nums {
        let hi = 2 * d
        for n in nums {
            if n < d { continue }
            if n > hi { break }
            if gcd(n, d) != 1 { continue }
            entries.append((n, d,
                            log2(Double(n) / Double(d)),
                            complexity(num: n, den: d)))
        }
    }
    entries.sort { $0.logRatio < $1.logRatio }

    // Collapse within-10-cent neighborhoods to the simplest fraction.
    let tolLog = 10.0 / 1200.0  // 10 cents in log2-octave units
    var deduped: [(num: Int, den: Int)] = []
    var lastLog: Double = -.infinity
    var lastCx: Int = .max
    for e in entries {
        if e.logRatio - lastLog < tolLog {
            if e.cx < lastCx {
                deduped.removeLast()
                deduped.append((e.num, e.den))
                lastLog = e.logRatio
                lastCx = e.cx
            }
        } else {
            deduped.append((e.num, e.den))
            lastLog = e.logRatio
            lastCx = e.cx
        }
    }
    return deduped
}

// MARK: - Best-fraction approximation

/// Best rational approximation of `x` with denominator ≤ `maxDen`
/// (continued fractions) — a clean fraction for a shift-clicked spot.
public func bestFraction(_ x: Double, maxDen: Int = 256) -> (num: Int, den: Int) {
    guard x.isFinite, x > 0 else { return (1, 1) }
    // Continued-fraction expansion with denominator cap.
    var (h1, h0) = (1, 0)
    var (k1, k0) = (0, 1)
    var b = x
    for _ in 0..<32 {
        let a = Int(b.rounded(.down))
        let h2 = a * h1 + h0
        let k2 = a * k1 + k0
        if k2 > maxDen { break }
        (h0, h1) = (h1, h2)
        (k0, k1) = (k1, k2)
        let frac = b - Double(a)
        if frac < 1e-9 { break }
        b = 1.0 / frac
    }
    return (max(1, h1), max(1, k1))
}

/// Fold a positive fraction into the half-open octave `[1, 2)` and
/// reduce to lowest terms — the same pitch class.
public func octaveFolded(num: Int, den: Int) -> (num: Int, den: Int) {
    guard num > 0, den > 0 else { return (1, 1) }
    var n = num, d = den
    while n >= 2 * d { d *= 2 }   // ratio ≥ 2 → halve
    while n < d { n *= 2 }        // ratio < 1 → double
    let g = gcd(n, d)
    return (n / g, d / g)
}

// MARK: - SoundingState

/// The fast-changing "what's playing" state, kept apart from
/// `PitchPadEngine` so per-tick glide updates re-render only the Hz
/// readout and the cell fills.
public final class SoundingState: ObservableObject {
    /// Ratio of the touch that updated last; `nil` when silent.
    @Published public var ratio: Double? = nil
    /// Per-seed cell-fill weights (`DisplaySeed.id` → weight, summing to
    /// 1); empty when silent.
    @Published public var weights: [String: Double] = [:]
    /// The ONSET-captured octave shift (semitones) of the touch that
    /// updated `ratio` last, so the Hz readout shows the sounding pitch.
    @Published public var octaveSemis: Double = 0

    public init() {}
}

// MARK: - PitchPadEngine

/// The pad's playing model: the scale, the tonic, the octave shift, the
/// chord selection and the touch API. Touches are written as
/// full-resolution fractional-MIDI pitch into an `OutboundPlayState` — on
/// the Mac pumped in-process into `LinkIngest`, on the iPad serialized to
/// the wire by `TarabLink`. No MIDI vocabulary; CoreMIDI is never touched.
public final class PitchPadEngine: ObservableObject {
    /// The active scale, seeded from the bundled `Default.json` (fallback
    /// `PitchScale.defaultJI`).
    @Published public var scale: PitchScale = ScaleStore.loadDefault() {
        didSet {
            // Clear a chord selection whose degree the new scale lacks.
            if let sel = chordSelection,
               sel.degree >= scaleDegrees(from: scale).count {
                setChordSelection(nil)
            }
        }
    }
    /// Name of the loaded user scale; `nil` = the default or an unsaved
    /// working scale ("Save" then routes to "Save As…").
    @Published public var currentScaleName: String? = nil
    /// The tonic's integer note anchor. Not persisted — every launch opens
    /// on `defaultTonicMidi` (D4) and the session tonic is set from the
    /// Fret Pad tab.
    @Published public var tonicMidi: Int = PitchPadEngine.defaultTonicMidi
    /// Fractional tonic refinement in CENTS (±50) on `tonicMidi`; together
    /// they are THE app tonic, set in Hz from the Fret Pad tab and
    /// mirrored everywhere (tarab, drones, iPad sync).
    @Published public var tonicCents: Double = 0

    /// The tonic as an absolute frequency — the ONE Hz value everything
    /// else is relative to.
    public var tonicHz: Double {
        440.0 * pow(2.0, (tonicFractionalMidi - 69.0) / 12.0)
    }

    /// Set the tonic from a frequency.
    public func setTonic(hz: Double) {
        guard hz > 20, hz < 4000 else { return }
        setTonic(fractionalMidi: 69.0 + 12.0 * log2(hz / 440.0))
    }

    /// Set the tonic from a fractional MIDI note: integer anchor + ±50¢
    /// remainder (the range the sync blob encodes).
    public func setTonic(fractionalMidi: Double) {
        let clamped = max(Double(Self.tonicNoteRange.lowerBound),
                          min(Double(Self.tonicNoteRange.upperBound), fractionalMidi))
        let note = Int(clamped.rounded())
        tonicMidi = note
        tonicCents = (clamped - Double(note)) * 100.0
    }

    /// Set the integer note anchor, KEEPING the cents offset (the Fret
    /// Pad's note menu).
    public func setTonic(midi: Int) {
        tonicMidi = max(Self.tonicNoteRange.lowerBound,
                        min(Self.tonicNoteRange.upperBound, midi))
    }

    /// The MIDI notes the tonic anchor may take (C1…B7).
    public static let tonicNoteRange = 24...107

    /// The tonic every launch opens on: **D4** (293.665 Hz).
    public static let defaultTonicMidi = 62

    public var tonicFractionalMidi: Double { Double(tonicMidi) + tonicCents / 100.0 }

    /// Playing-range octave shift, ±3 (Joy-Con dpad on the Mac; relayed
    /// to the iPad as the JOYCON_STATE `octave` byte). Applied at the ONE
    /// outbound-pitch point (`noteOn`/`glide`) and ONSET-CAPTURED per
    /// touch: a note keeps its birth shift through every glide, only the
    /// NEXT onset takes the new range. Drones and the tarab never shift.
    /// Not persisted.
    @Published public var octaveShift: Int = 0 {
        didSet {
            let c = min(max(octaveShift, Self.octaveShiftRange.lowerBound),
                        Self.octaveShiftRange.upperBound)
            if c != octaveShift { octaveShift = c }
        }
    }
    public static let octaveShiftRange = -3...3
    /// The shift as a fractional-MIDI offset.
    public var octaveShiftSemis: Double { Double(octaveShift) * 12.0 }

    @Published public var velocity: Int = 92
    /// Half-width (px) of the soft interpolation zone around each cell
    /// boundary — the toolbar's Margin slider.
    @Published public var marginPixels: Double = 16
    /// Hides the pad's editing chrome (control discs, octave lines);
    /// editing gestures still work.
    @Published public var performanceMode: Bool = false
    /// Which playing surface the iPad shows, pushed from the Mac via the
    /// synced state. Unused on the Mac.
    @Published public var layout: PadLayout = .pitchPad
    public let sounding = SoundingState()
    /// Prime-limit filter for snap targets (5 = classical 5-limit JI).
    /// Changing it invalidates the snap-targets cache.
    @Published public var primeLimit: Int = 5 {
        didSet {
            if oldValue != primeLimit { snapTargetsCache = nil }
        }
    }

    private var snapTargetsCache: [(num: Int, den: Int)]? = nil

    /// Memoized `simpleFractions(maxPrime:)` for the current `primeLimit`,
    /// without 2/1 (the scale spans `[1, 2)`).
    public func snapTargets() -> [(num: Int, den: Int)] {
        if let c = snapTargetsCache { return c }
        let computed = simpleFractions(maxPrime: primeLimit).filter {
            Double($0.num) / Double($0.den) < 2.0
        }
        snapTargetsCache = computed
        return computed
    }

    /// The outbound snapshot this pad writes into: on the iPad the
    /// app-wide state `TarabLink` serializes; on the Mac the pad's own,
    /// pumped synchronously into the local `LinkIngest`.
    private let playState: OutboundPlayState
    private weak var audio: AudioEngine?
    /// Mac in-process lane (nil on iPad).
    private let localPump: LocalLinkPump?

    /// The local lane's ingest (nil on iPad) — where the Mac hangs its
    /// `.fingerAccel` taps so local pads drive the dimension like the wire.
    public var localIngest: LinkIngest? { localPump?.ingest }

    /// Fired on `panic()` so the iPad owner can send the reliable PANIC
    /// event (nil on the Mac).
    public var onPanic: (() -> Void)?

    /// Per-touch ratio; `sounding.ratio` is display-only.
    private var currentRatio: [Int: Double] = [:]
    /// Per-touch cell-fill weights; `sounding.weights` is the per-seed max
    /// across them, so every finger's cell stays lit.
    private var touchWeights: [Int: [String: Double]] = [:]
    /// Per-touch octave shift (semitones) CAPTURED at onset — glides replay
    /// it, never the live `octaveShiftSemis`.
    private var touchOctaveSemis: [Int: Double] = [:]

    /// Mac path: the pad drives the local `AudioEngine` through its own
    /// `OutboundPlayState` → `LinkIngest` pump — the wire's frame-diff path,
    /// in-process. Coexists with a linked iPad (distinct id namespaces).
    public init(audio: AudioEngine) {
        self.audio = audio
        let state = OutboundPlayState()
        self.playState = state
        self.localPump = LocalLinkPump(state: state,
                                       ingest: LinkIngest(sink: audio))
    }

    /// iPad path: writes into the app-wide `OutboundPlayState` that
    /// `TarabLink` paces onto the wire. No local audio.
    public init(state: OutboundPlayState) {
        self.audio = nil
        self.playState = state
        self.localPump = nil
    }

    /// The performance-expression level the Mac pads hold (0–127, applied
    /// in `start()`) — the pads have no tilt source, so the axis is pinned.
    public var macExpressionLevel: UInt8 = 100

    public func start() {
        audio?.setPerformanceExpression(Double(macExpressionLevel) / 127.0)
    }

    // MARK: - Touch API

    /// Begin a note at `ratio` above the tonic; `noteOff` must reuse the
    /// caller's `touchId`. The pitch enters the outbound state as
    /// fractional MIDI (`tonicFractionalMidi + octave + 12·log2(ratio)`).
    /// `velocity01`: onset strike velocity (nil = the flat `velocity`).
    /// `radiusPt`: the fingertip's `UITouch.majorRadius` in points
    /// (0 = unknown — the Mac pads have no touchscreen).
    /// `octaveShifted: false` exempts the note from the octave shift (the
    /// strum chord). `exprScale` (1 = neutral) and `glideExempt` are the
    /// strum chord's in-process expression and glide-queue exemption.
    public func noteOn(touchId: Int, ratio: Double,
                       weights: [String: Double] = [:],
                       velocity01: Double? = nil,
                       radiusPt: Double = 0,
                       octaveShifted: Bool = true,
                       exprScale: Double = 1.0,
                       glideExempt: Bool = false) {
        let r = clampRatio(ratio)
        currentRatio[touchId] = r
        touchWeights[touchId] = weights
        // Captured for the touch's whole life — glides replay it.
        let octSemis = octaveShifted ? octaveShiftSemis : 0
        touchOctaveSemis[touchId] = octSemis
        let pitchSemis = tonicFractionalMidi + octSemis + 12.0 * log2(r)
        playState.touchOn(touchId, pitchSemis: pitchSemis,
                          velocity: velocity01 ?? Double(velocity) / 127.0,
                          radiusPt: radiusPt,
                          exprScale: exprScale, glideExempt: glideExempt)
        sounding.ratio = r
        sounding.octaveSemis = octSemis
        refreshSoundingWeights()
    }

    /// Live expression update for a held note (the strum chord's swell);
    /// in-process only.
    public func setTouchExpr(touchId: Int, exprScale: Double) {
        guard currentRatio[touchId] != nil else { return }
        playState.touchExpr(touchId, exprScale)
    }

    /// Fingertip-size update for a held note (points) — the flatten
    /// detector's feed; change-gated on the wire byte downstream.
    public func setTouchRadius(touchId: Int, radiusPt: Double) {
        guard currentRatio[touchId] != nil else { return }
        playState.touchRadius(touchId, radiusPt: radiusPt)
    }

    /// Published fill weights = the per-seed max across active touches.
    private func refreshSoundingWeights() {
        var merged: [String: Double] = [:]
        for w in touchWeights.values {
            for (id, weight) in w where weight > 0 {
                if weight > (merged[id] ?? 0) { merged[id] = weight }
            }
        }
        if merged != sounding.weights { sounding.weights = merged }
    }

    /// Glide a held note to a new ratio: a change-gated pitch write into
    /// the outbound state. The Mac ramps to each update within one render
    /// block — meend IS the finger's trajectory — and the wire carries at
    /// most one fresh frame per sender tick.
    public func glide(touchId: Int, ratio: Double,
                      weights: [String: Double]? = nil) {
        guard currentRatio[touchId] != nil else { return }
        let r = clampRatio(ratio)
        currentRatio[touchId] = r
        if let weights, touchWeights[touchId] != weights {
            touchWeights[touchId] = weights
            refreshSoundingWeights()
        }
        // The ONSET-captured shift, never the live one.
        let octSemis = touchOctaveSemis[touchId] ?? octaveShiftSemis
        playState.touchGlide(touchId,
                             pitchSemis: tonicFractionalMidi + octSemis
                                 + 12.0 * log2(r))
        sounding.ratio = r
        sounding.octaveSemis = octSemis
    }

    public func noteOff(touchId: Int) {
        currentRatio.removeValue(forKey: touchId)
        touchWeights.removeValue(forKey: touchId)
        touchOctaveSemis.removeValue(forKey: touchId)
        playState.touchOff(touchId)
        if currentRatio.isEmpty {
            sounding.ratio = nil
            sounding.weights = [:]
        } else {
            refreshSoundingWeights()
        }
    }

    /// Drone button `index` (0–2) press/release: a held-state bit in the
    /// outbound frame (latest-wins, stuck-drone safe by construction).
    public func setDrone(_ index: Int, pressed: Bool) {
        playState.setDrone(index, pressed)
    }

    // MARK: - Chord bar

    /// This surface's active strum chord (the chord bar). Rides the
    /// outbound frame as held state; the Mac acts on the change edges
    /// (`LinkIngest.onChordSelect`). Not persisted.
    @Published public private(set) var chordSelection: ChordSelection?

    /// Set (or clear, with nil) the chord selection outright.
    public func setChordSelection(_ sel: ChordSelection?) {
        if chordSelection != sel { chordSelection = sel }
        playState.setChordSelection(sel)
    }

    /// The tap gesture: a cell of the selected DEGREE deselects, any other
    /// selects. Octave-agnostic — the octave normalizes to 0 (the Shepard
    /// register law in `shepardChordNotes` fixes the sounding register).
    public func toggleChordSelection(_ sel: ChordSelection) {
        setChordSelection(chordSelection?.degree == sel.degree
            ? nil : ChordSelection(degree: sel.degree, octave: 0))
    }

    /// The user-facing PANIC: clears everything held AND fires `onPanic`.
    public func panic() {
        stopSoundingTouches()
        onPanic?()
    }

    /// Internal all-off for scale/layout/preset swaps: clears held touches
    /// WITHOUT the wire event. A scale application must never broadcast a
    /// panic — the far side would kill its own unrelated notes.
    public func stopSoundingTouches() {
        playState.clearAll()
        currentRatio.removeAll()
        touchWeights.removeAll()
        touchOctaveSemis.removeAll()
        sounding.ratio = nil
        sounding.weights = [:]
    }

    // MARK: - Scale save / load

    /// Persist the current scale under `name`; no-op on a write failure.
    public func saveScale(name: String) {
        guard (try? ScaleStore.save(scale, name: name)) != nil else { return }
        currentScaleName = name
    }

    /// Load the saved scale `name`, stopping sounding touches first (a
    /// note on a vanished cell would be stranded).
    public func loadScale(name: String) {
        guard let loaded = try? ScaleStore.load(name: name) else { return }
        stopSoundingTouches()
        scale = loaded
        currentScaleName = name
    }

    /// Delete a saved scale; the in-memory scale stays but loses its name.
    public func deleteScale(name: String) {
        try? ScaleStore.delete(name: name)
        if currentScaleName == name { currentScaleName = nil }
    }

    /// Apply state pushed from the Mac (iPad sync). Stops sounding touches
    /// when the cells change. Persistence is the receiver's job.
    public func applySyncedState(_ state: SyncedScaleState) {
        if state.scale != scale || state.layout != layout { stopSoundingTouches() }
        scale = state.scale
        tonicMidi = state.tonicMidi
        tonicCents = state.tonicCents
        marginPixels = state.marginPixels
        layout = state.layout
        currentScaleName = nil
    }

    /// Load a built-in scale preset as an unsaved working scale.
    public func loadPreset(_ preset: ScalePreset) {
        stopSoundingTouches()
        scale = preset.pitchScale
        currentScaleName = nil
    }

    /// Reload the bundled default, discarding the working scale.
    public func resetToDefault() {
        stopSoundingTouches()
        scale = ScaleStore.loadDefault()
        currentScaleName = nil
    }

    // MARK: - Internals

    /// Safety clamp, ±5 octaves: the Mac keyboard player ribbons several
    /// octaves out; nonsense is still rejected.
    private func clampRatio(_ r: Double) -> Double {
        if !r.isFinite { return 1.0 }
        return max(1.0 / 32.0, min(32.0, r))
    }
}
