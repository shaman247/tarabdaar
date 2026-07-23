import Accelerate
import Foundation

/// One analysed spectrum: dB magnitude on a fixed log-frequency grid that lines
/// up with the EQ view's `log2`-x axis. `db[i]` corresponds to
/// `SpectrumAnalyzer.binFreqs[i]`. dB is raw (un-referenced) — the
/// `SpectrumProvider` applies the adaptive reference + display floor.
public struct SpectrumFrame: Sendable {
    public let db: [Double]
    public init(db: [Double]) { self.db = db }
}

/// Broadband magnitude analyzer for the live FX-stage spectra. Hann-windows a
/// time-ordered ring, runs a vDSP real FFT, converts to dB, then **max-pools**
/// onto a fixed log-frequency grid (`binFreqs`) so it overlays the EQ curve
/// directly. Reusable: the FFT setup + split-complex scratch are allocated ONCE
/// (the setup is the expensive part) and reused across calls and stages. NOT
/// thread-safe (shared scratch) — drive all `analyze` calls from one serial
/// queue (see `SpectrumProvider`). **Starpad-local** (display only).
public final class SpectrumAnalyzer {
    /// Log-frequency display grid (matches the EQ x-axis: 20 Hz–20 kHz).
    public static let lowHz = 20.0
    public static let highHz = 20_000.0
    public static let binCount = 220
    public static let binFreqs: [Double] = {
        let lo = log2(lowHz), hi = log2(highHz)
        return (0..<binCount).map { pow(2.0, lo + (hi - lo) * Double($0) / Double(binCount - 1)) }
    }()

    private let n: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetupD
    private var window: [Double]
    private var windowed: [Double]
    private let realp: UnsafeMutablePointer<Double>
    private let imagp: UnsafeMutablePointer<Double>

    /// `size` must be a power of two (the ring length, e.g. `SarangiEngine.fxRingLength`).
    public init(size: Int) {
        n = size
        half = size / 2
        log2n = vDSP_Length(log2(Double(size)).rounded())
        fftSetup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
        window = [Double](repeating: 0, count: size)
        vDSP_hann_windowD(&window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        windowed = [Double](repeating: 0, count: size)
        realp = .allocate(capacity: half)
        imagp = .allocate(capacity: half)
        realp.initialize(repeating: 0, count: half)
        imagp.initialize(repeating: 0, count: half)
    }
    deinit {
        vDSP_destroy_fftsetupD(fftSetup)
        realp.deallocate(); imagp.deallocate()
    }

    /// Analyse one time-ordered ring → raw dB on the log grid (length `binCount`,
    /// aligned to `binFreqs`). `floorDb` is a hard guard only; the perceptual
    /// floor is applied later against the adaptive reference.
    public func analyze(_ ring: [Double], sr: Double, floorDb: Double = -160) -> SpectrumFrame {
        // 1. Window into `windowed`, clamping any non-finite input (a single NaN
        //    would poison the whole transform).
        for i in 0..<n {
            let v = ring[i]
            windowed[i] = (v.isFinite ? v : 0) * window[i]
        }
        // 2. Pack the real signal into split complex (even→realp, odd→imagp).
        var split = DSPDoubleSplitComplex(realp: realp, imagp: imagp)
        windowed.withUnsafeBufferPointer { wp in
            wp.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) { cp in
                vDSP_ctozD(cp, 2, &split, 1, vDSP_Length(half))
            }
        }
        // 3. Forward real FFT (in place on realp/imagp).
        vDSP_fft_zripD(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        // 4. Per-FFT-bin linear magnitude. Bin 0 (DC, with Nyquist packed into its
        //    imag) sits below 20 Hz and is excluded by the grid, so leave it raw.
        //    vDSP packs the forward real FFT at 2× — scale by 1/(2N) for a sane
        //    absolute level (the adaptive reference absorbs the exact constant).
        let scale = 1.0 / Double(2 * n)
        var mag = [Double](repeating: 0, count: half)
        for k in 0..<half {
            let re = realp[k], im = imagp[k]
            mag[k] = (re * re + im * im).squareRoot() * scale
        }
        // 5. Max-pool onto the log grid. Each output bin owns the FFT bins whose
        //    centre falls in its geometric-midpoint band; sparse low bands (which
        //    span <1 FFT bin) sample the nearest FFT bin. Peaks survive (better
        //    than averaging for a spectrum display).
        let freqs = SpectrumAnalyzer.binFreqs
        let m = freqs.count
        let hzPerBin = sr / Double(n)
        var out = [Double](repeating: floorDb, count: m)
        for i in 0..<m {
            let fLo = i == 0 ? freqs[0] : (freqs[i - 1] * freqs[i]).squareRoot()
            let fHi = i == m - 1 ? freqs[m - 1] : (freqs[i] * freqs[i + 1]).squareRoot()
            var kLo = Int((fLo / hzPerBin).rounded(.down))
            var kHi = Int((fHi / hzPerBin).rounded(.up))
            if kHi <= kLo { kLo = Int((freqs[i] / hzPerBin).rounded()); kHi = kLo + 1 }  // nearest
            kLo = max(1, kLo); kHi = min(half, kHi)
            var peak = 0.0
            if kLo < kHi { for k in kLo..<kHi where mag[k] > peak { peak = mag[k] } }
            out[i] = max(floorDb, 20 * log10(max(peak, 1e-12)))
        }
        return SpectrumFrame(db: out)
    }
}
