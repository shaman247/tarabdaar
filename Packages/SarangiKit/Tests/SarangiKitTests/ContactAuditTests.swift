import XCTest
import CBowKernel
@testable import SarangiKit

final class ContactAuditTests: XCTestCase {
    /// Both solvers preserve audited motion exactly, and SAV remains passive with no excess auxiliary energy.
    func testEnergyAuditDoesNotAffectPhysics() throws {
        let modes = 8, sites = 4
        let omega = (1...modes).map { 2*Double.pi*561*Double($0) }
        let sigma = (1...modes).map { 2+Double($0*$0) }
        let phi = (1...modes).flatMap { k in
            (0..<sites).map { z in sqrt(8)*sin(Double.pi*Double(k)*(0.98+Double(z)*0.005)) }
        }
        let bone = [1e-6, 2e-6, 3e-6, 2e-6], weight = 1.0
        let rest = try XCTUnwrap(JawariEquilibrium.solve(phi: phi, force: phi.map { $0*weight },
            omega: omega, bone: bone, stiffness: 1e10, alpha: 1.3))
        let zero = [Double](repeating: 0, count: modes)
        let tap = (1...modes).map { sqrt(8)*sin(Double.pi*Double($0)*0.2) }
        for useSAV in [false, true] {
            let solvers = try (0..<2).map { _ in try XCTUnwrap(bow_contact_create(
                Int32(modes), Int32(sites), 192000, 1e10, 1.3, 3, weight, 1e-3, 1,
                omega, sigma, phi, bone, rest, zero)) }
            defer { solvers.forEach { bow_contact_destroy($0) } }
            for solver in solvers { XCTAssertEqual(bow_contact_set_sav(solver, useSAV ? 1 : 0), 1) }
            bow_contact_disable_energy_audit(solvers[1])
            for solver in solvers {
                bow_contact_drive(solver, tap, tap)
                bow_contact_pluck(solver, 0.0005, 0.008, 0.0004, tap)
            }
            for block in 0..<80 {
                var outputs = [[Double]](), positions = [[Double]](), velocities = [[Double]]()
                var diagnostics = [[Double]](), reactions = [Double]()
                for solver in solvers {
                    if block == 30 { bow_contact_pluck(solver, 0.001, 0.008, 0.0004, tap) }
                    bow_contact_input(solver, sin(Double(block))*0.01)
                    bow_contact_damp(solver, 0.999)
                    var output = [Double](repeating: 0, count: 128), stats = [Double](repeating: 0, count: 8)
                    XCTAssertEqual(bow_contact_render_audio(solver, 128, &output, &stats), 128)
                    var q = zero, p = zero
                    bow_contact_state(solver, &q, &p)
                    outputs.append(output); positions.append(q); velocities.append(p)
                    diagnostics.append(stats); reactions.append(bow_contact_normal(solver))
                }
                XCTAssertEqual(outputs[0], outputs[1]); XCTAssertEqual(positions[0], positions[1])
                XCTAssertEqual(velocities[0], velocities[1]); XCTAssertEqual(reactions[0], reactions[1])
                XCTAssertEqual(Array(diagnostics[0].prefix(3)), Array(diagnostics[1].prefix(3)))
                XCTAssertEqual(diagnostics[0][2], 0)
                XCTAssertTrue(diagnostics[0].allSatisfy(\.isFinite))
                XCTAssertTrue(diagnostics[1].suffix(5).allSatisfy(\.isNaN))
                if useSAV {
                    XCTAssertEqual(diagnostics[0][0], 0)
                    let budget = max(abs(diagnostics[0][3])+abs(diagnostics[0][4])+abs(diagnostics[0][5]), 1e-12)
                    XCTAssertLessThan(abs(diagnostics[0][7])/budget, 1e-7)
                    let q = positions[0], p = velocities[0]
                    let modal = (0..<modes).reduce(0.0) { $0 + 0.5*(p[$1]*p[$1]+omega[$1]*omega[$1]*q[$1]*q[$1]) }
                    let physical = (0..<sites).reduce(0.0) { sum, z in
                        let eta = bone[z] - (0..<modes).reduce(0.0) { $0 + phi[$1*sites+z]*q[$1] }
                        return sum + weight*1e10/2.3*pow(max(eta, 0), 2.3)
                    }
                    XCTAssertLessThanOrEqual(diagnostics[0][6]-modal, physical+budget*1e-10)
                }
            }
            XCTAssertEqual(bow_contact_set_sav(solvers[0], useSAV ? 0 : 1), 0, "running strings cannot change solver")
        }
    }
}
