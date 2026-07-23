import XCTest
import CBowKernel
@testable import SarangiKit

/// STAGE D of the live bow port — end-to-end confirm: pair-3's first ~10 s of
/// measured kernel-rate controls through BowEngine's LIVE buffer path
/// (1024-sample engine buffers) against the Python offline render of the same
/// controls through the same 48 kHz post-chain.
///
/// Expected: the kernel section at the kernel-parity bar (1e-12 — same C
/// source; bit-zero holds within one compilation, the Python reference dylib
/// is a different `cc -O3` binary); the final post-chain in the −60 dB class
/// — the one representation
/// difference is the decimator (streaming 65-tap half-band vs scipy's
/// zero-phase kaiser resample_poly), whose 16-output-sample group delay the
/// compare compensates. Reverb runs with mix 0 on both sides (live Freeverb
/// tank vs offline decay-IR convolution differ by algorithm class — the same
/// accepted divergence as the coupled live mode).
///
/// Env-gated (the fixture is ~60 MB, not committed):
///   BOW_LIVE_FIX=<dir> python3 scripts/export_bow_live_fixture.py
///   BOW_LIVE_FIX=<dir> swift test --filter BowLiveEndToEndTests
final class BowLiveEndToEndTests: XCTestCase {

    struct ArrSpec: Decodable { let name: String; let len: Int }
    struct Meta: Decodable {
        let n96: Int; let srk: Double; let osf: Int; let sr: Double
        let e_lp: Double; let nv: Int; let K: Int
        let L: [Int]; let scalars: [Double]; let arrays: [ArrSpec]
    }

    func testLiveBufferPathMatchesPython() throws {
        guard let dir = ProcessInfo.processInfo.environment["BOW_LIVE_FIX"] else {
            throw XCTSkip("BOW_LIVE_FIX not set — run scripts/export_bow_live_fixture.py")
        }
        let base = URL(fileURLWithPath: dir)
        let meta = try JSONDecoder().decode(
            Meta.self,
            from: Data(contentsOf: base.appendingPathComponent("bow_live_fixture.json")))
        let blob = try Data(contentsOf: base.appendingPathComponent("bow_live_fixture.bin"))
        let all: [Double] = blob.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        var off = 0
        var A: [String: [Double]] = [:]
        for spec in meta.arrays {
            A[spec.name] = Array(all[off ..< off + spec.len]); off += spec.len
        }
        XCTAssertEqual(off, all.count, "fixture blob length mismatch")

        // fixture tables → the BowKernelTables the live builder would make
        // (table math itself is gated by BowTableParityTests; the fixture
        // carries Python's exact values so the kernel compare is bit-level)
        var t = BowKernelTables(sr: meta.srk, L: meta.L.map { Int32($0) })
        t.cs = A["cs"]!; t.cp = A["cp"]!
        t.w0 = A["w0"]!; t.w1 = A["w1"]!; t.w2 = A["w2"]!
        t.w3 = A["w3"]!; t.w4 = A["w4"]!
        t.g = A["g"]!; t.lpA = A["lpA"]!; t.wout = A["wout"]!
        t.kap = A["kap"]!; t.alphaw = A["alphaw"]!
        t.jw = A["jw"]!; t.jl = A["jl"]!; t.jn = A["jn"]!
        t.chg = A["chg"]!; t.zdrv = A["zdrv"]!; t.zi = A["zi"]!
        t.twt = A["twt"]!
        t.ba1 = A["ba1"]!; t.ba2 = A["ba2"]!; t.bn0 = A["bn0"]!
        t.bA = A["bA"]!; t.bC = A["bC"]!
        t.scalars = meta.scalars

        let f0 = A["f0"]!, vb = A["vb"]!, fb = A["fb"]!
        let beta = A["beta"]!, gate = A["gate"]!
        let refY96 = A["ref_y96"]!, refPost = A["ref_post"]!
        let n96 = meta.n96
        let n48 = n96 / meta.osf

        // ---- 1) kernel section: streaming chunks must be BIT-EXACT ----
        let s = meta.scalars
        XCTAssertEqual(s.count, 61)
        let L32 = meta.L.map { Int32($0) }
        let xvZero = [Double](repeating: 0, count: 2048)
        let st = bow_init(
            meta.srk, Int32(meta.nv), L32,
            t.cs, t.cp, t.w0, t.w1, t.w2, t.w3, t.w4, t.g, t.lpA, t.wout,
            t.kap, t.alphaw, t.jw, t.jl, t.jn, t.chg, t.zdrv, t.zi, t.twt,
            Int32(meta.K), t.ba1, t.ba2, t.bn0, t.bA, t.bC,
            s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9],
            s[10], s[11], s[12], s[13], s[14], s[15], s[16], s[17], s[18],
            s[19], s[20], s[21], s[22], s[23], s[24], s[25], s[26], s[27],
            s[28], s[29], s[30], s[31], s[32], s[33], s[34], s[35], s[36],
            s[37], s[38], s[39], s[40], s[41], s[42], s[43], s[44], s[45], s[46], s[47], s[48], s[49], s[50], s[51], s[52], s[53], s[54], s[55],
            s[56], s[57], s[58], s[59], s[60])
        defer { bow_free(st) }
        var kernelMaxErr = 0.0
        var oc = [Double](repeating: 0, count: 2048)
        var pos = 0
        while pos < n96 {
            let m = min(2048, n96 - pos)
            let f0c = Array(f0[pos ..< pos + m])
            let vbc = Array(vb[pos ..< pos + m])
            let fbc = Array(fb[pos ..< pos + m])
            let bec = Array(beta[pos ..< pos + m])
            let gac = Array(gate[pos ..< pos + m])
            bow_process(st, Int32(m), f0c, vbc, fbc, bec, gac, xvZero, &oc)
            for i in 0..<m {
                let e = abs(oc[i] - refY96[pos + i])
                if e > kernelMaxErr { kernelMaxErr = e }
            }
            pos += m
        }
        // Same C source, but the Python reference ran through the `cc -O3`
        // dylib while SwiftPM compiles CBowKernel with its own flags — FP
        // contraction differs between the two COMPILATIONS, so "bit-exact"
        // holds within one binary (streaming == one-shot, asserted in
        // BowKernelParityTests) and cross-binary parity carries the same
        // 1e-12 bar that gate uses (measured 4.8e-14 over 10 s — bounded,
        // the loop is dissipative).
        XCTAssertLessThan(kernelMaxErr, 1e-12,
                          "kernel section diverged (maxErr \(kernelMaxErr))")

