import SarangiKit
import TarabdaarCore
import SwiftUI

/// The **Taraf** tab (⌘9): every modal-jawari sympathetic
/// row, pitch-sorted, one strip each —
///
/// - the scale label (`follow` for the melody follower, `·c` for a
///   chromatic-bridge row, a moon glyph for a row asleep under the
///   quiescence gate), its Hz and its radiated level (bar + dB);
/// - the **modal energy spectrum** — the string's energy per mode, p_k²
///   (the kernel's per-mode velocity envelopes squared), 16 modes on 40 dB
///   under the row's own peak. The rows radiate their bridge contact
///   force, which weighs every mode flat in these units, so this is also
///   the row's radiated spectrum up to a constant — the jawari's upward
///   cascade as it happens and as it is heard.
/// - the spectral centroid (mode units, EMA-smoothed like the lane hue).
///
/// Reads the same `ScopeModel` as the Scope tab (60 Hz poll of
/// `AudioEngine.scopeSnapshot()`; the kernel's display-only meters are
/// armed only while a scope tab shows).
struct TarafScopeView: View {
    @ObservedObject var controller: AppController
    @StateObject private var model = ScopeModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                ScrollView {
                    if model.rows.isEmpty {
                        Text("No taraf rows — the String voice is not armed, or every string is disabled.")
                            .font(.padCaption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            columnHeads
                            ForEach(model.rows) { TarafRowStrip(row: $0) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .onAppear { model.start(controller: controller) }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("TARAF")
                    .font(.padCaption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("\(model.rows.count) rows · \(model.rows.filter(\.asleep).count) asleep")
                    .font(.padCaption)
                    .foregroundStyle(.tertiary)
            }
            Text("Each row's energy per mode, p² over modes 1–\(BowEngine.scopeModeCount) on 40 dB under its own peak. The rows radiate their bridge contact force, which weighs every mode flat, so this is the radiated spectrum too — the jawari cascade moves energy rightward as a row rings.")
                .font(.padCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var columnHeads: some View {
        HStack(spacing: 10) {
            Text("string").frame(width: TarafRowStrip.labelW, alignment: .leading)
            Text("level").frame(width: TarafRowStrip.levelW, alignment: .leading)
            Text("modal energy  (modes 1–\(BowEngine.scopeModeCount))")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("centroid").frame(width: TarafRowStrip.centroidW, alignment: .leading)
        }
        .font(.padSmall(9, design: .monospaced))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
    }
}

private struct TarafRowStrip: View {
    let row: ScopeModel.Row
    static let labelW: CGFloat = 96
    static let levelW: CGFloat = 110
    static let centroidW: CGFloat = 64

    var body: some View {
        HStack(spacing: 10) {
            // identity
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(row.label)
                        .font(.padCaption.weight(.semibold))
                        .foregroundStyle(row.isFollower ? Color.cyan : Color.primary)
                    if row.asleep {
                        Image(systemName: "moon.zzz")
                            .font(.padSmall(8))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text("\(Int(row.f0.rounded())) Hz")
                    .font(.padSmall(9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: Self.labelW, alignment: .leading)
            // level
            VStack(alignment: .leading, spacing: 2) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule()
                            .fill(ScopePalette.taraf(level: 1, bright: row.bright01))
                            .frame(width: max(0, geo.size.width * row.level01))
                    }
                }
                .frame(height: 6)
                Text(row.level01 > 0
                     ? String(format: "%.0f dB", TLPVolume.db(from01: row.level01))
                     : "—")
                    .font(.padSmall(9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: Self.levelW)
            // modal energy spectrum
            SpectrumBars(values: row.modes.map { Double($0) }, lit: row.level01 > 0)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
            // centroid
            Text(String(format: "%4.1f", row.centroid))
                .font(.padSmall(9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: Self.centroidW, alignment: .leading)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
        .opacity(row.asleep ? 0.45 : 1)
    }
}

/// One 16-bin energy spectrum: the values are per-mode velocity
/// amplitudes shown as ENERGY (the dB axis doubles) on a 40 dB scale under
/// the row's own peak, bars coloured by mode index on the taraf hue law.
private struct SpectrumBars: View {
    let values: [Double]
    let lit: Bool

    var body: some View {
        Canvas { ctx, size in
            let n = values.count
            guard n > 0 else { return }
            let peak = values.max() ?? 0
            let bw = size.width / CGFloat(n)
            let range = 40.0
            for (k, v) in values.enumerated() {
                let h01: Double
                if peak > 0, v > 0 {
                    h01 = min(1, max(0, 1 + 40 * log10(v / peak) / range))
                } else { h01 = 0 }
                let h = size.height * CGFloat(h01)
                let rect = CGRect(x: CGFloat(k) * bw + 0.5, y: size.height - h,
                                  width: max(1, bw - 1), height: h)
                ctx.fill(Path(rect), with: .color(
                    ScopePalette.mode(k, of: n).opacity(lit ? 0.9 : 0.25)))
            }
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(base, with: .color(Color.white.opacity(0.12)), lineWidth: 1)
        }
    }
}
