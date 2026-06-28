import AVFoundation
import Foundation

/// Per-buffer DSP closure installed on `SarangiProcessorAU` by `AudioEngine`.
/// Runs on the realtime render thread. `inL`/`inR` are the pulled upstream
/// (summed SWAM) stereo input; `outL`/`outR` are the effect's stereo output;
/// `frames` is the block size (always <= the buffer's capacity).
typealias SarangiProcessBlock = (
    _ inL: UnsafePointer<Float>, _ inR: UnsafePointer<Float>,
    _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>,
    _ frames: Int) -> Void

/// In-process AUv3 effect that runs an installed per-buffer DSP closure on its
/// input. It is spliced **inline** into the graph directly after the hosted
/// SWAM AU(s):  `hostedDriveTap → SarangiProcessorAU → symGain → mainMixer`.
///
/// This replaces the old `installTap(bufferSize: 4096) → SPSCAudioRing →
/// separate AVAudioSourceNode` transport, which decoupled SWAM's output from the
/// model render across two async clocks and added ~140 ms of latency (a 4096-
/// frame tap-accumulation window plus the ring producer/consumer phase offset),
/// audible even in pass-through. As an inline effect the model runs in the SAME
/// render pull as SWAM — zero added latency vs. playing the SWAM AU directly.
///
/// The node holds **no** model state. `AudioEngine` installs `processBlock`,
/// whose closure captures `AudioEngine` and runs `SarangiEngine.renderSample`
/// under `AudioEngine`'s own lock — the exact body the old source node ran,
/// minus the ring read.
final class SarangiProcessorAU: AUAudioUnit {

    /// Per-buffer model render, set by `AudioEngine` after instantiation and
    /// before the node is connected into the pulled graph. Read on the render
    /// thread; written once on the main thread.
    var processBlock: SarangiProcessBlock?

    private let _inputBus: AUAudioUnitBus
    private let _outputBus: AUAudioUnitBus
    private var _inputBusArray: AUAudioUnitBusArray!
    private var _outputBusArray: AUAudioUnitBusArray!

