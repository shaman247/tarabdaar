import Foundation
import QuartzCore

// MARK: - PitchPoint / PitchScale

/// One pitch in a Pitch-Pad scale. A pitch is an exact frequency ratio
/// over the tonic, stored as `num/den`. `y` is the pitch's vertical
/// position inside the pad rectangle (0..1, arbitrary), used only by
/// the layout — it has no effect on the frequency. `label` is an
/// optional user-facing name (e.g. a scale-degree like `"3-"`); when
/// empty, the ratio string is shown instead.
public struct PitchPoint: Identifiable, Equatable {
    public let id: UUID
    public var num: Int
    public var den: Int
    public var y: Double
    public var label: String
    /// When false the pitch is kept in the scale array (and listed in
    /// the editor's "Disabled" section) but is excluded from the pad —
    /// no cell, no disc, not playable — so a smaller scale can be drawn
    /// from a larger vocabulary and notes toggled back in at will.
    public var enabled: Bool

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
    /// X position inside the rectangle. The rectangle spans one octave,
    /// so `log2(ratio)` lands in [0, 1] for ratios in [1, 2].
    public var xFraction: Double { log2(ratio) }
    /// The ratio rendered as text, e.g. `"3/2"`.
    public var ratioString: String { "\(num)/\(den)" }
    /// What the pad and editor show for this pitch: the custom `label`
    /// if set, otherwise the ratio string.
    public var displayLabel: String { label.isEmpty ? ratioString : label }
}

public struct PitchScale: Equatable {
    public var points: [PitchPoint]

    public init(points: [PitchPoint]) {
        self.points = points
    }

