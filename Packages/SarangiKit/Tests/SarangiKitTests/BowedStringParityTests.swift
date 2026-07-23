import XCTest
import CBowKernel

/// Generic bowed-string kernel parity: the pure-physics instrument is the
/// SAME C kernel driven by FORMULA tables — analytic taraf voices (nv) and
/// analytic body modes (K), no fitted artifacts — this replays the python
/// golden (gutstring.render with SARANGI_DUMP_KERNEL) and asserts bit-parity
/// via the one-shot AND the streaming entry points. The scalar count moves
/// with every kernel round (58 since 2026-07-19d: …hairHz/Ref, crW/crMs) —
/// read it off the golden json + BowEngine's precondition, and regenerate
/// the golden with:
///   python3 scripts/export_bowed_string_golden.py
final class BowedStringParityTests: XCTestCase {

    struct ArrSpec: Decodable { let name: String; let len: Int }
    struct Meta: Decodable {
        let n: Int; let sr: Double; let nv: Int; let K: Int
        let L: [Int]; let scalars: [Double]; let arrays: [ArrSpec]
    }

    private func loadGolden() throws -> (meta: Meta, A: [String: [Double]]) {
        guard let jURL = Bundle.module.url(forResource: "bow_kernel_string",
                                           withExtension: "json",
                                           subdirectory: "Goldens"),
              let bURL = Bundle.module.url(forResource: "bow_kernel_string",
                                           withExtension: "bin",
                                           subdirectory: "Goldens") else {
            throw XCTSkip("bow_kernel_string golden not found — run the exporter")
        }
        let meta = try JSONDecoder().decode(Meta.self,
                                            from: Data(contentsOf: jURL))
        let binData = try Data(contentsOf: bURL)
        let blob: [Double] = binData.withUnsafeBytes {
            Array($0.bindMemory(to: Double.self))
        }
        var off = 0
        var A: [String: [Double]] = [:]
        for spec in meta.arrays {
            A[spec.name] = Array(blob[off ..< off + spec.len]); off += spec.len
        }
        XCTAssertEqual(off, blob.count, "golden blob length mismatch")
        // nv > 0 since the FORMULA TARAF (2026-07-16d) and K > 0 since the
        // FORMULA BODY (2026-07-16b) — analytic voices/modes, not fitted;
        // the golden carries the python-built tables verbatim
        return (meta, A)
    }

    private func renderOneShot(_ meta: Meta, _ A: [String: [Double]]) -> [Double] {
        XCTAssertEqual(meta.scalars.count, 61)
        return render(meta, A, s: meta.scalars, n: meta.n)
    }

