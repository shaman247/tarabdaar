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

    /// Equality is CONTENT equality — `id` is UI identity (ForEach), not
    /// pitch identity, and every sync-blob decode mints fresh UUIDs. With
    /// the synthesized `==` a re-pushed identical scale compared unequal,
    /// so `applySyncedState` panicked on EVERY push — invisible while
    /// panic was a local note-clear, catastrophic once it became a wire
    /// event (the 2026-08-14 staccato loop).
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
    ///
    /// Degrees are named in **sargam** (`S r R g G m M P d D n N`,
    /// 2026-07-25) — and since every pitch in the app is named by the scale
    /// (see `ScaleDegrees.swift`), those are the names the frets, the drone
    /// buttons and the Strings tab show. **Must stay in step with the bundled
    /// `TarabdaarMac/Default.json`**, which is what actually loads; this is
    /// the fallback for a missing/unreadable resource.
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
    /// The ONSET-captured octave shift (semitones) of whichever touch
    /// updated `ratio` last — the readouts add it so the displayed Hz is
    /// the pitch actually sounding, even for a note held across an
    /// octave step (the live `octaveShift` may already differ).
    @Published public var octaveSemis: Double = 0

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
    @Published public var scale: PitchScale = ScaleStore.loadDefault() {
        didSet {
            // A chord-bar selection referencing a degree the new scale no
            // longer has is cleared (a smaller-or-equal scale keeps it —
            // the chord itself re-derives from the new degrees).
            if let sel = chordSelection,
               sel.degree >= scaleDegrees(from: scale).count {
                setChordSelection(nil)
            }
        }
    }
    /// Name of the currently-loaded user scale, shown in the toolbar's
    /// Scale menu. `nil` means the default or an unsaved working scale —
    /// "Save" then routes to "Save As…" since there's no name to
    /// overwrite.
    @Published public var currentScaleName: String? = nil
    /// The tonic's integer note anchor — the "1/1". ALWAYS starts at
    /// `defaultTonicMidi` (D4): the tonic is not persisted on either side, so
    /// every launch opens on D4 and the session tonic is set fresh from the
    /// Fret Pad tab.
    @Published public var tonicMidi: Int = PitchPadEngine.defaultTonicMidi
    /// Fractional tonic refinement in CENTS (±50) on top of `tonicMidi` —
    /// together they are THE app tonic, set in Hz from the Fret Pad tab
    /// (`setTonic(hz:)`) and mirrored everywhere else (tarab, drones, iPad
    /// sync). Kept split (note + cents) so the MIDI/sync plumbing keeps its
    /// integer note anchor.
    @Published public var tonicCents: Double = 0

    /// The tonic as an absolute frequency — the ONE Hz value everything
    /// else is relative to.
    public var tonicHz: Double {
        440.0 * pow(2.0, (tonicFractionalMidi - 69.0) / 12.0)
    }

    /// Set the tonic from a frequency: nearest MIDI note + cents remainder.
    public func setTonic(hz: Double) {
        guard hz > 20, hz < 4000 else { return }
        setTonic(fractionalMidi: 69.0 + 12.0 * log2(hz / 440.0))
    }

    /// Set the tonic from a fractional MIDI note, re-split into the integer
    /// anchor + a ±50¢ remainder (the range the sync blob encodes).
    public func setTonic(fractionalMidi: Double) {
        let clamped = max(Double(Self.tonicNoteRange.lowerBound),
                          min(Double(Self.tonicNoteRange.upperBound), fractionalMidi))
        let note = Int(clamped.rounded())
        tonicMidi = note
        tonicCents = (clamped - Double(note)) * 100.0
    }

    /// Set the tonic's integer note anchor, KEEPING the current cents offset —
    /// so a fine tuning (e.g. −14¢ against a reference) survives picking a
    /// different note. Used by the Fret Pad's note menu.
    public func setTonic(midi: Int) {
        tonicMidi = max(Self.tonicNoteRange.lowerBound,
                        min(Self.tonicNoteRange.upperBound, midi))
    }

    /// The MIDI notes the tonic anchor may take — whole octaves, C1…B7.
    /// Bounds both the typed Hz and the Fret Pad's note menu.
    public static let tonicNoteRange = 24...107

    /// The tonic every launch opens on: **D4** (293.665 Hz).
    public static let defaultTonicMidi = 62

    public var tonicFractionalMidi: Double { Double(tonicMidi) + tonicCents / 100.0 }

    /// PLAYING-RANGE OCTAVE SHIFT (2026-08-27): whole-octave transpose of
    /// every played touch, ±3 (Joy-Con dpad ←/→ on the Mac; relayed to
    /// the iPad as the JOYCON_STATE `octave` byte, TLP v11). Applied at
    /// the ONE outbound-pitch point (`noteOn`/`glide`), so the fret
    /// field, snapping and drag assist are untouched — and it is
    /// **ONSET-CAPTURED per touch (2026-08-28)**: a note keeps the shift
    /// it was born with for its whole life, glides included, so stepping
    /// the octave mid-phrase never yanks a sounding note; only the NEXT
    /// onset takes the new range (the attack-family rule, not the
    /// fieldWarp live rule). Drones and the tarab are degree-resolved
    /// elsewhere and never shift. Not persisted — like the tonic, every
    /// launch opens at 0.
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

    /// The outbound performance snapshot this pad writes into. On the iPad
    /// it is the app-wide state the TarabLink paced sender serializes; on
    /// the Mac each pad owns one, pumped synchronously into the local
    /// `LinkIngest` (`LocalLinkPump`) — one emission path on both
    /// platforms, no MIDI vocabulary anywhere.
    private let playState: OutboundPlayState
    private weak var audio: AudioEngine?
    /// Mac in-process lane (nil on iPad).
    private let localPump: LocalLinkPump?

    /// The local lane's ingest (nil on iPad) — where the Mac hangs the
    /// `.fingerAccel` control taps so local pads and audition scores
    /// drive the dimension exactly like the wire does.
    public var localIngest: LinkIngest? { localPump?.ingest }

    /// Fired on `panic()` so the iPad owner can send the reliable PANIC
    /// event alongside the cleared state (nil on the Mac).
    public var onPanic: (() -> Void)?

    /// Per-touch frequency ratio (touchId → ratio). Each finger keeps its
    /// own pitch; `sounding.ratio` is display-only and reflects whichever
    /// touch updated last.
    private var currentRatio: [Int: Double] = [:]
    /// Per-touch cell-fill weights (touchId → seed-id → weight). The
    /// published `sounding.weights` is the per-seed **max** across these, so
    /// every active finger's cell stays lit simultaneously (polyphonic
    /// fills, no flicker).
    private var touchWeights: [Int: [String: Double]] = [:]
    /// Per-touch octave shift in semitones, CAPTURED at onset — glides
    /// replay this, never the live `octaveShiftSemis`, so a mid-hold
    /// octave step can't jump a sounding note (0 for exempt notes).
    private var touchOctaveSemis: [Int: Double] = [:]

    /// Mac path: the pad drives the local `AudioEngine` through its own
    /// `OutboundPlayState` → `LinkIngest` pump — the same frame-diff path
    /// the iPad wire uses, delivered synchronously in-process. Coexists
    /// with a linked iPad (distinct wire-id namespaces).
    public init(audio: AudioEngine) {
        self.audio = audio
        let state = OutboundPlayState()
        self.playState = state
        self.localPump = LocalLinkPump(state: state,
                                       ingest: LinkIngest(sink: audio))
    }

    /// iPad path: the pad writes into the injected app-wide
    /// `OutboundPlayState`; `TarabLink`'s 120 Hz paced sender (off-main)
    /// serializes it to the wire. No local audio, no MIDI.
    public init(state: OutboundPlayState) {
        self.audio = nil
        self.playState = state
        self.localPump = nil
    }

    /// The performance-expression level the Mac pads hold (the old flat
    /// CC11) — the pads have no tilt source, so without this the String
    /// voice idles near its fitted median anyway; kept settable for parity
    /// with the historic behavior. 0–127; applied in `start()`.
    public var macExpressionLevel: UInt8 = 100

    public func start() {
        // Mac only: pin the expression axis (the iPad has no audio here).
        audio?.setPerformanceExpression(Double(macExpressionLevel) / 127.0)
    }

    // MARK: - Touch API

    /// Begin a note. `ratio` is the exact frequency ratio above the
    /// tonic, in [1, 2] (clamped). The touchId namespace is the
    /// caller's; `noteOff(touchId:)` must reuse the same id.
    ///
    /// The pitch goes into the outbound state as FULL-RESOLUTION
    /// fractional MIDI (`tonicFractionalMidi + 12·log2(ratio)`) — no
    /// nearest-semitone pinning, no note+bend split, no MPE channel: the
    /// wire's state frame carries onset and exact pitch atomically.
    /// `velocity01` — per-note ONSET STRIKE VELOCITY 0…1 (2026-08-19: the
    /// iPad's accelerometer estimate; consumed on the Mac by the String
    /// voice's `bow_attack_vel` velocity→sharpness law). nil = the flat
    /// `velocity` constant, the historic behavior.
    /// `octaveShifted: false` exempts the note from the playing-range
    /// octave shift (the Joy-Con strum: its members carry their OWN
    /// octaves, an anchor gesture like the drones). The captured 0
    /// holds through any glide, like every onset-captured shift.
    /// `exprScale` (0…1, default 1 = neutral) — the note's expression
    /// scale (the strum chord's loudness, 2026-08-28); in-process only,
    /// live-updatable through `setTouchExpr` while held.
    /// `glideExempt: true` keeps the note out of the GLIDE QUEUE
    /// (2026-08-31; the strum chord — its members land milliseconds
    /// apart and must never chain into a glissando); in-process only.
    public func noteOn(touchId: Int, ratio: Double,
                       weights: [String: Double] = [:],
                       velocity01: Double? = nil,
                       octaveShifted: Bool = true,
                       exprScale: Double = 1.0,
                       glideExempt: Bool = false) {
        let r = clampRatio(ratio)
        currentRatio[touchId] = r
        touchWeights[touchId] = weights
        // Capture the octave shift for this touch's whole life (glides
        // replay it) — a mid-hold octave step must not move this note.
        let octSemis = octaveShifted ? octaveShiftSemis : 0
        touchOctaveSemis[touchId] = octSemis
        let pitchSemis = tonicFractionalMidi + octSemis + 12.0 * log2(r)
        playState.touchOn(touchId, pitchSemis: pitchSemis,
                          velocity: velocity01 ?? Double(velocity) / 127.0,
                          exprScale: exprScale, glideExempt: glideExempt)
        sounding.ratio = r
        sounding.octaveSemis = octSemis
        refreshSoundingWeights()
    }

    /// Live expression-scale update for a held note (the strum chord's
    /// swell) — a change-gated write into the outbound state, delivered
    /// like a glide (in-process; the wire carries no expression).
    public func setTouchExpr(touchId: Int, exprScale: Double) {
        guard currentRatio[touchId] != nil else { return }
        playState.touchExpr(touchId, exprScale)
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

    /// Glide an already-held note to a new ratio. Just a pitch write into
    /// the outbound state (change-gated inside) — the Mac ramps to each
    /// update within one render block (no meend smoother since
    /// 2026-08-24: meend IS the finger's trajectory), and the wire
    /// carries at most one fresh frame per sender tick regardless of how
    /// fast the finger reports.
    public func glide(touchId: Int, ratio: Double,
                      weights: [String: Double]? = nil) {
        guard currentRatio[touchId] != nil else { return }
        let r = clampRatio(ratio)
        currentRatio[touchId] = r
        // Update this touch's fill weights independently of the pitch, so
        // every active finger's cell stays lit (no flicker when fingers
        // take turns updating).
        if let weights, touchWeights[touchId] != weights {
            touchWeights[touchId] = weights
            refreshSoundingWeights()
        }
        // The ONSET-captured shift, never the live one — a glide is the
        // same note continuing, so it stays in its birth octave.
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

    /// Drone button `index` (0–2) press/release (Fret Pad): a held-state
    /// bit in the outbound frame — on the Mac the local pump diffs it into
    /// `AudioEngine.setDronePressed`, on the iPad it rides the state frame
    /// (latest-wins, stuck-drone safe by construction).
    public func setDrone(_ index: Int, pressed: Bool) {
        playState.setDrone(index, pressed)
    }

    // MARK: - Chord bar (2026-08-28)

    /// THIS surface's active strum chord (the chord bar below the fret
    /// band) — what its own cells highlight. Rides the outbound frame as
    /// held state (TLP v12); the Mac side consumes the change edges
    /// (`LinkIngest.onChordSelect`) into the strum. Performance state:
    /// not persisted, cleared implicitly at launch.
    @Published public private(set) var chordSelection: ChordSelection?

    /// Set (or clear, with nil) the chord selection outright.
    public func setChordSelection(_ sel: ChordSelection?) {
        if chordSelection != sel { chordSelection = sel }
        playState.setChordSelection(sel)
    }

    /// The tap gesture: tapping any cell of the selected DEGREE deselects
    /// it, any other cell selects that chord. Octave-agnostic
    /// (2026-08-30): chords are pitch-class objects — the tapped cell's
    /// octave normalizes to 0 (the Shepard register law fixes the
    /// sounding register; see `shepardChordNotes`).
    public func toggleChordSelection(_ sel: ChordSelection) {
        setChordSelection(chordSelection?.degree == sel.degree
            ? nil : ChordSelection(degree: sel.degree, octave: 0))
    }

    /// The user-facing PANIC (buttons): clears everything held AND fires
    /// the reliable wire panic event via `onPanic`.
    public func panic() {
        stopSoundingTouches()
        onPanic?()
    }

    /// Internal all-off for scale/layout/preset swaps: clears held touches
    /// WITHOUT the wire event. A scale application must never broadcast a
    /// panic — the far side would kill its own unrelated notes (the
    /// 2026-08-14 staccato loop's second leg).
    public func stopSoundingTouches() {
        playState.clearAll()
        currentRatio.removeAll()
        touchWeights.removeAll()
        touchOctaveSemis.removeAll()
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
        stopSoundingTouches()
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
        if state.scale != scale || state.layout != layout { stopSoundingTouches() }
        scale = state.scale
        tonicMidi = state.tonicMidi
        tonicCents = state.tonicCents
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

    /// Clamp to a safety range. The octave-extended pad only reaches
    /// `[2^-0.5, 2^1.5]`, but the Mac computer-keyboard player
    /// (`KeyboardNotePlayer`) ribbons several octaves out, so the bound is
    /// a generous ±5 octaves — wide enough to never collapse a played key
    /// in practice while still rejecting nonsense. Safe regardless of
    /// width: the played note is pinned to the nearest semitone of `r` and
    /// bent from there, so even an extreme ratio stays inside
    /// `bendRangeSemis` (the bend only ever carries the sub-semitone
    /// residue) and lands on a valid MIDI note number.
    private func clampRatio(_ r: Double) -> Double {
        if !r.isFinite { return 1.0 }
        return max(1.0 / 32.0, min(32.0, r))
    }
}
