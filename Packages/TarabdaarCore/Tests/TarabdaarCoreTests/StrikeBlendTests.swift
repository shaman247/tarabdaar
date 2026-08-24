import XCTest
@testable import TarabdaarCore

/// The Strike→Acceleration blend window (2026-08-23): per-note onset
/// anchors, newest-sounding-note weighting, un-reset fallback on release,
/// and the aging rest. Pure time math — timestamps are passed in, so the
/// tests are exact.
final class StrikeBlendTests: XCTestCase {

    func testRestIsAccelerationSide() {
        let w = StrikeBlendWindow(windowS: 2.0)
        XCTAssertEqual(w.weight(at: 100.0), 1.0,
                       "before any note the blend rests on Acceleration")
    }

    func testSingleNoteRampsOverWindow() {
        var w = StrikeBlendWindow(windowS: 2.0)
        w.noteOn(1, at: 10.0)
        XCTAssertEqual(w.weight(at: 10.0), 0.0, "onset = full Strike")
        XCTAssertEqual(w.weight(at: 11.0), 0.5, accuracy: 1e-12)
        XCTAssertEqual(w.weight(at: 12.0), 1.0)
        XCTAssertEqual(w.weight(at: 20.0), 1.0, "clamped past the window")
    }

    /// The user-decided overlap rule: the NEWEST sounding note's age
    /// drives the weight — a fresh tap gets full Strike treatment even
    /// mid-legato.
    func testNewestSoundingNoteWins() {
        var w = StrikeBlendWindow(windowS: 2.0)
        w.noteOn(1, at: 0.0)
        w.noteOn(2, at: 1.5)
        XCTAssertEqual(w.weight(at: 1.5), 0.0,
                       "the new onset snaps the blend to Strike")
        XCTAssertEqual(w.weight(at: 2.5), 0.5, accuracy: 1e-12,
                       "and ages from ITS OWN anchor")
    }

    /// The per-note guarantee: releasing the newer note falls back to the
    /// older note's TRUE age — its window was never reset by the overlap.
    func testReleaseFallsBackToSurvivorsTrueAge() {
        var w = StrikeBlendWindow(windowS: 2.0)
        w.noteOn(1, at: 0.0)
        w.noteOn(2, at: 1.5)
        w.noteOff(2)
        XCTAssertEqual(w.weight(at: 1.6), 0.8, accuracy: 1e-12,
                       "note 1's age is 1.6 s — not reset by note 2")
        w.noteOff(1)
        // Nothing sounding: the newest onset ever keeps aging.
        XCTAssertEqual(w.weight(at: 2.5), 0.5, accuracy: 1e-12,
                       "after release the window ages from the last onset")
        XCTAssertEqual(w.weight(at: 4.0), 1.0)
    }

    /// A retrigger (same id, new onsetSeq) is a fresh articulation — it
    /// re-anchors that id's window.
    func testRetriggerReanchors() {
        var w = StrikeBlendWindow(windowS: 2.0)
        w.noteOn(7, at: 0.0)
        XCTAssertEqual(w.weight(at: 1.9), 0.95, accuracy: 1e-12)
        w.noteOn(7, at: 1.9)
        XCTAssertEqual(w.weight(at: 1.9), 0.0)
    }

    /// Link drop: the sounding set clears but the blend keeps settling
    /// toward Acceleration instead of snapping.
    func testAllNotesOffKeepsAgingFallback() {
        var w = StrikeBlendWindow(windowS: 2.0)
        w.noteOn(1, at: 0.0)
        w.noteOn(2, at: 1.0)
        w.allNotesOff()
        XCTAssertEqual(w.weight(at: 2.0), 0.5, accuracy: 1e-12,
                       "ages from the newest onset ever (t = 1.0)")
    }
}
