import XCTest
@testable import SarangiKit

final class BowAxisTransformTests: XCTestCase {
    /// Absent or explicit identity maps preserve bits; custom maps clamp and interpolate without overshoot.
    func testIdentityAndBoundedInterpolation() {
        let absent = BowAxisTransform(bp: BowParams(num: [:]), axis: "expr")
        var bp = BowParams(num: [:])
        for i in 0...10 { bp.num["bow_expr_map_\(i)"] = Double(i) / 10 }
        let identity = BowAxisTransform(bp: bp, axis: "expr")
        for i in 0...1000 {
            let x = Double(i) / 1000
            XCTAssertEqual(absent.apply(x).bitPattern, x.bitPattern)
            XCTAssertEqual(identity.apply(x).bitPattern, x.bitPattern)
        }
        for i in 0...10 { bp.num["bow_expr_map_\(i)"] = 0.4 + 0.5 * Double(i) / 10 }
        let mapped = BowAxisTransform(bp: bp, axis: "expr")
        for i in 0...1000 {
            let x = Double(i) / 1000
            XCTAssertEqual(mapped.apply(x), 0.4 + 0.5 * x, accuracy: 1e-14)
        }
        XCTAssertEqual(mapped.apply(-1), 0.4)
        XCTAssertEqual(mapped.apply(2), 0.9)
        XCTAssertEqual(mapped.apply(.nan), 0.4)
    }

    /// Arbitrary knots, reversals, malformed points and edits stay bounded with an exact identity bypass.
    func testEditablePoints() {
        let points = [BowAxisPoint(x: 0, y: 0.8), BowAxisPoint(x: 0.23, y: 0.1),
                      BowAxisPoint(x: 0.71, y: 0.9), BowAxisPoint(x: 1, y: 0.3)]
        let curve = BowAxisTransform(points: points)
        for p in points { XCTAssertEqual(curve.apply(p.x), p.y, accuracy: 1e-14) }
        XCTAssertEqual(curve.apply(0.47), 0.5, accuracy: 1e-14)
        for i in 0...1000 { XCTAssertTrue((0.1...0.9).contains(curve.apply(Double(i) / 1000))) }
        var edited = points
        edited.insert(BowAxisPoint(x: 0.47, y: 0.5), at: 2)
        let added = BowAxisTransform(points: edited)
        for i in 0...1000 {
            let x = Double(i) / 1000
            XCTAssertEqual(curve.apply(x), added.apply(x), accuracy: 1e-14)
            XCTAssertEqual(BowAxisTransform(points: []).apply(x).bitPattern, x.bitPattern)
        }
        let normalized = BowAxisTransform.normalize([
            BowAxisPoint(x: .nan, y: 1), BowAxisPoint(x: 0.7, y: 3),
            BowAxisPoint(x: 0.2, y: -1), BowAxisPoint(x: 0.2, y: 0.4)])
        XCTAssertEqual(normalized, [BowAxisPoint(x: 0, y: 0.4), BowAxisPoint(x: 0.2, y: 0.4),
                                    BowAxisPoint(x: 0.7, y: 1), BowAxisPoint(x: 1, y: 1)])
    }

