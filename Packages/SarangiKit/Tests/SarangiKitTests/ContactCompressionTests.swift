import XCTest
import CBowKernel
@testable import SarangiKit

final class ContactCompressionTests: XCTestCase {
    /// Compressed contact preserves dense motion and energy balance, with exact fallback for unsuitable geometry.
    func testCompressionReciprocityAndDenseFallback() throws {
        let modes = 80, sites = 24
        let omega = (0..<modes).map { 2*Double.pi*561*Double($0 % 40 + 1) }
        let sigma = (0..<modes).map { 2+0.1*Double(($0 % 40 + 1)*($0 % 40 + 1)) }
        var smooth = [Double]()
        for k in 0..<modes {
            for z in 0..<sites {
                let position = 0.976+Double(z)*0.0208/23
                let value = sqrt(8.0)*sin(Double.pi*Double(k+1)*position)
                smooth.append(k < 40 ? value : 0)
            }
        }
        let fullRank = (0..<modes).flatMap { k in (0..<sites).map { z in k == z ? 1.0 : 0.0 } }
        let bone = (0..<sites).map { z in 1e-6 - pow(Double(z-18)*0.0002, 2)/0.6 }
        let tap = (0..<modes).map { sqrt(8)*sin(Double.pi*Double($0 % 40+1)*0.2) }
        let zero = [Double](repeating: 0, count: modes)
        for rate in [96000.0, 192000.0] {
            for (phi, compressible) in [(smooth, true), (fullRank, false)] {
                let rest = try XCTUnwrap(JawariEquilibrium.solve(phi: phi, force: phi,
                    omega: omega, bone: bone, stiffness: 1e10, alpha: 1.3))
                let solvers = try (0..<2).map { _ in try XCTUnwrap(bow_contact_create(
                    Int32(modes), Int32(sites), rate, 1e10, 1.3, 3, 1, 1e-3, 1,
                    omega, sigma, phi, bone, rest, zero)) }
                defer { solvers.forEach { bow_contact_destroy($0) } }
                let rank = bow_contact_compress(solvers[1])
                if compressible { XCTAssertGreaterThan(rank, 0) } else { XCTAssertEqual(rank, 0) }
                for solver in solvers {
                    bow_contact_drive(solver, tap, tap)
                    bow_contact_pluck(solver, 0.0005, 0.008, 0.0004, tap)
                }
                var signalEnergy = 0.0, errorEnergy = 0.0
                var reactionEnergy = 0.0, reactionError = 0.0
                for block in 0..<80 {
                    var outputs = [[Double]](), reactions = [Double]()
                    for solver in solvers {
                        if block == 30 { bow_contact_pluck(solver, 0.001, 0.008, 0.0004, tap) }
                        bow_contact_input(solver, sin(Double(block))*0.01)
                        var output = [Double](repeating: 0, count: 128), stats = [Double](repeating: 0, count: 8)
                        XCTAssertEqual(bow_contact_render_audio(solver, 128, &output, &stats), 128)
                        XCTAssertTrue(output.allSatisfy(\.isFinite))
                        XCTAssertTrue(stats.allSatisfy(\.isFinite))
                        XCTAssertEqual(stats[2], 0)
                        let scale = max(abs(stats[3])+abs(stats[4])+abs(stats[5]), 1e-12)
                        XCTAssertLessThan(abs(stats[7])/scale, 1e-6, "contact work must remain reciprocal")
                        outputs.append(output); reactions.append(bow_contact_normal(solver))
                    }
                    if !compressible { XCTAssertEqual(outputs[0], outputs[1]); XCTAssertEqual(reactions[0], reactions[1]) }
                    for (a, b) in zip(outputs[0], outputs[1]) { signalEnergy += a*a; errorEnergy += (a-b)*(a-b) }
                    reactionEnergy += reactions[0]*reactions[0]
                    reactionError += pow(reactions[0]-reactions[1], 2)
                }
                XCTAssertEqual(bow_contact_compress(solvers[0]), 0, "a running solver cannot change geometry")
                XCTAssertGreaterThan(signalEnergy, 0)
                XCTAssertLessThan(sqrt(errorEnergy/signalEnergy), 1e-6)
                XCTAssertLessThan(sqrt(reactionError/max(reactionEnergy, 1e-30)), 1e-6)
            }
        }
    }
}
