import Foundation
import os
import SarangiKit

/// An engine the crossfader can pull stereo blocks from.
public protocol StereoRenderEngine: AnyObject {
    func render(frames: Int, outL: UnsafeMutablePointer<Double>,
                outR: UnsafeMutablePointer<Double>)
}

public enum EngineCrossfade {
    /// Crossfade length when swapping engines (a fresh engine has no ringing
    /// state, so the outgoing one fades out instead of being cut).
    public static let defaultMs = 300.0
}

/// THE ENGINE SWAP shared by every voice source: the published engine, the
/// one crossfading out (it keeps rendering so its ring decays), the
/// equal-power fade and the retention of swapped-out engines past any
/// in-flight buffer. `publish` is the control thread's; `render` is the
/// audio callback's body and allocates nothing.
public final class EngineCrossfader<Engine: StereoRenderEngine>: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var engine: Engine?
    private var fading: Engine?
    private var fadePos = 0
    private var fadeLen = 0
    private let sr: Double
    private let maxFrames: Int
    private var bufL: [Double], bufR: [Double]
    /// Second buffer pair, used only while a crossfade is running.
    private var fadeL: [Double], fadeR: [Double]
    /// Strong refs keep swapped-out engines alive past any in-flight buffer
    /// — deep enough that a fading engine is never freed under the audio
    /// thread. Control thread only.
    private var recent: [Engine] = []

    public init(sr: Double, maxFrames: Int = 4096) {
        self.sr = sr
        self.maxFrames = maxFrames
        bufL = [Double](repeating: 0, count: maxFrames)
        bufR = [Double](repeating: 0, count: maxFrames)
        fadeL = [Double](repeating: 0, count: maxFrames)
        fadeR = [Double](repeating: 0, count: maxFrames)
    }

    /// Publish `engine` (nil silences). The outgoing engine crossfades out
    /// over `crossfadeMs`; a swap mid-fade restarts the fade from the
    /// audible engine.
    public func publish(_ engine: Engine?, crossfadeMs: Double) {
        if let engine {
            recent.append(engine)
            if recent.count > 8 { recent.removeFirst() }
        }
        os_unfair_lock_lock(&lock)
        let outgoing = self.engine
        if engine != nil, let outgoing, crossfadeMs > 0 {
            fading = outgoing
            fadeLen = max(1, Int(crossfadeMs * 0.001 * sr))
            fadePos = 0
        } else {
            fading = nil
            fadeLen = 0
            fadePos = 0
        }
        self.engine = engine
        os_unfair_lock_unlock(&lock)
    }

    /// The published engine (brief lock); nil unarmed.
    public var current: Engine? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return engine
    }

    public var isArmed: Bool { current != nil }

    /// Render `frames` into the outputs, equal-power crossfaded with the
    /// outgoing engine while a fade runs. False (outputs untouched) when
    /// no engine is published.
    @discardableResult
    public func render(frames n: Int, outL: UnsafeMutablePointer<Float>,
                       outR: UnsafeMutablePointer<Float>) -> Bool {
        os_unfair_lock_lock(&lock)
        let engine = self.engine
        let fading = self.fading
        os_unfair_lock_unlock(&lock)
        guard let engine else { return false }
        var done = 0
        while done < n {
            let m = min(maxFrames, n - done)
            bufL.withUnsafeMutableBufferPointer { lb in
                bufR.withUnsafeMutableBufferPointer { rb in
                    engine.render(frames: m, outL: lb.baseAddress!,
                                  outR: rb.baseAddress!)
                }
            }
            if let fading {
                // 2x voice CPU for the fade window only.
                fadeL.withUnsafeMutableBufferPointer { lb in
                    fadeR.withUnsafeMutableBufferPointer { rb in
                        fading.render(frames: m, outL: lb.baseAddress!,
                                      outR: rb.baseAddress!)
                    }
                }
                let len = max(fadeLen, 1)
                for i in 0..<m {
                    let t = min(Double(fadePos + i) / Double(len), 1.0)
                    let gIn = sin(t * Double.pi / 2)
                    let gOut = cos(t * Double.pi / 2)
                    outL[done + i] = Float(bufL[i] * gIn + fadeL[i] * gOut)
                    outR[done + i] = Float(bufR[i] * gIn + fadeR[i] * gOut)
                }
                fadePos += m
            } else {
                for i in 0..<m {
                    outL[done + i] = Float(bufL[i])
                    outR[done + i] = Float(bufR[i])
                }
            }
            done += m
        }
        if fading != nil, fadePos >= fadeLen {
            // Fade finished. `recent` still holds the object, so this never
            // deallocates on the audio thread.
            os_unfair_lock_lock(&lock)
            if self.fading === fading { self.fading = nil }
            os_unfair_lock_unlock(&lock)
        }
        return true
    }
}

extension BowEngine: StereoRenderEngine {}
extension TanpuraEngine: StereoRenderEngine {}
