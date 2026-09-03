import Foundation

/// THE CONTROLLER STRUM — a HELD CHORD sounded as ordinary notes in the
/// MAIN voice (fresh strings, taraf charge, firm strike velocity). Held by
/// the Joy-Con L button and/or the ACCEL TRIGGER (the strike envelope
/// crossing `ctl_strum_thresh`); a press always closes any chord still
/// held; touch ids are GENERATION-scoped so a re-press retriggers.
///
/// What it plays is THE CHORD BAR's active selection (iPad taps arrive as
/// the PERF_STATE chord bytes, Mac taps through the local pump), else the
/// Strings tab's configured strum set; a selection change while ringing
/// RETUNES in place rather than re-attacking. Extracted from
/// `AppController`, which owns the note engine and feeds this the sink.
///
/// Main-queue only, except `accelSense` (called from the link receive
/// queue — it detects the edge there and hops to main, which re-tests).
public final class StrumController {

    /// The note engine, as plain closures (`PitchPadEngine` on the Mac).
    public struct NoteSink {
        public var noteOn: (_ touchId: Int, _ ratio: Double,
                            _ velocity01: Double, _ exprScale: Double) -> Void
        public var noteOff: (_ touchId: Int) -> Void
        public var glide: (_ touchId: Int, _ ratio: Double) -> Void
        public var setExpr: (_ touchId: Int, _ exprScale: Double) -> Void

        public init(
            noteOn: @escaping (Int, Double, Double, Double) -> Void,
            noteOff: @escaping (Int) -> Void,
            glide: @escaping (Int, Double) -> Void,
            setExpr: @escaping (Int, Double) -> Void
        ) {
            self.noteOn = noteOn
            self.noteOff = noteOff
            self.glide = glide
            self.setExpr = setExpr
        }
    }

    /// Distinct touchId namespace on the shared engine (the keyboard
    /// player uses 1_000_000).
    public static let touchBase = 2_000_000

    /// The id for member `index` of generation `gen` — index-deterministic,
    /// so a retune can address the ringing notes.
    public static func touchId(gen: Int, index: Int) -> Int {
        touchBase + (gen % 1024) * 64 + index
    }

    /// What a strum sounds, as (ratio, weight): the active chord under the
    /// SHEPARD REGISTER LAW (`shepardChordNotes` — centered in the octave
    /// below the tonic, raised-cosine weights), else the configured set at
    /// weight 1.
    public static func notes(selection: ChordSelection?,
                             degrees: [(ratio: Double, label: String)],
                             fallback: [Double])
        -> [(ratio: Double, weight: Double)] {
        if let sel = selection {
            if sel.degree >= 0, sel.degree < degrees.count {
                return shepardChordNotes(
                    rootRatio: degrees[sel.degree].ratio,
                    intervals: scaleChords(degrees: degrees)[sel.degree]
                        .intervals)
            }
        }
        return fallback.map { ($0, 1.0) }
    }

    private let sink: NoteSink
    /// The scale degrees the chord is derived against, and the Strings
    /// tab's configured strum ratios (the no-selection fallback).
    private let degrees: () -> [(ratio: Double, label: String)]
    private let fallbackRatios: () -> [Double]
    /// Injected for tests; the app hops to the main queue.
    private let dispatchMain: (@escaping () -> Void) -> Void
    private let now: () -> TimeInterval

    /// The chord bar's ACTIVE selection (nil = the configured set).
    public private(set) var selection: ChordSelection?

    private var gen = 0
    /// The ringing chord's touches + Shepard weights (1.0 for the
    /// configured set); each note's live expression is `expr × weight`.
    private var held: [(id: Int, weight: Double)] = []
    private var lHeld = false
    private var accelHeld = false
    private var expr = 1.0                        // ctl_strum_expr
    /// `ctl_strum_thresh` in the 0…1 strike domain; ≥127 = off (.infinity).
    private var thresh01 = Double.infinity
    /// Accel-trigger cooldown deadline: 100 ms after each accel release so
    /// a jittery envelope can't re-strike. Main-queue only.
    private var accelCooldownUntil: TimeInterval = 0

