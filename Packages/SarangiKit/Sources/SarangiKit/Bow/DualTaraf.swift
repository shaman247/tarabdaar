import Foundation
import CBowKernel

/// Build-time physical profile for the two-direction raga rows.
enum DualTaraf {
    private struct Radiation: Decodable {
        let sampleRate: Double
        let coefficients: [Double]
    }

    /// Shared reference coordinates; row pitch changes its clock and drive, not this geometry.
    private struct ReferenceProfile {
        let mu: Double, length: Double, shape: Double, weight: Double, rad: Double
        let modesPerPlane: Int, contacts: Int
        let omega: [Double], sigma: [Double], phi: [Double], bone: [Double]
        let rest: [Double], velocity: [Double], driveSine: [Double]
        let tap: [Double], pin: [Double], normalPin: [Double], radiation: [Double]

        init?() {
            guard let url = Bundle.module.url(forResource: "taraf_dual_radiation", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let response = try? JSONDecoder().decode(Radiation.self, from: data),
                  response.sampleRate == 48000 else { return nil }
            let f = 554.7063153796236
            let length = 0.25, radius = 0.0001, j = 8, m = 40
            let mu = Double.pi * radius * radius * 7850
            let tension = 4 * mu * length * length * f * f
            let inertia = Double.pi * pow(radius, 4) / 4
            let stiffness = Double.pi * Double.pi * 2e11 * inertia / (tension * length * length)
            let spacing = (0.006 - 0.0008) / Double(j-1)
            let shape = sqrt(2 / length)
            var omega = [Double](), sigma = [Double](), phi = [Double]()
            var driveSine = [Double](), tap = [Double](), pin = [Double](), normalPin = [Double]()
            for plane in 0..<2 {
                for k in 1...m {
                    let h = Double(k)
                    let w = 2 * Double.pi * f * h * sqrt(1 + stiffness*h*h)
                    omega.append(w)
                    let t60 = plane == 0 ? 4.0 : 5.0
                    let corner = plane == 0 ? 4000.0 : 6000.0
                    sigma.append(6.91 / t60 * (1 + pow(w / (2 * Double.pi * corner), 2)))
                    for z in 0..<j {
                        let x = length - 0.006 + Double(z)*spacing
                        phi.append(plane == 0 ? shape*sin(Double.pi*h*x/length) : 0)
                    }
                    if plane == 0 { driveSine.append(sin(Double.pi*h*0.9)) }
                    tap.append(shape*sin(Double.pi*h*0.2)*(plane == 0 ? cos(.pi/6) : sin(.pi/6)))
                    let p = shape * (2 * Double.pi * f * sqrt(1+stiffness)) * (k % 2 == 0 ? h : -h)
                    pin.append(p * (plane == 0 ? 1 : 0.25))
                    normalPin.append(plane == 0 ? p : 0)
                }
            }
            let bone = (0..<j).map { z -> Double in
                let x = length - 0.006 + Double(z)*spacing
                return 1e-5 * pow(4, 1-2*0.8) - pow(x-(length-0.0015), 2)/(2*0.3)
            }
            let weight = spacing/mu
            guard let rest = JawariEquilibrium.solve(phi: phi, force: phi.map { $0*weight },
                omega: omega, bone: bone, stiffness: 1e10, alpha: 1.3) else { return nil }
            self.mu = mu; self.length = length; self.shape = shape; self.weight = weight
            self.rad = Double.pi*spacing/(mu*length*omega[0])
            modesPerPlane = m; contacts = j
            self.omega = omega; self.sigma = sigma; self.phi = phi; self.bone = bone
            self.rest = rest; velocity = [Double](repeating: 0, count: 2*m)
            self.driveSine = driveSine; self.tap = tap; self.pin = pin; self.normalPin = normalPin
            radiation = response.coefficients
        }
    }

    // Swift's once-only initialization also serializes concurrent off-main builds.
    private static let reference = ReferenceProfile()

    static func install(kernel: UnsafeMutableRawPointer, row: Int, tables: JtTables,
                        useSAV: Bool = false) -> Bool {
        guard tables.rowFreqs.indices.contains(row), row != Int(tables.trackRow),
              tables.rowOutputGain.indices.contains(row) else { return false }
        let ratio = tables.rowFreqs[row] / 561
        guard ratio * 554.7063153796236 >= 70,
              ratio * 554.7063153796236 <= 1800,
              let p = reference else { return false }
        // Solve in the approved string's coordinates. The worker advances this
        // clock at ratio times wall time, preserving the discrete contact law.
        // Physical lengths/displacements scale by 1/ratio, density by 1/ratio².
        var drive = [Double](repeating: 0, count: p.omega.count)
        for k in 0..<p.modesPerPlane {
            // Preserve the fitted multiply/divide order for exact render parity.
            drive[k] = ratio*ratio*tables.rowInputGain[row]*p.shape*p.driveSine[k]/p.mu
        }
        // The C constructor copies the reference into row-owned motion and
        // solver storage. No mutable physics or filter history is shared.
        guard let contact = bow_contact_create(Int32(p.omega.count), Int32(p.contacts),
            Double(BOW_JT_DUAL_CONTACT_RATE), 1e10, 1.3, 3,
            p.weight, p.rad, p.shape*p.omega[0], p.omega, p.sigma, p.phi, p.bone,
            p.rest, p.velocity) else { return false }
        _ = bow_contact_compress(contact)
        if useSAV && bow_contact_set_sav(contact, 1) != 1 {
            bow_contact_destroy(contact)
            return false
        }
        bow_contact_radiation(contact, p.pin)
        bow_contact_drive(contact, drive, p.normalPin)
        // Convert the reference-coordinate reaction back to physical newtons.
        let forceScale = p.mu*p.length*p.omega[0]/(Double.pi*ratio*ratio)
        let norm = tables.rowOutputGain[row] > 1e-12 ? tables.rowCouplingNorm : 0
        let installed = bow_poly_jt_dual_load(kernel, Int32(row), contact, p.tap, Int32(p.omega.count),
            tables.rowOutputGain[row], forceScale, norm, p.radiation, Int32(p.radiation.count), tables.rowFreqs[row]) == 1
        if !installed { bow_contact_destroy(contact) }
        return installed
    }
}