        // ---- 2) full live buffer path: BowEngine, 1024-sample buffers ----
        var bp = BowParams()
        bp.num["bow_os"] = Double(meta.osf)
        let engine = BowEngine(tables: t, mapper: BowControlMapper(), bp: bp,
                               sr: meta.sr, rfir: A["rfir48"]!, eLp: meta.e_lp,
                               reverbRT60: 1.2, reverbPredelayMs: 20.0,
                               reverbMix: 0.0, reverbWidth: 0.0,
                               maxFrames: 1024)
        var outMono = [Double](repeating: 0, count: n48)
        var bufL = [Double](repeating: 0, count: 1024)
        var bufR = [Double](repeating: 0, count: 1024)
        var done = 0
        while done < n48 {
            let n = min(1024, n48 - done)
            let k0 = done * meta.osf
            let kn = n * meta.osf
            engine.renderFixture(
                f0: Array(f0[k0 ..< k0 + kn]), vb: Array(vb[k0 ..< k0 + kn]),
                fb: Array(fb[k0 ..< k0 + kn]), beta: Array(beta[k0 ..< k0 + kn]),
                gate: Array(gate[k0 ..< k0 + kn]),
                outL: &bufL, outR: &bufR)
            for i in 0..<n { outMono[done + i] = bufL[i] + bufR[i] }
            done += n
        }

        // compensate the half-band's integer group delay (16 @48k) and
        // measure the residual vs the scipy-decimated reference
        let delay = HalfBandDecimator.outputDelay
        let nCmp = n48 - delay
        var maxErr = 0.0
        var errSq = 0.0, refSq = 0.0
        for m in 0..<nCmp {
            let e = outMono[m + delay] - refPost[m]
            if abs(e) > maxErr { maxErr = abs(e) }
            errSq += e * e
            refSq += refPost[m] * refPost[m]
        }
        let rmsDB = 10.0 * log10(errSq / max(refSq, 1e-30))
        let refRMS = (refSq / Double(nCmp)).squareRoot()
        let peakDB = 20.0 * log10(maxErr / max(refRMS, 1e-30))
        print(String(format: "bow live e2e: kernel maxErr %.3e | final " +
                     "residual %.1f dB rms (peak %.1f dB, maxAbs %.3e over " +
                     "%d samples)", kernelMaxErr, rmsDB, peakDB, maxErr, nCmp))
        // −60 dB class expected from the decimator representation; gate at
        // −40 so a real plumbing regression fails loudly without flaking on
        // filter-design tweaks
        XCTAssertLessThan(rmsDB, -40.0, "post-chain residual too large")
    }
}
