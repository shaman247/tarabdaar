import XCTest
import CoreGraphics
@testable import TarabdaarCore

/// Guards the drag-assist escape/decay rules (2026-08-01): the magnet never
/// fights an escape from a fret (no pull from a receding candidate), a moving
/// touch sheds its carried correction toward the raw field pitch, and a
/// stationary touch keeps it frozen (microtonal hold). The original bug: a
/// slow glide R → S below S's vertical extent arrived ~+97c sharp ("halfway")
/// because the magnet re-anchored to R across the basin and the residue froze
/// at the basin edge.
final class FretDragAssistTests: XCTestCase {

    // Default JI 12-degree scale (sargam), default 7-column arrangement.
    private let degrees: [(ratio: Double, label: String)] = [
        (1.0, "S"), (16.0 / 15.0, "r"), (9.0 / 8.0, "R"), (6.0 / 5.0, "g"),
        (5.0 / 4.0, "G"), (4.0 / 3.0, "m"), (45.0 / 32.0, "M"), (3.0 / 2.0, "P"),
        (8.0 / 5.0, "d"), (5.0 / 3.0, "D"), (16.0 / 9.0, "n"), (15.0 / 8.0, "N"),
    ]
    private let size = CGSize(width: 1000, height: 300)
    private let snapDistance: CGFloat = 24

    private func makePlacements() -> [FretPlacement] {
        let arr = FretArrangement.defaultArrangement(degrees: degrees)
        return fretPlacements(arrangement: arr, degrees: degrees, size: size)
    }

    private func fret(_ name: String, in placements: [FretPlacement]) -> FretPlacement {
        placements.first { $0.name == name && !$0.isGhost }!
    }

    /// Drive one touch: 60 Hz moves along `points`, returning the last
    /// assisted log2 pitch. `t` advances in place so phases can be chained.
    private func drive(_ assist: FretDragAssist, placements: [FretPlacement],
                       offset: Double, points: [CGPoint], t: inout Double) -> Double {
        var out = 0.0
        for p in points {
            t += 1.0 / 60.0
            let f = fretFieldLog(at: p, placements: placements)!
            out = assist.move(touchId: 1, x: p.x, y: p.y,
                              uncorrectedLog: f + offset, time: t).log2Pitch
        }
        return out
    }

    private func hold(_ assist: FretDragAssist, seconds: Double,
                      t: inout Double) -> Double {
        var out = 0.0
        for _ in 0..<Int(seconds * 60) {
            t += 1.0 / 60.0
            for (_, o) in assist.tick(time: t) { out = o.log2Pitch }
        }
        return out
    }

    private func line(from a: CGPoint, to b: CGPoint,
                      pxPerSec: Double) -> [CGPoint] {
        let dist = Double(hypot(b.x - a.x, b.y - a.y))
        let n = max(1, Int((dist / pxPerSec * 60).rounded(.up)))
        return (1...n).map { i in
            let s = CGFloat(Double(i) / Double(n))
            return CGPoint(x: a.x + (b.x - a.x) * s, y: a.y + (b.y - a.y) * s)
        }
    }

    /// The reported bug: a slow on-fret glide S → r at a y below r's extent
    /// must arrive ON r (the field's truth), not carry the S magnet's
    /// residue; moving on up into r's extent stays on r.
    ///
    /// (Geometry, 2026-08-02 pitch-aligned default: the komal/tivra tier ends
    /// at 0.460 and S — the long key — runs 0.470…0.912, so a y just under
    /// the upper tier is inside S's extent and outside r's.)
    func testSlowGlideOffFretArrivesOnPitch() {
        let placements = makePlacements()
        let s = fret("S", in: placements)
        let komal = fret("r", in: placements)
        let y = komal.bottomY + 5       // below r's extent, inside S's
        let rCents = log2(komal.ratio) * 1200

        let assist = FretDragAssist()
        assist.setContext(placements: placements, snapDistance: snapDistance)
        var t = 0.0
        let start = CGPoint(x: s.x, y: y)
        assist.begin(touchId: 1, x: start.x, y: start.y,
                     uncorrectedLog: log2(s.ratio), time: t)
        var played = drive(assist, placements: placements, offset: 0,
                           points: line(from: start, to: CGPoint(x: komal.x, y: y),
                                        pxPerSec: 120), t: &t)
        played = hold(assist, seconds: 0.5, t: &t)
        XCTAssertEqual(played * 1200, rCents, accuracy: 5,
                       "slow glide must arrive on r (was ~+97c pre-fix)")

        played = drive(assist, placements: placements, offset: 0,
                       points: line(from: CGPoint(x: komal.x, y: y),
                                    to: CGPoint(x: komal.x, y: komal.bottomY - 10),
                                    pxPerSec: 100), t: &t)
        played = hold(assist, seconds: 0.5, t: &t)
        XCTAssertEqual(played * 1200, rCents, accuracy: 1,
                       "entering r's extent settles exactly on r")
    }