    /// 12-tone just intonation, laid out like a piano: white-key pitch
    /// classes sit low in the pad, black-key pitch classes sit high.
    /// Y-coordinates align with two of the seven command-snap rungs
    /// (`2/6` for black, `5/6` for white) so dragging existing pitches
    /// vertically with command held doesn't nudge them off the
    /// keyboard-like layout. The scale spans the half-open octave
    /// `[1, 2)` — 2/1 is **not** a member; the octave appears on the
    /// pad as the upper-octave repeat (ghost) of 1/1.
    public static var defaultJI: PitchScale {
        // (numerator, denominator, "black key" flag, label)
        let entries: [(Int, Int, Bool, String)] = [
            (1, 1, false, "1"),      // C   — tonic
            (16, 15, true, "2-"),    // C#
            (9, 8, false, "2"),      // D
            (6, 5, true, "3-"),      // D#
            (5, 4, false, "3"),      // E
            (4, 3, false, "4"),      // F
            (45, 32, true, "4+"),    // F# — tritone
            (3, 2, false, "5"),      // G
            (8, 5, true, "6-"),      // G#
            (5, 3, false, "6"),      // A
            (16, 9, true, "7-"),     // A#
            (15, 8, false, "7"),     // B
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

/// Tenney height = num * den (in lowest terms). Lower = simpler in
/// the music-theoretic sense — 3/2 (Tenney 6) is simpler than 45/32
/// (Tenney 1440). Kept around as an alternate metric, but the pad's
/// dedup + gridline height now uses `complexity(num:den:)` below.
func tenneyHeight(num: Int, den: Int) -> Int {
    let g = gcd(num, den)
    return (num / g) * (den / g)
}

/// Count prime factors (with multiplicity), the "big omega" function:
/// Ω(1) = 0, Ω(2·2·3) = 3, Ω(prime) = 1.
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

/// Pad-specific complexity score for a fraction:
///   Ω(num) + Ω(den) + largestPrimeFactor(num) + largestPrimeFactor(den)
///
/// Both halves of the metric pull in the same direction — penalize
/// long factorizations and penalize use of big primes — but they
/// disagree on cases like 5/4 (low Ω, prime 5) vs 9/8 (higher Ω,
/// lower primes), which they're meant to: each emphasis is musically
/// relevant in different ways. Smaller score = simpler.
///   1/1   = 0+0+1+1 = 2     (simplest)
///   2/1   = 1+0+2+1 = 4
///   3/2   = 1+1+3+2 = 7
///   4/3   = 2+1+2+3 = 8
///   9/8   = 2+3+3+2 = 10
///   5/4   = 1+2+5+2 = 10
///   45/32 = 3+5+5+2 = 15
public func complexity(num: Int, den: Int) -> Int {
    let g = gcd(num, den)
    let n = num / g
    let d = den / g
    return omega(n) + omega(d) + largestPrimeFactor(n) + largestPrimeFactor(d)
}

/// Largest prime factor of `n`. Returns 1 for `|n| ≤ 1`. Trial
/// division is fine here — we only call this on numerators /
/// denominators that fit inside our Tenney cap (≤ a few hundred).
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

/// Largest prime appearing in either side of `num/den` (in lowest
/// terms). This is what musicians call the "prime limit" of a JI
/// ratio: 3/2 is 3-limit, 5/4 is 5-limit, 7/4 is 7-limit, etc.
func largestPrime(num: Int, den: Int) -> Int {
    let g = gcd(num, den)
    return max(largestPrimeFactor(num / g), largestPrimeFactor(den / g))
}

/// Primes ≤ 31 — covers every value the Prime picker exposes.
private let smallPrimes: [Int] = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31]

/// All `maxPrime`-smooth positive integers up to `limit`, sorted
/// ascending. Generated by a breadth-first frontier expansion that
/// adds the next layer of products until no new value fits under
/// `limit`. There's no Ω cap — depth grows as far as the value cap
/// allows, so e.g. 1024 = 2¹⁰ shows up if 2 is in `primes` and the
/// limit is ≥ 1024.
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

/// All coprime fractions n/d in [1, 2] (in lowest terms) where both
/// `n` and `d` are `maxPrime`-smooth (each prime factor ≤ maxPrime).
/// Generated up to a value cap rather than an Ω cap, so the
/// frontier keeps expanding "in line with our complexity metric"
/// — higher-Ω numbers appear naturally once a slot needs them.
///
/// Pairs whose log-frequency distance is under 10 cents collapse to
/// the **simpler** of the two — `complexity(num:den:)` score, lower
/// wins. Since higher-Ω candidates always have higher complexity
/// than what's already there, they fill empty 10-cent slots but
/// never displace simpler representatives; the dedup converges as
/// soon as every reachable slot is taken.
///
/// Cost is dominated by the number of `maxPrime`-smooth integers
/// ≤ `valueCap`, so callers should cache the result rather than
/// recompute per frame (see `PitchPadEngine.snapTargets()`).
func simpleFractions(maxPrime: Int) -> [(num: Int, den: Int)] {
    let primes = smallPrimes.filter { $0 <= maxPrime }
    // High enough that the gridline set is "full" for every prime
    // limit the picker exposes — at maxPrime=2 you only get powers
    // of 2 up to 8192 (14 numbers), but the 10-cent dedup is hard-
    // capped by the prime set itself. At maxPrime ≥ 7 the
    // resulting set already fills most of the 120 reachable slots.
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

/// Stern-Brocot best rational approximation of a real value, capped at
/// `maxDen`. Used when the user shift-clicks an arbitrary spot — we
/// pick a clean fraction so the editor list isn't littered with ugly
/// decimals.
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

/// Fold a positive fraction into the half-open octave `[1, 2)` by
/// repeatedly halving (doubling the denominator) while it's ≥ 2 and
/// doubling (doubling the numerator) while it's < 1, then reduce to
/// lowest terms. The result is the same pitch class as `num/den`. Used
/// when the user types a ratio outside the scale's octave.
public func octaveFolded(num: Int, den: Int) -> (num: Int, den: Int) {
    guard num > 0, den > 0 else { return (1, 1) }
    var n = num, d = den
    while n >= 2 * d { d *= 2 }   // ratio ≥ 2 → halve
    while n < d { n *= 2 }        // ratio < 1 → double
    let g = gcd(n, d)
    return (n / g, d / g)
}

// MARK: - SoundingState

/// The fast-changing "what's playing" state for the Pitch Pad, kept
/// apart from `PitchPadEngine` so it can be observed in isolation. A
/// glide updates `ratio` (and the surface updates `weights`) on every
/// mouse tick; routing those through this small object means only the
/// Hz readout and the cell-fill layer re-render at that rate, instead
/// of the entire pad view tree.
public final class SoundingState: ObservableObject {
    /// Frequency ratio of the currently-sounding touch, or `nil` when
    /// the pad is silent.
    @Published public var ratio: Double? = nil
    /// Per-seed cell-fill weights (`DisplaySeed.id` → weight), summing
    /// to 1. A single entry at 1 is an exact pitch; two or three mean a
    /// soft-margin / triple-junction blend. Empty when silent.
    @Published public var weights: [String: Double] = [:]

    public init() {}
}

// MARK: - PitchPadEngine

/// In-process MIDI engine for the Pitch Pad tab. Each active "finger"
/// gets its own MPE channel; the pitch is produced by holding a fixed
/// MIDI note near `tonicMidi` on that channel and bending to the
/// requested ratio. The bend range is set to `Config.midiPitchBendRange`
/// at channel-init time (see `bendRangeSemis`) so a full glide fits
/// inside one bend without retriggering.
///
/// MIDI bytes are routed in-process directly to `AudioEngine` via
/// `MIDIEngine.onLocalEvent`, mirroring `IPadSimulator`. CoreMIDI is
/// **not** touched — this engine never broadcasts to external sources.
public final class PitchPadEngine: ObservableObject {
    /// The active scale. Seeded from the bundled default (`Default.json`,
    /// falling back to the in-code `PitchScale.defaultJI`) so the pad
    /// opens on a scale loaded from disk rather than a hard-coded value.
    @Published public var scale: PitchScale = ScaleStore.loadDefault()
    /// Name of the currently-loaded user scale, shown in the toolbar's
    /// Scale menu. `nil` means the default or an unsaved working scale —
    /// "Save" then routes to "Save As…" since there's no name to
    /// overwrite.
    @Published public var currentScaleName: String? = nil
    @Published public var tonicMidi: Int = 62       // D4 = the "1/1"
    @Published public var velocity: Int = 92
    /// Half-width of the soft interpolation zone around each cell
    /// boundary, in pixels. See `docs/pitch-pad.md` (Inner & outer
    /// polygons) for the geometry. Bound to the **Margin** slider in
    /// the pad toolbar; default 16 px matches the original visual.
    @Published public var marginPixels: Double = 16
    /// Performance mode hides the editing chrome on the pad surface —
    /// the per-pitch control discs and the 1/1 / 2/1 octave boundary
    /// lines — leaving the cell outlines, the black field, and the live
    /// sounding fills. Lets the pad read as a cleaner playing surface
    /// once a scale is dialed in. Toggled from the pad toolbar; editing
    /// gestures (drag a handle, shift-click) still work, they just have
    /// no visible handles to aim at.
    @Published public var performanceMode: Bool = false
    /// Which playing surface the iPad should show, pushed from the Mac via
    /// the synced state. The iPad's `ContentView` observes this to swap
    /// between the Pitch Pad and Chord Pad surfaces. Unused on the Mac.
    @Published public var layout: PadLayout = .pitchPad
    /// High-frequency "what's sounding" state, split out of the engine
    /// into its own observable so that the per-tick updates during a
    /// glide only re-render the two tiny views that show them (the Hz
    /// readout and the cell fills) — not the whole pad. Were these
    /// `@Published` on the engine, every glide tick would re-evaluate
    /// the toolbar's sliders/pickers, all cell borders, and all 12
    /// control discs. `ratio` / `weights` are written by
    /// `noteOn` / `glide` / `noteOff` and the surface's gesture
    /// handlers; see `SoundingState`.
    public let sounding = SoundingState()
    /// Prime-limit filter for snap targets. `5` is classical 5-limit
    /// just intonation (primes 2, 3, 5 only). `7` brings in
    /// septimal ratios like 7/4, 7/5, 7/6. `11`+ enters xenharmonic
    /// territory. Changing this invalidates the snap-targets cache.
    @Published public var primeLimit: Int = 5 {
        didSet {
            if oldValue != primeLimit { snapTargetsCache = nil }
        }
    }

    /// Cached snap fractions for the current `primeLimit`. The
    /// enumeration cost grows quickly (`O(N²)` where N is the count
    /// of `maxOmega`-smooth numbers under `primeLimit`), so we only
    /// recompute when the user moves the prime picker rather than on
    /// every drag-tick render.
    private var snapTargetsCache: [(num: Int, den: Int)]? = nil

    /// Memoized accessor for the current snap-target set. See
    /// `simpleFractions(maxPrime:)` for the underlying rule. 2/1 is
    /// filtered out: the scale spans the half-open octave `[1, 2)`, so
    /// the octave itself isn't a snappable degree (it lives on the pad
    /// as 1/1's upper-octave repeat instead).
    public func snapTargets() -> [(num: Int, den: Int)] {
        if let c = snapTargetsCache { return c }
        let computed = simpleFractions(maxPrime: primeLimit).filter {
            Double($0.num) / Double($0.den) < 2.0
        }
        snapTargetsCache = computed
        return computed
    }

    private let midi: MIDIEngine
    private weak var audio: AudioEngine?
    /// True when this engine created the `MIDIEngine` itself (Mac
    /// in-process path) and is therefore responsible for `start()`ing it.
    /// On iPad the engine is injected and started by the owner
    /// (`ContentView`), so `start()` here is a no-op.
    private let ownsMidi: Bool

    private var touchChannels: [Int: Int] = [:]    // touchId → channel
    private var channelHolders: [Int: Int] = [:]   // channel → touchId
    private var nextChannel: Int = 1
    private var bendRangeSet: Set<Int> = []

    /// Per-touch frequency ratio (touchId → ratio). Each finger keeps its
    /// own pitch; `sounding.ratio` is display-only and reflects whichever
    /// touch updated last, so the expression loop reads pitch from here.
    private var currentRatio: [Int: Double] = [:]
    /// Per-touch cell-fill weights (touchId → seed-id → weight). The
    /// published `sounding.weights` is the per-seed **max** across these, so
    /// every active finger's cell stays lit simultaneously (polyphonic
    /// fills, no flicker).
    private var touchWeights: [Int: [String: Double]] = [:]
    /// Per-touch last ratio a pitch bend was sent for, so the render/bend
    /// skip in `glide` is per-finger rather than keyed on the shared
    /// `sounding.ratio` (which would make one finger suppress another's
    /// bend when their ratios momentarily coincide).
    private var lastBentRatio: [Int: Double] = [:]

    // MARK: - Tilt expression (iPad)

    /// Source of tilt-driven expression: the `NoteManager` that owns the
    /// `DimensionMapping` matrix and samples the device tilt. On the iPad
    /// the pad is the only playing surface; `NoteManager` runs purely as
    /// the mapping brain (its glide/voice MIDI paths stay idle). nil on
    /// the Mac (no tilt source), where the expression loop never runs.
    public weak var expression: NoteManager?

    /// 60 Hz loop that re-sends each held touch's pitch bend (tracking its
    /// position-derived ratio) plus tilt-driven aftertouch / CC. Created
    /// only on the iPad init (`init(midi:)`); the Mac has no tilt source, so
    /// its `glide` sends the bend directly.
    private var expressionTimer: Timer?

    /// Pitch bend range we configure each MPE channel to, in semitones.
    ///
    /// **Must equal `Config.midiPitchBendRange`** — the iPad emits MPE
    /// on the same channel pool and re-asserts that value on every
    /// Note On, and the hosted AU stores one bend-range per channel.
    /// If the two sides disagree, whichever side acted most recently
    /// wins and the loser's bend values get misinterpreted by SWAM
    /// (PitchPad previously used 24 here while the iPad used 48, so
    /// any iPad activity left the channel at 48 → next PitchPad bend
    /// rendered 2× wider than intended).
    private let bendRangeSemis: Double = Config.midiPitchBendRange

    /// Mac path: the engine owns a private `MIDIEngine` that does **not**
    /// publish to CoreMIDI; bytes are delivered in-process to `audio`'s
    /// hosted AU via `onLocalEvent`. Coexists with a plugged-in iPad.
    public init(audio: AudioEngine) {
        self.audio = audio
        self.midi = MIDIEngine(publishToCoreMIDI: false)
        self.ownsMidi = true
        self.macFlatExpression = true
        self.midi.onLocalEvent = { [weak self] bytes in
            self?.deliver(bytes: bytes)
        }
    }

    /// iPad path: the engine emits real MPE through an injected,
    /// already-started `MIDIEngine` (`publishToCoreMIDI: true`) — the
    /// same one the rest of the app uses for USB-MIDI out. No
    /// `onLocalEvent`, no `AudioEngine`. The 60 Hz tilt-expression loop
    /// runs here (the Mac pad has no tilt source, so `init(audio:)`
    /// leaves it off and `glide` sends the bend directly).
    public init(midi: MIDIEngine) {
        self.audio = nil
        self.midi = midi
        self.ownsMidi = false
        self.macFlatExpression = false
        startExpressionLoop()
    }

    /// Mac (`init(audio:)`) has no tilt/accelerometer, so the 60 Hz
    /// expression loop never runs and nothing would send CC11 — leaving the
    /// hosted bowed AU (SWAM Viola) at near-zero expression, i.e. near
    /// SILENT. When `macFlatExpression` is set, every note sends a fixed
    /// CC11 (Expression) so SWAM actually sounds; the sym halo, driven by
    /// SWAM's audio, then has a voice to ring against. Adjustable level
    /// (0–127, default 100 ≈ a firm bow). The iPad path leaves this off and
    /// drives CC11 dynamically from tilt.
    private let macFlatExpression: Bool
    /// CC11 value the Mac pad holds per note. 0–127.
    public var macExpressionLevel: UInt8 = 100

    public func start() {
        if ownsMidi { midi.start() }
    }

    private func deliver(bytes: [UInt8]) {
        guard let audio, bytes.count >= 2 else { return }
        let high = bytes[0] & 0xF0
        if high == 0xD0 {
            audio.sendHostedMIDI2(status: bytes[0], data1: bytes[1])
            return
        }
        guard bytes.count >= 3 else { return }
        audio.sendHostedMIDI(status: bytes[0], data1: bytes[1], data2: bytes[2])
    }

    // MARK: - Touch API

    /// Begin a note. `ratio` is the exact frequency ratio above the
    /// tonic, in [1, 2] (clamped). The touchId namespace is the
    /// caller's; `noteOff(touchId:)` must reuse the same id.
    ///
    /// The MIDI note is pinned at the *closest semitone* to the
    /// requested ratio so SWAM picks the right register for its body
    /// model on the initial attack. From then on, the held note number
    /// stays fixed for the lifetime of this touch — `glide()` only
    /// sweeps the pitch bend. The wide `bendRangeSemis` (one octave +
    /// headroom) lets a touch starting on the tonic glide to the
    /// octave without retriggering on a new note number.
    ///
    /// Ordering matters because the Mac `AudioEngine` only routes a
    /// MIDI channel to a hosted-AU slot when it sees a Note On — pitch
    /// bend on an un-slotted channel is silently dropped. So we (1)
    /// reset controllers on the channel first (CC 121 is broadcast to
    /// every slot, wiping any residual bend left on the AU's internal
    /// channel state from a prior touch that reused this number), then
    /// (2) Note On to allocate the slot, then (3) the pitch bend so it
    /// lands on the just-allocated slot. The bend-range RPN is sent
    /// once per channel on first use — the iPad re-asserts the same
    /// value on the same channel pool, so no further drift is possible.
    public func noteOn(touchId: Int, ratio: Double, weights: [String: Double] = [:]) {
        let r = clampRatio(ratio)
        let channel = allocateChannel()
        touchChannels[touchId] = channel
        channelHolders[channel] = touchId
        currentRatio[touchId] = r
        touchWeights[touchId] = weights
        configureBendRangeIfNeeded(channel: channel)
        let semisAboveTonic = 12.0 * log2(r)
        let fractional = Double(tonicMidi) + semisAboveTonic
        let note = Int(fractional.rounded())
        heldNote[channel] = note
        let bend = bendValue(forSemisFromNote: fractional - Double(note))
        midi.sendControlChange(controller: 121, value: 0, channel: UInt8(channel))
        midi.sendNoteOn(note: UInt8(note), velocity: UInt8(velocity),
                        channel: UInt8(channel))
        midi.sendPitchBend(value: bend, channel: UInt8(channel))
        // Mac has no tilt to drive expression: hold CC11 high (after the
        // Note On, so the channel has an AU slot) or SWAM stays silent.
        if macFlatExpression {
            midi.sendControlChange(controller: 11, value: macExpressionLevel,
                                   channel: UInt8(channel))
        }
        lastBentRatio[touchId] = r
        sounding.ratio = r
        refreshSoundingWeights()
    }

    /// Recompute the published fill weights as the per-seed max across all
    /// active touches, so concurrent fingers each light their own cell.
    private func refreshSoundingWeights() {
        var merged: [String: Double] = [:]
        for w in touchWeights.values {
            for (id, weight) in w where weight > 0 {
                if weight > (merged[id] ?? 0) { merged[id] = weight }
            }
        }
        if merged != sounding.weights { sounding.weights = merged }
    }

    /// Bend an already-held note to a new ratio. Computed against the
    /// note number this touch was pinned to at `noteOn` — the bend
    /// value carries the full delta, so dragging across the pad's
    /// whole octave produces the corresponding ±12-semi sweep instead
    /// of just the tiny fractional residue.
    public func glide(touchId: Int, ratio: Double, weights: [String: Double]? = nil) {
        guard let channel = touchChannels[touchId],
              let note = heldNote[channel] else { return }
        let r = clampRatio(ratio)
        // Record the per-touch ratio first so the expression tick (on
        // iPad) keeps bending the right pitch for *this* finger even when
        // the render-skip below fires.
        currentRatio[touchId] = r
        // Update this touch's fill weights independently of the bend, so
        // every active finger's cell stays lit (no flicker when fingers
        // take turns updating).
        if let weights, touchWeights[touchId] != weights {
            touchWeights[touchId] = weights
            refreshSoundingWeights()
        }
        // Skip the bend when the pitch is unchanged for this touch (e.g.
        // the finger moving within one inner polygon).
        if r == lastBentRatio[touchId] { return }
        lastBentRatio[touchId] = r
        let semisAboveTonic = 12.0 * log2(r)
        let fractional = Double(tonicMidi) + semisAboveTonic
        let bend = bendValue(forSemisFromNote: fractional - Double(note))
        midi.sendPitchBend(value: bend, channel: UInt8(channel))
        sounding.ratio = r
    }

    public func noteOff(touchId: Int) {
        currentRatio.removeValue(forKey: touchId)
        touchWeights.removeValue(forKey: touchId)
        lastBentRatio.removeValue(forKey: touchId)
        guard let channel = touchChannels.removeValue(forKey: touchId) else { return }
        channelHolders.removeValue(forKey: channel)
        let note = heldNote.removeValue(forKey: channel) ?? tonicMidi
        midi.sendNoteOff(note: UInt8(note), channel: UInt8(channel))
        if touchChannels.isEmpty {
            sounding.ratio = nil
            sounding.weights = [:]
        } else {
            refreshSoundingWeights()
        }
    }

    public func panic() {
        for ch in 1...15 {
            midi.sendControlChange(controller: 123, value: 0, channel: UInt8(ch))
        }
        touchChannels.removeAll()
        channelHolders.removeAll()
        heldNote.removeAll()
        currentRatio.removeAll()
        touchWeights.removeAll()
        lastBentRatio.removeAll()
        sounding.ratio = nil
        sounding.weights = [:]
    }

    // MARK: - Scale save / load

    /// Persist the current scale under `name` and mark it as the loaded
    /// scale. Silently no-ops on a write failure (e.g. a bad name); the
    /// in-memory scale is unaffected.
    public func saveScale(name: String) {
        guard (try? ScaleStore.save(scale, name: name)) != nil else { return }
        currentScaleName = name
    }

    /// Replace the active scale with the saved scale `name`. Stops any
    /// sounding touches first — the old scale's seeds are about to
    /// vanish, so leaving a note hanging on a removed cell would strand
    /// it. No-ops if the file can't be read.
    public func loadScale(name: String) {
        guard let loaded = try? ScaleStore.load(name: name) else { return }
        panic()
        scale = loaded
        currentScaleName = name
    }

    /// Delete a saved scale. If it was the loaded one, the in-memory
    /// scale stays put but loses its name (becomes an unsaved working
    /// scale).
    public func deleteScale(name: String) {
        try? ScaleStore.delete(name: name)
        if currentScaleName == name { currentScaleName = nil }
    }

    /// Apply state pushed from the Mac over SysEx (iPad sync): the scale
    /// plus the tonic and margin performance params. Stops any sounding
    /// touches first — the incoming scale's cells replace the old ones, so a
    /// note left on a vanished cell would be stranded — then swaps in the new
    /// values. Persistence is handled by the receiver (`SyncedScaleStore`).
    public func applySyncedState(_ state: SyncedScaleState) {
        // Stop sounding touches when the cells are about to change out from
        // under a held note — either the scale or the playing surface itself.
        if state.scale != scale || state.layout != layout { panic() }
        scale = state.scale
        tonicMidi = state.tonicMidi
        marginPixels = state.marginPixels
        layout = state.layout
        currentScaleName = nil
    }

    /// Load a built-in scale preset (a mode / major-minor / pentatonic) into
    /// the working scale. Shared by the Pitch Pad and Chord Pad — both read
    /// this one `scale`. Stops any sounding touches first (the cells are
    /// about to change) and clears the loaded-scale name (it becomes an
    /// unsaved working scale seeded from the preset).
    public func loadPreset(_ preset: ScalePreset) {
        panic()
        scale = preset.pitchScale
        currentScaleName = nil
    }

    /// Reload the bundled default, discarding the working scale.
    public func resetToDefault() {
        panic()
        scale = ScaleStore.loadDefault()
        currentScaleName = nil
    }

    // MARK: - Internals

    /// Per-channel pinned MIDI note for the active touch. Stays fixed
    /// for the lifetime of the touch; glide is implemented entirely via
    /// pitch bend on the same channel, so SWAM doesn't have to re-
    /// articulate while the cursor crosses cell boundaries.
    private var heldNote: [Int: Int] = [:]

    /// Start the 60 Hz tilt-expression loop (iPad only).
    private func startExpressionLoop() {
        expressionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0,
                                               repeats: true) { [weak self] _ in
            self?.expressionTick()
        }
    }

    /// Per-tick expression update (iPad). For every held touch it re-sends a
    /// pitch bend tracking the touch's position-derived ratio, plus channel
    /// pressure (aftertouch) and any mapped CCs read from the bound
    /// `DimensionMapping`. `noteOn` / `glide` set the per-touch ratio and
    /// emit the base bend; this loop overlays tilt expression at ≤16 ms.
    private func expressionTick() {
        guard !touchChannels.isEmpty else { return }

        // Pad expression is driven by the *global* dimensions (tilts +
        // sliders); per-note dims (keyY/pressure) read their idle value
        // since the pad never activates NoteManager voices.
        func param(_ p: MappableParameter) -> Double {
            expression?.cachedParamValue(for: p) ?? p.midpointValue
        }

        let aftertouchActive = !(expression?.dimensionMapping
            .mapping(for: .aftertouch).bindings.isEmpty ?? true)
        let aftertouchVal: UInt8 = aftertouchActive
            ? UInt8(max(0, min(127, Int(param(.aftertouch))))) : 0
        let ccs = expression?.activeCCs ?? []

        for (touchId, channel) in touchChannels {
            guard let note = heldNote[channel],
                  let r = currentRatio[touchId] else { continue }
            let base = (Double(tonicMidi) + 12.0 * log2(r)) - Double(note)
            let bend = bendValue(forSemisFromNote: base)
            midi.sendPitchBend(value: bend, channel: UInt8(channel))
            if aftertouchActive {
                midi.sendChannelPressure(value: aftertouchVal, channel: UInt8(channel))
            }
            for (cc, paramIdx) in ccs {
                guard let p = MappableParameter(rawValue: paramIdx) else { continue }
                let v = UInt8(max(0, min(127, Int(param(p)))))
                midi.sendControlChange(controller: cc, value: v, channel: UInt8(channel))
            }
        }
    }

    private func bendValue(forSemisFromNote bendSemis: Double) -> UInt16 {
        let unitsPerSemi = 8192.0 / bendRangeSemis
        let raw = 8192.0 + bendSemis * unitsPerSemi
        return UInt16(max(0, min(16383, raw.rounded())))
    }

    private func configureBendRangeIfNeeded(channel: Int) {
        if bendRangeSet.insert(channel).inserted {
            midi.sendPitchBendRange(semitones: UInt8(bendRangeSemis),
                                    channel: UInt8(channel))
        }
    }

    /// Round-robin allocator across MPE member channels 1...15.
    /// Skips channels that are currently holding a note. If every
    /// channel is busy, the oldest one is reused (the prior holder is
    /// released with a Note Off to avoid stuck notes).
    private func allocateChannel() -> Int {
        for _ in 0..<15 {
            let c = nextChannel
            nextChannel = (nextChannel % 15) + 1
            if channelHolders[c] == nil {
                return c
            }
        }
        let c = nextChannel
        nextChannel = (nextChannel % 15) + 1
        if let oldTouch = channelHolders[c] {
            noteOff(touchId: oldTouch)
        }
        return c
    }

    /// Clamp to a safety range wide enough for the octave-extended
    /// pad, which plays ratios in `[2^-0.5, 2^1.5]` (half an octave
    /// below the tonic up to half an octave above the octave). The
    /// bound is a generous full octave on each side; the played note
    /// is pinned to the nearest semitone of `r` and bent from there,
    /// so even an edge-to-edge glide stays inside `bendRangeSemis`.
    private func clampRatio(_ r: Double) -> Double {
        if !r.isFinite { return 1.0 }
        return max(0.5, min(4.0, r))
    }
}