    public init(sink: NoteSink,
                degrees: @escaping () -> [(ratio: Double, label: String)],
                fallbackRatios: @escaping () -> [Double],
                dispatchMain: @escaping (@escaping () -> Void) -> Void
                    = { DispatchQueue.main.async(execute: $0) },
                now: @escaping () -> TimeInterval
                    = { ProcessInfo.processInfo.systemUptime }) {
        self.sink = sink
        self.degrees = degrees
        self.fallbackRatios = fallbackRatios
        self.dispatchMain = dispatchMain
        self.now = now
    }

    /// The ringing chord's touch ids (test/introspection).
    public var heldTouchIds: [Int] { held.map(\.id) }

    private func currentNotes() -> [(ratio: Double, weight: Double)] {
        Self.notes(selection: selection, degrees: degrees(),
                   fallback: fallbackRatios())
    }

    // MARK: - Holds

    /// The L button: a press always retriggers, a release lets go unless
    /// the accel trigger still holds.
    public func strum(pressed: Bool) {
        lHeld = pressed
        if pressed {
            strike()
        } else if !accelHeld {
            release()
        }
    }

    /// The chord bar's selection edge. A RINGING chord retunes in place.
    public func setSelection(_ sel: ChordSelection?) {
        selection = sel
        retune()
    }

    /// `ctl_strum_expr` — the chord's expression, pushed live to the held
    /// notes (each scaled by its Shepard weight).
    public func setExpression(_ value: Double) {
        let v = min(max(value, 0), 1)
        expr = v
        dispatchMain { [weak self] in
            guard let self else { return }
            for h in self.held {
                self.sink.setExpr(h.id, v * h.weight)
            }
        }
    }

    /// `ctl_strum_thresh` (0–127; ≥127 = off) in the strike domain.
    public func setAccelThreshold(_ ccValue: Double) {
        thresh01 = ccValue >= 126.5 ? .infinity : ccValue / 127.0
    }

    /// The accel trigger's edge detector (link receive queue): rising
    /// through the threshold strikes; falling below releases (unless L
    /// holds) and arms the cooldown. Edges hop to main, which re-tests.
    public func accelSense(_ v: Double) {
        let up = !accelHeld && v >= thresh01
        let down = accelHeld && v < thresh01
        guard up || down else { return }
        dispatchMain { [weak self] in
            guard let self else { return }
            let t = self.now()
            if !self.accelHeld, v >= self.thresh01,
               t >= self.accelCooldownUntil {
                self.accelHeld = true
                self.strike()
            } else if self.accelHeld, v < self.thresh01 {
                self.accelHeld = false
                self.accelCooldownUntil = t + 0.1
                if !self.lHeld { self.release() }
            }
        }
    }

    // MARK: - Sounding

    private func strike() {
        release()
        gen += 1
        for (i, note) in currentNotes().enumerated() {
            let touch = Self.touchId(gen: gen, index: i)
            // A fixed-register anchor: exempt from the octave shift and from
            // the glide queue (near-simultaneous onsets must not chain).
            sink.noteOn(touch, note.ratio, 0.9, expr * note.weight)
            held.append((touch, note.weight))
        }
    }

    private func release() {
        for h in held { sink.noteOff(h.id) }
        held.removeAll()
    }

    /// A selection change while RINGING retunes the held notes in place (no
    /// new attack); a shrinking chord note-offs the surplus, a growing one
    /// strikes the extra members. Ids are index-deterministic per generation.
    private func retune() {
        guard !held.isEmpty else { return }
        let notes = currentNotes()
        for i in held.indices where i < notes.count {
            sink.glide(held[i].id, notes[i].ratio)
            if held[i].weight != notes[i].weight {
                held[i].weight = notes[i].weight
                sink.setExpr(held[i].id, expr * notes[i].weight)
            }
        }
        if held.count > notes.count {
            for h in held[notes.count...] { sink.noteOff(h.id) }
            held.removeSubrange(notes.count...)
        }
        while held.count < notes.count {
            let i = held.count
            let touch = Self.touchId(gen: gen, index: i)
            sink.noteOn(touch, notes[i].ratio, 0.9, expr * notes[i].weight)
            held.append((touch, notes[i].weight))
        }
    }
}
