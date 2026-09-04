import Foundation
import CBowKernel

/// One insert point's staged state: the settings and the EQ design
/// realised from them (already scaled by `eqAmount`, identity when off).
public struct FXStaged: Sendable {
    public var settings = FXSettings()
    public var design = EQDesign()
    public init() {}
}

// The FX rack's four insert points: staging settings from the control
// thread, the per-chunk smoother tick, and the kernel's voice→taraf
// drive hook.
extension BowEngine {
    /// The rate the point's insert runs at: kernel rate on the split
    /// buses, engine rate for the global point.
    public func fxRate(_ point: FXPoint) -> Double {
        point == .global ? sr : sr * Double(osFactor)
    }

    /// Stage one FX insert point's settings (control thread); adopted at
    /// the next chunk boundary. All-off is byte-null.
    ///
    /// The EQ curve is FITTED here, off the render thread (`EQCurve.design`
    /// allocates), and cached per point set so the amount knob — a tilt
    /// target — only rescales a finished design.
    public func setFX(_ point: FXPoint, _ settings: FXSettings) {
        let i = point.rawValue
        var design = EQDesign()
        if settings.eqOn, settings.eqAmount > 0, !settings.eqPoints.isEmpty {
            os_unfair_lock_lock(&tiltLock)
            let cached = fxDesignCache[i]
            os_unfair_lock_unlock(&tiltLock)
            let full: EQDesign
            if let cached, cached.points == settings.eqPoints {
                full = cached.design
            } else {
                full = EQCurve.design(settings.eqPoints, sr: fxRate(point))
            }
            design = full.scaled(by: settings.eqAmount)
            os_unfair_lock_lock(&tiltLock)
            fxDesignCache[i] = (settings.eqPoints, full)
            os_unfair_lock_unlock(&tiltLock)
        }
        os_unfair_lock_lock(&tiltLock)
        fxPending[i].settings = settings
        fxPending[i].design = design
        fxDirty = true
        os_unfair_lock_unlock(&tiltLock)
    }

    /// Per-chunk FX update (render thread): adopt staged settings, advance
    /// smoothers. `nk` = kernel-rate chunk, `n48` = engine-rate (global).
    func updateFX(nk: Int, n48: Int) {
        os_unfair_lock_lock(&tiltLock)
        let dirty = fxDirty
        let staged = dirty ? fxPending : []
        fxDirty = false
        os_unfair_lock_unlock(&tiltLock)
        if dirty {
            for i in fxUnits.indices {
                fxUnits[i].retarget(staged[i].settings, design: staged[i].design)
            }
        }
        fxUnits[FXPoint.drive.rawValue].tick(frames: nk)
        fxUnits[FXPoint.voice.rawValue].tick(frames: nk)
        fxUnits[FXPoint.taraf.rawValue].tick(frames: nk)
        fxUnits[FXPoint.global.rawValue].tick(frames: n48)
    }

    /// Called by the kernel's drive hook with the recorded jt-drive block
    /// (render thread, kernel rate) — the voice→taraf insert.
    fileprivate func fxProcessDrive(_ buf: UnsafeMutablePointer<Double>,
                                    _ n: Int) {
        fxUnits[FXPoint.drive.rawValue].processMono(buf, n)
    }
}

/// C trampoline for the kernel's drive FX hook; ctx = the unretained BowEngine.
func bowEngineDriveFXHook(_ ctx: UnsafeMutableRawPointer?,
                          _ buf: UnsafeMutablePointer<Double>?,
                          _ n: Int32) {
    guard let ctx, let buf, n > 0 else { return }
    Unmanaged<BowEngine>.fromOpaque(ctx).takeUnretainedValue()
        .fxProcessDrive(buf, Int(n))
}