    /// Staged curves reach every sounding slot and survive a later ordinary live-parameter update.
    func testEngineCurveAdoptionSurvivesLiveParams() {
        let bp = BowedStringEngineTests.stringBP()
        var referenceBP = bp
        for i in 0...10 { referenceBP.num["bow_expr_map_\(i)"] = 0.55 }
        let tables = BowTables.buildOpenString(sr: 96000, tonic: 261.63, bp: bp)
        func engine(_ params: BowParams) -> BowEngine {
            let mapper = BowControlMapper()
            mapper.setAxis(expr: 0.8, press: 0.5, pos: 0.5)
            mapper.touchOn(1, pitchSemis: 60)
            mapper.touchOn(2, pitchSemis: 67)
            return BowEngine(tables: tables, mapper: mapper, bp: params, sr: 48000,
                             rfir: [], eLp: 8000, reverbRT60: 1,
                             reverbPredelayMs: 15, reverbMix: 0, reverbWidth: 0, maxPoly: 2)
        }
        let reference = engine(referenceBP), edited = engine(bp)
        edited.setAxisTransforms([.expression: BowAxisTransform(points: [
            BowAxisPoint(x: 0, y: 0.55), BowAxisPoint(x: 0.37, y: 0.55), BowAxisPoint(x: 1, y: 0.55)])])
        let buffers = (0..<4).map { _ in UnsafeMutablePointer<Double>.allocate(capacity: 128) }
        defer { buffers.forEach { $0.deallocate() } }
        var energy = 0.0
        var maxDifference = 0.0
        for block in 0..<64 {
            if block == 32 {
                edited.setLiveParams(bp: bp, scalars: tables.scalars, tables: tables)
                reference.setLiveParams(bp: referenceBP, scalars: tables.scalars, tables: tables)
            }
            reference.render(frames: 128, outL: buffers[0], outR: buffers[1])
            edited.render(frames: 128, outL: buffers[2], outR: buffers[3])
            for i in 0..<128 {
                maxDifference = max(maxDifference, abs(buffers[0][i] - buffers[2][i]),
                                    abs(buffers[1][i] - buffers[3][i]))
                energy += buffers[2][i] * buffers[2][i]
            }
        }
        XCTAssertGreaterThan(energy, 1e-8)
        XCTAssertEqual(maxDifference, 0)
    }

    /// Each map runs once after per-touch expression scaling, including in-place edits on a held note.
    func testFilterUsesTransformedAxesAfterExpressionScale() {
        var bp = BowedStringEngineTests.stringBP()
        let raw = BowControlMapper(), mapped = BowControlMapper()
        raw.setAxis(expr: 0.3, press: 0.15, pos: 0.7)
        mapped.setAxis(expr: 0.8, press: 0.5, pos: 0.2)
        raw.touchOn(1, pitchSemis: 60)
        mapped.touchOn(1, pitchSemis: 60, exprScale: 0.5)
        var reference = BowControlFilter(bp: bp, srk: 96000, tonic: 261.63)
        var transformed = BowControlFilter(bp: bp, srk: 96000, tonic: 261.63)
        let buffers = (0..<10).map { _ in UnsafeMutablePointer<Double>.allocate(capacity: 256) }
        defer { buffers.forEach { $0.deallocate() } }
        for round in 0..<2 {
            for i in 0...10 {
                let x = Double(i) / 10
                bp.num["bow_expr_map_\(i)"] = 0.1 + 0.5 * x
                bp.num["bow_press_map_\(i)"] = 0.3 * x
                bp.num["bow_pos_map_\(i)"] = 0.6 + 0.5 * x
            }
            if round == 0 {
                transformed.setAxisTransforms([
                    .expression: BowAxisTransform(points: [BowAxisPoint(x: 0, y: 0.1), BowAxisPoint(x: 1, y: 0.6)]),
                    .pressure: BowAxisTransform(points: [BowAxisPoint(x: 0, y: 0), BowAxisPoint(x: 1, y: 0.3)]),
                    .position: BowAxisTransform(points: [BowAxisPoint(x: 0, y: 0.6), BowAxisPoint(x: 0.8, y: 1), BowAxisPoint(x: 1, y: 1)])])
            }
            else {
                bp.num["bow_expr_map_4"] = 0.35
                raw.setAxis(expr: 0.35)
                transformed.updateLiveParams(bp: bp)
                // Let the raw-axis interpolation reach the edited curve's destination.
                reference.fill(from: raw, n: 256, f0: buffers[0], vb: buffers[1], fb: buffers[2], beta: buffers[3], gate: buffers[4])
                transformed.fill(from: mapped, n: 256, f0: buffers[5], vb: buffers[6], fb: buffers[7], beta: buffers[8], gate: buffers[9])
            }
            reference.fill(from: raw, n: 256, f0: buffers[0], vb: buffers[1], fb: buffers[2], beta: buffers[3], gate: buffers[4])
            transformed.fill(from: mapped, n: 256, f0: buffers[5], vb: buffers[6], fb: buffers[7], beta: buffers[8], gate: buffers[9])
            for k in 0..<5 {
                for i in 0..<256 { XCTAssertEqual(buffers[k][i], buffers[k+5][i], accuracy: 1e-12) }
            }
        }
    }
}
