import Foundation
import SwiftUI
import TarabdaarCore

/// Main-thread display and gain updates continue across tab switches.
final class PerformanceProfileModel: ObservableObject {
    @Published private(set) var snapshot: PerformancePitchProfile.Snapshot?
    @Published private(set) var gains: [Double] = []
    @Published private(set) var labels: [String] = []
    @Published private(set) var ratios: [Double] = []
    @Published var amount: Double = 0 { didSet { refresh() } }
    private let audio: AudioEngine
    private let tuning: Tuning
    private var timer: Timer?

    init(audio: AudioEngine, tuning: Tuning) {
        self.audio = audio
        self.tuning = tuning
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func reset() {
        audio.resetPitchProfile()
        refresh()
    }

    func toggleSeed() {
        refresh()
        if snapshot?.seeding == true { audio.finishPitchProfileSeed() }
        else { audio.resetPitchProfile(seed: true) }
        refresh()
    }

    private func refresh() {
        let degrees = scaleDegrees(from: tuning.scale)
        let ratios = degrees.map(\.ratio)
        let labels = degrees.map(\.label)
        if self.ratios != ratios { self.ratios = ratios }
        if self.labels != labels { self.labels = labels }
        let snap = audio.pitchProfile(tonicSemis: tuning.tonicFractionalMidi, ratios: ratios)
        snapshot = snap
        let inferred = PerformancePitchProfile.gains(snapshot: snap, scale: ratios)
        let depth = min(1, max(0, amount))
        gains = inferred.map { 1 + depth * ($0 - 1) }
        let hasEvidence = snap.seeding ? !snap.seededDegrees.isEmpty
            : PerformancePitchProfile.degreeWeights(snap.performance, scale: ratios).contains { $0 > 0 }
        audio.setPerformanceTarafProfile(tonic: tuning.tonicHz, ratios: ratios,
                                        gains: depth > 0 ? gains : [],
                                        unmatchedGain: hasEvidence ? 1 - depth * 0.85 : 1)
    }

    deinit { timer?.invalidate() }
}

struct PerformanceProfileView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var profile: PerformanceProfileModel

    init(controller: AppController) {
        self.controller = controller
        profile = controller.pitchProfile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Performance pitch profile").font(.title3.bold())
                Spacer()
                if let snap = profile.snapshot {
                    Text(String(format: "%.1f s", snap.activeSeconds))
                        .font(.padCaption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button(profile.snapshot?.seeding == true ? "Finish seed · −" : "Reset & seed · −") {
                    profile.toggleSeed()
                }
                Button("Reset performance · Capture") { profile.reset() }
                Spacer()
                Text("Adaptation").font(.padCaption)
                Slider(value: Binding(get: { controller.paramValue("ctl_taraf_adapt") },
                                      set: { controller.setParamValue("ctl_taraf_adapt", $0) }),
                       in: 0...1).frame(width: 120)
                Text(String(format: "%.0f%%", profile.amount * 100))
                    .font(.padCaption.monospacedDigit()).frame(width: 42)
            }
            if let snap = profile.snapshot {
                if snap.seeding || !snap.seededDegrees.isEmpty {
                    HStack(spacing: 10) {
                        Text(snap.seeding ? "Seeding" : "Seed").foregroundStyle(.secondary)
                        ForEach(profile.labels.indices, id: \.self) { i in
                            Text(profile.labels[i])
                                .foregroundStyle(snap.seededDegrees.contains(i) ? Color.orange : .secondary)
                        }
                    }.font(.padCaption)
                }
                let windows = [snap.short, snap.medium, snap.performance]
                let ceiling = max(0.1, windows.map { bins in
                    (bins.max() ?? 0) / max(1e-12, bins.reduce(0, +))
                }.max() ?? 0)
                ForEach(0..<3) { i in
                    PitchHistogram(title: ["10 s", "60 s", "Performance"][i],
                                   bins: windows[i], ceiling: ceiling,
                                   ratios: profile.ratios, labels: profile.labels,
                                   color: [Color.cyan, .mint, .orange][i])
                }
                HStack(spacing: 6) {
                    Text("Gain ×").font(.padCaption).foregroundStyle(.secondary)
                    ForEach(profile.labels.indices, id: \.self) { i in
                        VStack(spacing: 3) {
                            Text(profile.labels[i]).foregroundStyle(.secondary)
                            Text(String(format: "%.2f", profile.gains.indices.contains(i) ? profile.gains[i] : 1))
                                .monospacedDigit()
                        }.font(.padCaption).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }
}

private struct PitchHistogram: View {
    let title: String
    let bins: [Double]
    let ceiling: Double
    let ratios: [Double]
    let labels: [String]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.padCaption.bold())
                Spacer()
                Text(String(format: "0–%.0f%% · 10¢ bins", ceiling * 100))
                    .font(.padCaption2).foregroundStyle(.secondary)
            }
            Canvas { context, size in
                let inset = 16.0
                let width = max(1, size.width - inset * 2)
                let height = size.height - 23
                let sum = bins.reduce(0, +)
                for i in bins.indices {
                    let value = sum > 0 ? bins[i] / sum / ceiling : 0
                    let x = inset + Double(i) / Double(bins.count) * width
                    let barWidth = width / Double(bins.count)
                    let h = value * height
                    context.fill(Path(CGRect(x: x, y: height - h, width: max(1, barWidth - 0.5), height: h)),
                                 with: .color(color.opacity(0.8)))
                }
                for (i, ratio) in ratios.enumerated() {
                    let phase = log2(ratio) - floor(log2(ratio))
                    let x = inset + phase * width
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: height))
                    context.stroke(line, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
                    if labels.indices.contains(i) {
                        context.draw(Text(labels[i]).font(.padCaption2).foregroundColor(.secondary),
                                     at: CGPoint(x: x, y: height + 13))
                    }
                }
            }
            .frame(height: 92)
            .accessibilityLabel("\(title) pitch distribution")
        }
    }
}
