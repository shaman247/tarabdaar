import Foundation

/// THE STRIKE→ACCELERATION BLEND WINDOW . The `.strike` and
/// `.acceleration` dimensions ride the SAME measurement (the PERF_STATE
/// strike-envelope byte); what separates them is TIME SINCE THE NOTE
/// STARTED: at onset the measurement drives the Strike bindings fully,
/// and over `windowS` (2 s) it hands over linearly to the Acceleration
/// bindings — per target, output = (1−w)·strikeOut + w·accelOut, where a
/// side without a binding evaluates to the target's DEFAULT (registry
/// default for a parameter, 0 = rest for a composite). So "expression
/// [0,1] on Strike, unbound on Acceleration with default 0.4" reads at
/// w = 0.5 as the interpolated range [0.2, 0.7].
///
/// This struct owns the WEIGHT only — the per-note window bookkeeping:
///
///  * anchors are PER NOTE (wire touch id): a new onset never rewrites an
///    older sounding note's window;
///  * while notes sound, the NEWEST sounding note's age drives the weight
///    (a fresh tap always gets full Strike
///    treatment, even mid-legato — the cost that the shared parameters
///    swing back under the older note too is inherent to global targets,
///    and the measurement itself spikes at the tap anyway);
///  * releasing the newest note falls back to the SURVIVOR'S TRUE AGE
///    (the un-reset older window — the whole point of per-note anchors);
///  * with nothing sounding, the last onset keeps aging, so the blend
///    settles on the Acceleration side and rests there (weight 1 before
///    any note has ever played).
///
/// Retriggers (same id, new onsetSeq) re-anchor that id. Not thread-safe
/// — the owner serializes access (AppController's strike lock).
public struct StrikeBlendWindow {
    /// Configurable  (`ctl_strike_window`, Parameters
    /// tab); the owner clamps writes. Anchors survive a change — only
    /// the ramp length moves.
    public var windowS: Double

    /// Onset anchor per SOUNDING note (wire touch id).
    private var anchors: [UInt16: TimeInterval] = [:]
    /// The newest onset ever seen — the aging fallback after release.
    private var newestOnset: TimeInterval?

    public init(windowS: Double = 2.0) {
        self.windowS = max(windowS, 1e-3)
    }

    /// Fresh articulation (note-on or retrigger) — anchors the id's window.
    public mutating func noteOn(_ id: UInt16, at t: TimeInterval) {
        anchors[id] = t
        newestOnset = max(newestOnset ?? t, t)
    }

    /// Release — the id's anchor leaves the sounding set (the survivor's
    /// own anchor, or the aging `newestOnset` fallback, takes over).
    public mutating func noteOff(_ id: UInt16) {
        anchors.removeValue(forKey: id)
    }

    /// Link drop / panic: nothing sounds any more. The aging fallback is
    /// kept — the blend keeps settling toward Acceleration, not snapping.
    public mutating func allNotesOff() {
        anchors.removeAll()
    }

    /// The Strike→Acceleration weight at `now`: 0 = full Strike, 1 = full
    /// Acceleration, linear over `windowS` from the governing anchor
    /// (newest sounding, else the last onset ever, else rest = 1).
    public func weight(at now: TimeInterval) -> Double {
        guard let t0 = anchors.values.max() ?? newestOnset else { return 1.0 }
        return min(max((now - t0) / windowS, 0.0), 1.0)
    }
}
