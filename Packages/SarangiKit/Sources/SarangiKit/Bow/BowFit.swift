import Foundation
import CBowKernel

/// Shared fitted observations; resources contain no reference recordings or gestures.
struct BowFitAsset: Decodable {
    let version: Int
    let sampleRate: Int
    let coefficients: [[Double]]
    let bodyDB: [Double]
    let bodyKnots: [Double]
    let radiationDelta: [Double]
    let radiationMain: Double
    let radiationTail: Double
    let roomFrames: Int
    let roomDryGain: Double
    let ringModes: [[Double]]
    let forceGain: Double
    static let shared: BowFitAsset = {
        let url = Bundle.module.url(forResource: "sarangi_fit", withExtension: "json")!
        let a = try! JSONDecoder().decode(BowFitAsset.self, from: Data(contentsOf: url))
        precondition(a.version == 1 && a.sampleRate == 48000 && a.coefficients.count == 23
                     && a.coefficients.allSatisfy { $0.count == 129 }
                     && a.bodyDB.count == 24 && a.bodyKnots.count == 24)
        return a
    }()
    static let room: [Float] = {
        let url = Bundle.module.url(forResource: "sarangi_fit_room", withExtension: "f32")!
        let data = try! Data(contentsOf: url)
        precondition(data.count == shared.roomFrames * 3 * MemoryLayout<Float>.size)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }()
    func create() -> UnsafeMutableRawPointer {
        let p = bow_fit_create(coefficients.flatMap { $0 }, bodyDB, bodyKnots,
                               Self.room, Int32(roomFrames), ringModes.flatMap { $0 },
                               Int32(ringModes.count), forceGain)
        precondition(p != nil)
        return p!
    }
    func applyRadiation(to tables: inout BowKernelTables, bp: BowParams) {
        let amount = min(1, max(0, bp.v("bow_fit_body", 0)))
        guard amount != 0 else { return }
        let main = Int(bp.v("bow_body_modes", 9).rounded())
        // Separate original main/formant indices so changing either count stays defined.
        for k in tables.bC.indices {
            let index = k < main ? k : k - main + 9
            guard index < radiationDelta.count, k >= main || k < 9 else { continue }
            let scale = k < main ? bp.v("bow_body_rad", radiationMain) / radiationMain
                                : bp.v("bow_body_tail_rad", radiationTail) / radiationTail
            tables.bC[k] += amount * scale * radiationDelta[index]
        }
    }
}

extension BowEngine {
    /// Staged through the same render lock as the other live voice controls.
    public func setFittedControl(_ index: Int, _ value: Double) {
        guard index >= 0 && index < 10 && value.isFinite else { return }
        os_unfair_lock_lock(&tiltLock)
        fitTargets[index] = value
        fitDirty = true
        os_unfair_lock_unlock(&tiltLock)
    }

    func updateFittedControls() {
        os_unfair_lock_lock(&tiltLock)
        if fitDirty {
            for i in fitTargets.indices { bow_fit_set(fitted, Int32(i), fitTargets[i]) }
            fitDirty = false
        }
        os_unfair_lock_unlock(&tiltLock)
    }
}
