import Foundation
import CBowKernel

// The FX rack's four insert points: staging settings from the control
// thread, the per-chunk smoother tick, and the kernel's voice→taraf
// drive hook.
extension BowEngine {
    /// Stage one FX insert point's settings (control thread); adopted at
    /// the next chunk boundary. All-off is byte-null.
    public func setFX(_ point: FXPoint, _ settings: FXSettings) {
        os_unfair_lock_lock(&tiltLock)
        fxPending[point.rawValue] = settings
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
            for i in fxUnits.indices { fxUnits[i].retarget(staged[i]) }
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
