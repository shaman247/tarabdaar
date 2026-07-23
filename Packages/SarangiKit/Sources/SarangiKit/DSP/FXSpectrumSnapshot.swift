import Foundation

/// A pure-data snapshot of the two **pre-EQ** mono signals feeding the per-voice
/// FX stages (Pre-drive / Global), copied under the host lock so the broadband
/// FFT can run off-lock (mirrors `BankRawSnapshot`'s "copy cheap, analyse
/// off-lock" contract). Each array is time-ordered (oldest first), length
/// `SarangiEngine.fxRingLength`. The post-EQ spectrum is NOT captured — the UI
/// derives it analytically as `pre-dB + the EQ curve` (so it always matches the
/// drawn response and needs no second tap). **Starpad-local** (display only).
/// (The v57 re-vendor removed the violin/sym streams — the passive coupled
/// network has ONE output; only the pre-drive and global stages remain.)
public struct FXSpectrumSnapshot: Sendable {
    public let sr: Double
    public let violinPre: [Double] // pre-violinPreFX mono (raw drive)
    public let global: [Double]    // pre-globalFX mono mid (m)
    public init(sr: Double, violinPre: [Double], global: [Double]) {
        self.sr = sr; self.violinPre = violinPre; self.global = global
    }
}
