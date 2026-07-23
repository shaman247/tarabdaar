import Combine
import Foundation
import SarangiKit

/// Publishes the live **pre-EQ** spectra for the two FX stages to the graphical
/// EQ. ONE instance (owned by `AppController`). Each EQ view registers itself
/// visible/hidden via `setVisible`; the provider runs a single 30 Hz timer while
/// ≥1 stage is visible, snapshots once per tick, and runs the FFT ONLY for
/// visible stages (no redundant work when a stage is collapsed). The FFT runs on
/// a background queue; smoothed, reference-relative frames publish on main.
///
/// Frames are **reference-relative dB** (`db[i] ≤ ~0`, 0 = the shared adaptive
/// peak): a slow-decaying reference shared across stages keeps them level-
/// comparable (they're consecutive points on one chain) and lets a quiet signal
/// still rise off the floor. The view maps these against its own display floor,
/// and derives the post-EQ overlay as `pre + the EQ curve`. **Starpad-local.**
public final class SpectrumProvider: ObservableObject {
    public enum Stage: Hashable, CaseIterable { case violinPre, global }

    @Published public private(set) var violinPre: SpectrumFrame?
    @Published public private(set) var global: SpectrumFrame?

    /// The log-frequency grid every published frame is sampled on (`db[i]` ↔ `binFreqs[i]`).
    public let binFreqs: [Double] = SpectrumAnalyzer.binFreqs

    private weak var audio: AudioEngine?
    private let analyzer = SpectrumAnalyzer(size: SarangiEngine.fxRingLength)
    private let queue = DispatchQueue(label: "starpad.spectrum", qos: .userInitiated)
    private var visible: Set<Stage> = []
    private var timer: AnyCancellable?

    // Queue-only state (touched solely inside `queue` closures → no extra lock).
    private var smooth: [Stage: [Double]] = [:]
    private var peakRefDb = -100.0
    private let alpha = 0.4               // one-pole temporal smoothing on raw dB
    private let refDecayDbPerTick = 0.08  // ~2.4 dB/s reference fall toward the floor
    private let refFloorDb = -100.0
    private let displaySpan = 70.0        // headroom below the reference the view can show

    public init(audio: AudioEngine) { self.audio = audio }

    /// Register/unregister a stage as visible. Starts the 30 Hz timer when the
    /// first stage appears; stops it (zero CPU) when none remain. Call from a
    /// view's expand/collapse + appear/disappear.
    public func setVisible(_ stage: Stage, _ on: Bool) {
        let was = !visible.isEmpty
        if on { visible.insert(stage) } else { visible.remove(stage); clearPublished(stage) }
        let now = !visible.isEmpty
        if now && !was { startTimer() }
        if !now && was { stopTimer() }
    }

    private func startTimer() {
        timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }
    private func stopTimer() { timer?.cancel(); timer = nil }

    private func clearPublished(_ stage: Stage) {
        switch stage {
        case .violinPre: violinPre = nil
        case .global: global = nil
        }
    }

    private func tick() {
        guard !visible.isEmpty, let snap = audio?.sarangiFXSpectrumSnapshot() else { return }
        let want = visible
        queue.async { [weak self] in
            guard let self else { return }
            var rawByStage: [Stage: [Double]] = [:]
            for stage in want {
                let ring: [Double]
                switch stage {
                case .violinPre: ring = snap.violinPre
                case .global: ring = snap.global
                }
                let raw = self.analyzer.analyze(ring, sr: snap.sr).db
                // One-pole smooth on raw dB.
                if let prev = self.smooth[stage], prev.count == raw.count {
                    for i in raw.indices { rawByStage[stage, default: raw][i] = self.alpha * raw[i] + (1 - self.alpha) * prev[i] }
                } else {
                    rawByStage[stage] = raw
                }
                self.smooth[stage] = rawByStage[stage]
            }
            // Shared adaptive reference: rise to the loudest smoothed bin, decay slowly.
            var frameMax = self.refFloorDb
            for (_, f) in rawByStage { for v in f where v > frameMax { frameMax = v } }
            self.peakRefDb = max(frameMax, self.peakRefDb - self.refDecayDbPerTick, self.refFloorDb)
            let ref = self.peakRefDb, span = self.displaySpan
            // Reference-relative frames, clamped to [-span, 0].
            var out: [Stage: SpectrumFrame] = [:]
            for (stage, f) in rawByStage {
                out[stage] = SpectrumFrame(db: f.map { max(-span, min(0, $0 - ref)) })
            }
            DispatchQueue.main.async {
                for stage in want where self.visible.contains(stage) {
                    switch stage {
                    case .violinPre: self.violinPre = out[stage]
                    case .global: self.global = out[stage]
                    }
                }
            }
        }
    }
}
