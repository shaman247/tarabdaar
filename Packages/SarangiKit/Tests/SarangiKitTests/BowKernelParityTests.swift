import XCTest
import CBowKernel

/// Bow-friction kernel parity: the Swift app compiles the SAME C source as the
/// offline Python render (src/bowstring.py C_SRC → Sources/CBowKernel, symbol
/// `render` → `bow_kernel_render`). This feeds the kernel the EXACT marshaled
/// inputs the Python render used for pair 3 (a short window) and asserts the
/// Swift-driven kernel reproduces the output bit-for-bit — via the one-shot
/// entry point AND via the streaming API (bow_init / bow_process chunks /
/// bow_free), which must concatenate to the identical signal. Regenerate the
/// golden FROM THE REPO ROOT (both paths below are root-relative) with:
///   SARANGI_KERNEL_MAXN=29000 \
///   SARANGI_DUMP_KERNEL=app/Tests/SarangiKitTests/Goldens/bow_kernel_pair3 \
///   python3 -c "import sys;sys.path.insert(0,'src');import bowstring as b;\
///     b.render_bow_pair(3,n_bow=1.0,verbose=False)"
/// MAXN is what keeps this a WINDOW: it truncates the controls only (the
/// voice/body tables are built full-size), so the dump is the exact pair-3
/// render on the first 29000 samples. Dropping it dumps the whole 24.9 s
/// take — 7 full-length arrays, a 133 MB blob into git history. The regen is
/// correct only if it lands n == 29000 and a 1,632,032-byte .bin; anything
/// else means the cap did not apply.
final class BowKernelParityTests: XCTestCase {

    struct ArrSpec: Decodable { let name: String; let len: Int }
    struct Meta: Decodable {
        let n: Int; let sr: Double; let nv: Int; let K: Int
        let L: [Int]; let scalars: [Double]; let arrays: [ArrSpec]
    }