    /// Private scratch the engine's pull writes the upstream (SWAM) input into,
    /// so we never pull into the output ABL (avoids in-place clobber). Sized in
    /// `allocateRenderResources` from the host-set `maximumFramesToRender`.
    private var inputScratch: AVAudioPCMBuffer?

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        // Deinterleaved Float32 stereo at the app sample rate — matches the old
        // source-node format and the `format` used on the graph connections.
        let fmt = AVAudioFormat(standardFormatWithSampleRate: Config.sampleRate,
                                channels: 2)!
        _inputBus = try AUAudioUnitBus(format: fmt)
        _outputBus = try AUAudioUnitBus(format: fmt)
        _inputBus.maximumChannelCount = 2
        _outputBus.maximumChannelCount = 2
        try super.init(componentDescription: componentDescription, options: options)
        _inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input,
                                             busses: [_inputBus])
        _outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output,
                                              busses: [_outputBus])
        // Default; the host (AVAudioEngine) overrides this to its render quantum
        // before `allocateRenderResources`, which is where the scratch is sized.
        maximumFramesToRender = 4096
    }

    // The host caches these arrays — must return the SAME instances every call.
    override var inputBusses: AUAudioUnitBusArray { _inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { _outputBusArray }
    // We pull into a private scratch, never in place.
    override var canProcessInPlace: Bool { false }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        // Size from the host-negotiated input format + the host-set max frames,
        // so a render quantum larger than our default can't overrun the pull.
        guard let buf = AVAudioPCMBuffer(pcmFormat: _inputBus.format,
                                         frameCapacity: maximumFramesToRender) else {
            NSLog("Starpad: SarangiProcessorAU allocateRenderResources FAILED to make scratch")
            throw NSError(domain: "Starpad",
                          code: Int(kAudioUnitErr_FailedInitialization))
        }
        buf.frameLength = maximumFramesToRender
        inputScratch = buf
    }

    override func deallocateRenderResources() {
        inputScratch = nil
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        // `unowned(unsafe) self` — no per-render ARC traffic; the AU outlives
        // rendering (engine.stop() precedes any teardown).
        return { [unowned(unsafe) self] _, timestamp, frameCount,
                 _, outputData, _, pullInputBlock in
            let frames = Int(frameCount)
            let outABL = UnsafeMutableAudioBufferListPointer(outputData)

            @inline(__always) func zeroOutput() {
                for b in 0..<outABL.count {
                    if let p = outABL[b].mData {
                        memset(p, 0, Int(outABL[b].mDataByteSize))
                    }
                }
            }

            guard let pull = pullInputBlock,
                  let scratch = self.inputScratch,
                  frames <= Int(scratch.frameCapacity) else {
                zeroOutput(); return noErr
            }

            // Pull the upstream (summed SWAM) audio into our own scratch ABL.
            let inABLPtr = scratch.mutableAudioBufferList
            let inABL = UnsafeMutableAudioBufferListPointer(inABLPtr)
            let byteCount = UInt32(frames) * UInt32(MemoryLayout<Float>.size)
            for b in 0..<inABL.count { inABL[b].mDataByteSize = byteCount }
            var pullFlags = AudioUnitRenderActionFlags(rawValue: 0)
            let st = pull(&pullFlags, timestamp, frameCount, 0, inABLPtr)
            if st != noErr { zeroOutput(); return st }

            // Resolve input channel pointers (read back from the ABL the pull
            // filled — robust whether the producer wrote our mData or swapped
            // in its own). Deinterleaved stereo => 2 buffers; mono => 1 (fed to
            // both); anything unexpected => silence (never crash).
            guard inABL.count >= 1,
                  let inLp = inABL[0].mData?.assumingMemoryBound(to: Float.self) else {
                zeroOutput(); return noErr
            }
            let inRp = (inABL.count >= 2
                        ? inABL[1].mData?.assumingMemoryBound(to: Float.self)
                        : inLp) ?? inLp

            // Resolve output channel pointers.
            guard outABL.count >= 1,
                  let outLp = outABL[0].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let outRp = (outABL.count >= 2
                         ? outABL[1].mData?.assumingMemoryBound(to: Float.self)
                         : outLp) ?? outLp

            if let process = self.processBlock {
                process(inLp, inRp, outLp, outRp, frames)
            } else {
                // Silence until AudioEngine installs the model closure.
                for i in 0..<frames { outLp[i] = 0; outRp[i] = 0 }
            }
            return noErr
        }
    }
}

// MARK: - In-process registration

/// AudioComponentDescription for the in-process sarangi effect. Custom 4-char
/// codes unlikely to collide with any installed AU.
let sarangiAUComponentDescription = AudioComponentDescription(
    componentType: kAudioUnitType_Effect,
    componentSubType: sarangiFourCC("Srng"),
    componentManufacturer: sarangiFourCC("Strp"),
    componentFlags: 0,
    componentFlagsMask: 0)

private var sarangiAURegistered = false
private let sarangiAURegisterLock = NSLock()

/// Register `SarangiProcessorAU` as an in-process AU exactly once. Registering
/// the same description twice in a process is unsafe.
func registerSarangiAUOnce() {
    sarangiAURegisterLock.lock()
    defer { sarangiAURegisterLock.unlock() }
    guard !sarangiAURegistered else { return }
    AUAudioUnit.registerSubclass(SarangiProcessorAU.self,
                                 as: sarangiAUComponentDescription,
                                 name: "Starpad: Sarangi",
                                 version: 1)
    sarangiAURegistered = true
}

/// Pack up to 4 ASCII chars into a UInt32 OSType.
func sarangiFourCC(_ s: String) -> UInt32 {
    var result: UInt32 = 0
    for byte in s.utf8.prefix(4) { result = (result << 8) + UInt32(byte) }
    return result
}
