import XCTest
import CoreGraphics
@testable import StarpadCore

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

    /// The reported bug: a slow on-fret glide R → S at a y below S's extent
    /// must arrive ON S (the field's truth), not carry the R magnet's
    /// residue; moving on up into S's extent stays on S.
    func testSlowGlideOffFretArrivesOnPitch() {
        let placements = makePlacements()
        let s = fret("S", in: placements)
        let r = fret("R", in: placements)
        let y = s.bottomY + 5           // below S's extent, inside R's

        let assist = FretDragAssist()
        assist.setContext(placements: placements, snapDistance: snapDistance)
        var t = 0.0
        let start = CGPoint(x: r.x, y: y)
        assist.begin(touchId: 1, x: start.x, y: start.y,
                     uncorrectedLog: log2(r.ratio), time: t)
        var played = drive(assist, placements: placements, offset: 0,
                           points: line(from: start, to: CGPoint(x: s.x, y: y),
                                        pxPerSec: 120), t: &t)
        played = hold(assist, seconds: 0.5, t: &t)
        XCTAssertEqual(played * 1200, 0, accuracy: 5,
                       "slow glide must arrive on S (was +97c pre-fix)")

        played = drive(assist, placements: placements, offset: 0,
                       points: line(from: CGPoint(x: s.x, y: y),
                                    to: CGPoint(x: s.x, y: s.bottomY - 10),
                                    pxPerSec: 100), t: &t)
        played = hold(assist, seconds: 0.5, t: &t)
        XCTAssertEqual(played * 1200, 0, accuracy: 1,
                       "entering S's extent settles exactly on S")
    }

    /// A carried correction (from an assisted landing) must shed during a
    /// glide with no qualifying pull — the next approach lands true.
    func testMovingTouchShedsCarriedCorrection() {
        let placements = makePlacements()
        let s = fret("S", in: placements)
        let r = fret("R", in: placements)
        let y = s.bottomY + 5

        let assist = FretDragAssist()
        assist.setContext(placements: placements, snapDistance: snapDistance)
        var t = 0.0
        // Unsnapped onset 30 px flat of R (inside the 42 px basin, outside
        // the 24 px snap), then rest: the magnet lands the touch on R,
        // building a real correction (~+86c).
        let start = CGPoint(x: r.x - 30, y: y)
        let f0 = fretFieldLog(at: start, placements: placements)!
        assist.begin(touchId: 1, x: start.x, y: start.y,
                     uncorrectedLog: f0, time: t)
        _ = drive(assist, placements: placements, offset: 0,
                  points: [CGPoint(x: start.x - 1, y: y)], t: &t)
        var played = hold(assist, seconds: 1.0, t: &t)
        XCTAssertEqual(played * 1200, log2(r.ratio) * 1200, accuracy: 3,
                       "assisted landing settles on R")

        // Slow glide to S: receding from R (no pull) + moving (correction
        // decays) → arrives on S.
        played = drive(assist, placements: placements, offset: 0,
                       points: line(from: CGPoint(x: start.x - 1, y: y),
                                    to: CGPoint(x: s.x, y: y),
                                    pxPerSec: 120), t: &t)
        played = hold(assist, seconds: 0.5, t: &t)
        XCTAssertEqual(played * 1200, 0, accuracy: 5,
                       "carried correction sheds during the glide")
    }

    /// A stationary touch with no qualifying fret keeps its correction
    /// frozen — a deliberate microtonal hold must not drift.
    func testStationaryHoldStaysFrozen() {
        let placements = makePlacements()
        let s = fret("S", in: placements)
        let r = fret("R", in: placements)

        let assist = FretDragAssist()
        assist.setContext(placements: placements, snapDistance: snapDistance)
        var t = 0.0
        // Build a correction on R as above, then slide straight DOWN out of
        // R's extent (dx = 0 → stationary by the horizontal-speed measure).
        let y = s.bottomY + 5
        let start = CGPoint(x: r.x - 30, y: y)
        let f0 = fretFieldLog(at: start, placements: placements)!
        assist.begin(touchId: 1, x: start.x, y: start.y, uncorrectedLog: f0, time: t)
        _ = drive(assist, placements: placements, offset: 0,
                  points: [CGPoint(x: start.x - 1, y: y)], t: &t)
        _ = hold(assist, seconds: 1.0, t: &t)

        let exitY = r.bottomY + 20      // below every extent at this x
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