    /// Load the golden: JSON meta + raw little-endian float64 blob, sliced
    /// into named arrays in the exact dump order.
    private func loadGolden() throws -> (meta: Meta, A: [String: [Double]]) {
        guard let jURL = Bundle.module.url(forResource: "bow_kernel_pair3",
                                           withExtension: "json",
                                           subdirectory: "Goldens"),
              let bURL = Bundle.module.url(forResource: "bow_kernel_pair3",
                                           withExtension: "bin",
                                           subdirectory: "Goldens") else {
            throw XCTSkip("bow_kernel_pair3 golden not found — run the exporter")
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
        return (meta, A)
    }

    /// One-shot render over the golden inputs (the exact C-signature call:
    /// 19 per-voice arrays incl. chg/zdrv/zi/twt, 5 body arrays, 52 scalars).
    private func renderOneShot(_ meta: Meta, _ A: [String: [Double]]) -> [Double] {
        let f0 = A["f0"]!, vb = A["vb"]!, fb = A["fb"]!, beta = A["beta"]!
        let gate = A["gate"]!, xv = A["xv"]!
        let cs = A["cs"]!, cp = A["cp"]!, w0 = A["w0"]!, w1 = A["w1"]!
        let w2 = A["w2"]!, w3 = A["w3"]!, w4 = A["w4"]!, g = A["g"]!
        let lpA = A["lpA"]!, wout = A["wout"]!, kap = A["kap"]!
        let alphaw = A["alphaw"]!, jw = A["jw"]!, jl = A["jl"]!, jn = A["jn"]!
        let chg = A["chg"]!, zdrv = A["zdrv"]!, zi = A["zi"]!
        let twt = A["twt"]!
        let ba1 = A["ba1"]!, ba2 = A["ba2"]!, bn0 = A["bn0"]!
        let bA = A["bA"]!, bC = A["bC"]!
        let L = meta.L.map { Int32($0) }
        let s = meta.scalars
        XCTAssertEqual(s.count, 61)
        var out = [Double](repeating: 0, count: meta.n)

        bow_kernel_render(
            Int32(meta.n), meta.sr,
            f0, vb, fb, beta, gate, xv,
            Int32(meta.nv), L,
            cs, cp, w0, w1, w2, w3, w4, g, lpA, wout, kap, alphaw, jw, jl, jn,
            chg, zdrv, zi, twt,
            Int32(meta.K), ba1, ba2, bn0, bA, bC,
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

    func testBowKernelParity() throws {
        let (meta, A) = try loadGolden()
        let ref = A["out"]!
        let out = renderOneShot(meta, A)

        var maxErr = 0.0
        for i in 0 ..< meta.n { maxErr = max(maxErr, abs(out[i] - ref[i])) }
        // same C source, float64 throughout → expect bit-identical.
        XCTAssertLessThan(maxErr, 1e-12,
                          "bow kernel diverged from Python (maxErr \(maxErr))")
    }

    /// Streaming parity: bow_init + chunked bow_process must concatenate to
    /// the EXACT one-shot output (all cross-sample state lives in the C
    /// bow_state_t; the loop has no absolute-time dependence). Verified
    /// bit-exact on the Python side; assert the same here.
    func testBowKernelStreamingParity() throws {
        let (meta, A) = try loadGolden()
        let ref = A["out"]!
        let oneShot = renderOneShot(meta, A)

        let f0 = A["f0"]!, vb = A["vb"]!, fb = A["fb"]!, beta = A["beta"]!
        let gate = A["gate"]!, xv = A["xv"]!
        let cs = A["cs"]!, cp = A["cp"]!, w0 = A["w0"]!, w1 = A["w1"]!
        let w2 = A["w2"]!, w3 = A["w3"]!, w4 = A["w4"]!, g = A["g"]!
        let lpA = A["lpA"]!, wout = A["wout"]!, kap = A["kap"]!
        let alphaw = A["alphaw"]!, jw = A["jw"]!, jl = A["jl"]!, jn = A["jn"]!
        let chg = A["chg"]!, zdrv = A["zdrv"]!, zi = A["zi"]!
        let twt = A["twt"]!
        let ba1 = A["ba1"]!, ba2 = A["ba2"]!, bn0 = A["bn0"]!
        let bA = A["bA"]!, bC = A["bC"]!
        let L = meta.L.map { Int32($0) }
        let s = meta.scalars
        XCTAssertEqual(s.count, 61)

        let st = bow_init(
            meta.sr,
            Int32(meta.nv), L,
            cs, cp, w0, w1, w2, w3, w4, g, lpA, wout, kap, alphaw, jw, jl, jn,
            chg, zdrv, zi, twt,
            Int32(meta.K), ba1, ba2, bn0, bA, bC,
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

        let chunk = 1024
        var streamed = [Double](repeating: 0, count: meta.n)
        var base = 0
        while base < meta.n {
            let m = min(chunk, meta.n - base)
            let f0c = Array(f0[base ..< base + m])
            let vbc = Array(vb[base ..< base + m])
            let fbc = Array(fb[base ..< base + m])
            let betac = Array(beta[base ..< base + m])
            let gatec = Array(gate[base ..< base + m])
            let xvc = Array(xv[base ..< base + m])
            var oc = [Double](repeating: 0, count: m)
            bow_process(st, Int32(m), f0c, vbc, fbc, betac, gatec, xvc, &oc)
            streamed.replaceSubrange(base ..< base + m, with: oc)
            base += m
        }

        // streaming == one-shot must be BIT-IDENTICAL (same state machine,
        // chunk staging is exact double loads/stores).
        var maxErrOS = 0.0
        for i in 0 ..< meta.n {
            maxErrOS = max(maxErrOS, abs(streamed[i] - oneShot[i]))
        }
        XCTAssertEqual(maxErrOS, 0.0,
                       "streaming diverged from one-shot (maxErr \(maxErrOS))")

        // and both match the Python golden.
        var maxErr = 0.0
        for i in 0 ..< meta.n { maxErr = max(maxErr, abs(streamed[i] - ref[i])) }
        XCTAssertLessThan(maxErr, 1e-12,
                          "streamed kernel diverged from Python (maxErr \(maxErr))")
    }
}