    /// A carried correction (from an assisted landing) must shed during a
    /// glide with no qualifying pull — the next approach lands true.
    func testMovingTouchShedsCarriedCorrection() {
        let placements = makePlacements()
        let s = fret("S", in: placements)
        let komal = fret("r", in: placements)
        let y = komal.bottomY + 5       // below r's extent, inside S's

        let assist = FretDragAssist()
        assist.setContext(placements: placements, snapDistance: snapDistance)
        var t = 0.0
        // Unsnapped onset 30 px flat of S (inside the 42 px basin, outside
        // the 24 px snap), then rest: the magnet lands the touch on S,
        // building a real correction (~+72c).
        let start = CGPoint(x: s.x - 30, y: y)
        let f0 = fretFieldLog(at: start, placements: placements)!
        assist.begin(touchId: 1, x: start.x, y: start.y,
                     uncorrectedLog: f0, time: t)
        _ = drive(assist, placements: placements, offset: 0,
                  points: [CGPoint(x: start.x - 1, y: y)], t: &t)
        var played = hold(assist, seconds: 1.0, t: &t)
        XCTAssertEqual(played * 1200, log2(s.ratio) * 1200, accuracy: 3,
                       "assisted landing settles on S")

        // Slow glide up to r: receding from S (no pull), r's extent doesn't
        // contain the touch (no pull either) + moving (correction decays) →
        // arrives on r.
        played = drive(assist, placements: placements, offset: 0,
                       points: line(from: CGPoint(x: start.x - 1, y: y),
                                    to: CGPoint(x: komal.x, y: y),
                                    pxPerSec: 120), t: &t)
        played = hold(assist, seconds: 0.5, t: &t)
        XCTAssertEqual(played * 1200, log2(komal.ratio) * 1200, accuracy: 5,
                       "carried correction sheds during the glide")
    }

    /// A stationary touch with no qualifying fret keeps its correction
    /// frozen — a deliberate microtonal hold must not drift.
    func testStationaryHoldStaysFrozen() {
        let placements = makePlacements()
        let s = fret("S", in: placements)
        let komal = fret("r", in: placements)

        let assist = FretDragAssist()
        assist.setContext(placements: placements, snapDistance: snapDistance)
        var t = 0.0
        // Build a correction on S as above, then slide straight DOWN out of
        // S's extent (dx = 0 → stationary by the horizontal-speed measure).
        let y = komal.bottomY + 5
        let start = CGPoint(x: s.x - 30, y: y)
        let f0 = fretFieldLog(at: start, placements: placements)!
        assist.begin(touchId: 1, x: start.x, y: start.y, uncorrectedLog: f0, time: t)
        _ = drive(assist, placements: placements, offset: 0,
                  points: [CGPoint(x: start.x - 1, y: y)], t: &t)
        _ = hold(assist, seconds: 1.0, t: &t)

        let exitY = s.bottomY + 20      // below every extent (S is the longest)
        var played = drive(assist, placements: placements, offset: 0,
                           points: line(from: CGPoint(x: start.x - 1, y: y),
                                        to: CGPoint(x: start.x - 1, y: exitY),
                                        pxPerSec: 100), t: &t)
        let before = played
        played = hold(assist, seconds: 1.0, t: &t)
        XCTAssertEqual(played * 1200, before * 1200, accuracy: 0.5,
                       "stationary hold must not drift")
    }
}