    /// One-shot render over the golden tables with an explicit scalar list
    /// and sample count — the null-law probes swap single scalars.
    private func render(_ meta: Meta, _ A: [String: [Double]],
                        s: [Double], n: Int) -> [Double] {
        let L = meta.L.map { Int32($0) }
        var out = [Double](repeating: 0, count: n)
        bow_kernel_render(
            Int32(n), meta.sr,
            A["f0"]!, A["vb"]!, A["fb"]!, A["beta"]!, A["gate"]!, A["xv"]!,
            Int32(meta.nv), L,
            A["cs"]!, A["cp"]!, A["w0"]!, A["w1"]!, A["w2"]!, A["w3"]!,
            A["w4"]!, A["g"]!, A["lpA"]!,
            A["wout"]!, A["kap"]!, A["alphaw"]!, A["jw"]!, A["jl"]!, A["jn"]!,
            A["chg"]!, A["zdrv"]!, A["zi"]!, A["twt"]!,
            Int32(meta.K), A["ba1"]!, A["ba2"]!, A["bn0"]!, A["bA"]!, A["bC"]!,
            s[0], s[1], s[2],
            s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11],
            s[12], s[13], s[14],
            s[15], s[16], s[17], s[18], s[19], s[20], s[21],
            s[22], s[23], s[24], s[25],
            s[26], s[27], s[28], s[29],
            s[30], s[31], s[32],
            s[33], s[34], s[35], s[36], s[37],
            s[38], s[39], s[40],
            s[41], s[42], s[43], s[44], s[45], s[46],
            s[47], s[48], s[49], s[50], s[51], s[52], s[53], s[54], s[55],
            s[56], s[57], s[58], s[59], s[60],
            &out)
        return out
    }

    func testStringKernelParity() throws {
        let (meta, A) = try loadGolden()
        let ref = A["out"]!
        let out = renderOneShot(meta, A)
        var maxErr = 0.0
        for i in 0 ..< meta.n { maxErr = max(maxErr, abs(out[i] - ref[i])) }
        XCTAssertLessThan(maxErr, 1e-12,
                          "string kernel diverged from Python (maxErr \(maxErr))")
    }

    /// TORSIONAL LOOP NULL (2026-07-17, scalars 47-49): `bow_tors_c` 0 must
    /// leave the kernel BIT-IDENTICAL to its pre-torsion behaviour — with the
    /// coupling off, torsRatio/torsG must be dead scalars (the `torsC > 1e-9`
    /// gate covers the echo READ and the buffer WRITE). The armed leg is the
    /// anti-vacuity half: with c on, the same inputs must MOVE, or the null
    /// would merely prove the loop is unwired.
    func testTorsionalLoopIsBitNullAtZeroCoupling() throws {
        let (meta, A) = try loadGolden()
        let n = min(meta.n, 8000)
        var off = meta.scalars
        off[49] = 0.0                       // torsC — the coupling
        let base = render(meta, A, s: off, n: n)

        var swept = off
        swept[47] = 3.1                     // torsRatio: c_tors / c_transverse
        swept[48] = 0.9                     // torsG: round-trip loss
        let nulled = render(meta, A, s: swept, n: n)
        var maxErr = 0.0
        for i in 0 ..< n { maxErr = max(maxErr, abs(nulled[i] - base[i])) }
        XCTAssertEqual(maxErr, 0.0,
                       "torsion scalars are live at bow_tors_c 0 (maxErr \(maxErr))")

        var armed = swept
        armed[49] = 0.35                    // the fitted round-10 coupling
        let onOut = render(meta, A, s: armed, n: n)
        var diff = 0.0
        for i in 0 ..< n { diff = max(diff, abs(onOut[i] - base[i])) }
        XCTAssertGreaterThan(diff, 1e-9, "torsion coupling had no effect at all")
    }

    /// CONTACT-AGING NULL (2026-07-17g, scalars 50-51): `bow_age_a` 0 must be
    /// bit-null (the `ageA > 1e-12` gates), with `bow_age_ms` inert alongside.
    func testContactAgingIsBitNullAtZeroAmplitude() throws {
        let (meta, A) = try loadGolden()
        let n = min(meta.n, 8000)
        var off = meta.scalars
        off[50] = 0.0                       // ageAp
        let base = render(meta, A, s: off, n: n)

        var swept = off
        swept[51] = 4.0                     // ageMs — only feeds the decay rate
        let nulled = render(meta, A, s: swept, n: n)
        var maxErr = 0.0
        for i in 0 ..< n { maxErr = max(maxErr, abs(nulled[i] - base[i])) }
        XCTAssertEqual(maxErr, 0.0,
                       "aging scalars are live at bow_age_a 0 (maxErr \(maxErr))")

        var armed = swept
        armed[50] = 0.5
        let onOut = render(meta, A, s: armed, n: n)
        var diff = 0.0
        for i in 0 ..< n { diff = max(diff, abs(onOut[i] - base[i])) }
        XCTAssertGreaterThan(diff, 1e-9, "contact aging had no effect at all")
    }

    func testStringKernelStreamingParity() throws {
        let (meta, A) = try loadGolden()
        let ref = A["out"]!
        let oneShot = renderOneShot(meta, A)
        let L = meta.L.map { Int32($0) }
        let s = meta.scalars
        let st = bow_init(
            meta.sr, Int32(meta.nv), L,
            A["cs"]!, A["cp"]!, A["w0"]!, A["w1"]!, A["w2"]!, A["w3"]!,
            A["w4"]!, A["g"]!, A["lpA"]!,
            A["wout"]!, A["kap"]!, A["alphaw"]!, A["jw"]!, A["jl"]!, A["jn"]!,
            A["chg"]!, A["zdrv"]!, A["zi"]!, A["twt"]!,
            Int32(meta.K), A["ba1"]!, A["ba2"]!, A["bn0"]!, A["bA"]!, A["bC"]!,
            s[0], s[1], s[2],
            s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11],
            s[12], s[13], s[14],
            s[15], s[16], s[17], s[18], s[19], s[20], s[21],
            s[22], s[23], s[24], s[25],
            s[26], s[27], s[28], s[29],
            s[30], s[31], s[32],
            s[33], s[34], s[35], s[36], s[37],
            s[38], s[39], s[40],
            s[41], s[42], s[43], s[44], s[45], s[46],
            s[47], s[48], s[49], s[50], s[51], s[52], s[53], s[54], s[55],
            s[56], s[57], s[58], s[59], s[60])
        defer { bow_free(st) }

        let f0 = A["f0"]!, vb = A["vb"]!, fb = A["fb"]!, beta = A["beta"]!
        let gate = A["gate"]!, xv = A["xv"]!
        let chunk = 512
        var streamed = [Double](repeating: 0, count: meta.n)
        var base = 0
        while base < meta.n {
            let m = min(chunk, meta.n - base)
            var oc = [Double](repeating: 0, count: m)
            bow_process(st, Int32(m),
                        Array(f0[base ..< base + m]),
                        Array(vb[base ..< base + m]),
                        Array(fb[base ..< base + m]),
                        Array(beta[base ..< base + m]),
                        Array(gate[base ..< base + m]),
                        Array(xv[base ..< base + m]), &oc)
            streamed.replaceSubrange(base ..< base + m, with: oc)
            base += m
        }
        var maxErrOS = 0.0
        for i in 0 ..< meta.n {
            maxErrOS = max(maxErrOS, abs(streamed[i] - oneShot[i]))
        }
        XCTAssertEqual(maxErrOS, 0.0,
                       "streaming diverged from one-shot (maxErr \(maxErrOS))")
        var maxErr = 0.0
        for i in 0 ..< meta.n { maxErr = max(maxErr, abs(streamed[i] - ref[i])) }
        XCTAssertLessThan(maxErr, 1e-12,
                          "streamed string kernel diverged (maxErr \(maxErr))")
    }
}
