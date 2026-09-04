import SarangiKit
import TarabdaarCore
import SwiftUI

/// The **Body** tab (⌘0): the formula body's frequency response exactly
/// as the running String engine was built with it —
///
/// - **radiation** — bridge force → radiated pressure through the modal
///   bank plus the flat `bow_body_c0` floor (thin, the raw ripple) and its
///   ±⅙-octave envelope (thick);
/// - **at the ear** — the same after the radiation LP/HP sections and the
///   bridge hill, i.e. what leaves the instrument before the room;
/// - **admittance** — bridge force → bridge velocity, the loop side the
///   string feels (dim);
/// - every mode as a tick on the floor (height = its radiation residue),
///   and the tonic's harmonics as faint verticals, so you can read where
///   Sa's partials sit on the peaks and nulls.
///
/// Recomputed only when the engine identity changes (a rebuild), polled
/// at 2 Hz; hover for a readout at any frequency.
struct BodyView: View {
    @ObservedObject var controller: AppController
    @StateObject private var model = BodyModel()
    @State private var hoverX: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let r = model.response {
                stats(r)
                BodyPlot(response: r, hoverX: $hoverX)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                legend
            } else {
                Text("No body — the String voice is not armed.")
                    .font(.padCaption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .onAppear { model.start(controller: controller) }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BODY")
                .font(.padCaption.weight(.bold))
                .foregroundStyle(.secondary)
            Text("The formula body as built into the running engine: bridge force → radiated pressure (the peaks and nulls every harmonic sweeps through during meend and vibrato), the same after the radiation chain, and the bridge admittance the string loops through. Edit the Body group on the Parameters tab; the plot follows each rebuild.")
                .font(.padCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stats(_ r: BowEngine.BodyResponse) -> some View {
        HStack(spacing: 18) {
            stat("modes", "\(r.modes.count)")
            stat("ripple std 300–6k", String(format: "%.1f dB", r.stdDb))
            stat("range", String(format: "%.0f … %.0f dB", r.minDb, r.maxDb))
            stat("peaks / octave", String(format: "%.1f", r.peaksPerOctave))
            stat("bridge return", String(format: "%.3f", r.kret))
            stat("tonic", String(format: "%.1f Hz", r.tonicHz))
        }
        .font(.padSmall(10, design: .monospaced))
    }

    private func stat(_ name: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(name).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.primary)
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            key(BodyPlot.radColor, "radiation")
            key(BodyPlot.envColor, "±⅙-oct envelope")
            key(BodyPlot.chainColor, "at the ear (after LP/HP/hill)")
            key(BodyPlot.admColor, "bridge admittance")
            key(BodyPlot.modeColor, "modes")
            key(BodyPlot.harmColor, "tonic harmonics")
        }
        .font(.padSmall(9))
        .foregroundStyle(.secondary)
    }

    private func key(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 14, height: 3)
            Text(label)
        }
    }
}

/// Polls the engine identity at 2 Hz and recomputes the response only
/// when the String voice was rebuilt.
@MainActor
private final class BodyModel: ObservableObject {
    @Published var response: BowEngine.BodyResponse? = nil
    private var identity: ObjectIdentifier? = nil
    private var timer: Timer? = nil

    func start(controller: AppController) {
        refresh(controller)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self, weak controller] _ in
            guard let self, let controller else { return }
            MainActor.assumeIsolated { self.refresh(controller) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh(_ controller: AppController) {
        let id = controller.audio.stringVoiceEngineIdentity()
        guard id != identity || (id != nil && response == nil) else { return }
        identity = id
        response = controller.audio.stringVoiceBodyResponse()
    }
}

private struct BodyPlot: View {
    let response: BowEngine.BodyResponse
    @Binding var hoverX: CGFloat?

    static let radColor = Color(red: 1.0, green: 0.55, blue: 0.2)
    static let envColor = Color(red: 1.0, green: 0.85, blue: 0.4)
    static let chainColor = Color.white
    static let admColor = Color.cyan
    static let modeColor = Color(red: 0.6, green: 0.4, blue: 1.0)
    static let harmColor = Color.green

    private static let fLo = 40.0, fHi = 20000.0
    private static let padL: CGFloat = 44, padR: CGFloat = 12
    private static let padT: CGFloat = 8, padB: CGFloat = 22
    private static let modeLane: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(ctx, size) }
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.04)))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hoverX = p.x
                    case .ended: hoverX = nil
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: geometry

    private func x(_ hz: Double, _ size: CGSize) -> CGFloat {
        let w = size.width - Self.padL - Self.padR
        let u = log(hz / Self.fLo) / log(Self.fHi / Self.fLo)
        return Self.padL + CGFloat(u) * w
    }

    private func hz(atX px: CGFloat, _ size: CGSize) -> Double {
        let w = size.width - Self.padL - Self.padR
        let u = Double((px - Self.padL) / w)
        return Self.fLo * pow(Self.fHi / Self.fLo, min(1, max(0, u)))
    }

    private func dbRange() -> (lo: Double, hi: Double) {
        var lo = Double.infinity, hi = -Double.infinity
        for (i, v) in response.radDb.enumerated() {
            lo = min(lo, v); hi = max(hi, v)
            let c = response.chainDb[i]
            if c.isFinite, response.hz[i] > 60 { lo = min(lo, c); hi = max(hi, c) }
        }
        for v in response.admDb { hi = max(hi, v) }
        let l = max(-60.0, (lo / 10).rounded(.down) * 10 - 5)
        let h = min(30.0, (hi / 10).rounded(.up) * 10 + 5)
        return (l, max(h, l + 20))
    }

    private func y(_ db: Double, _ size: CGSize, _ r: (lo: Double, hi: Double)) -> CGFloat {
        let h = size.height - Self.padT - Self.padB - Self.modeLane
        let u = (db - r.lo) / (r.hi - r.lo)
        return Self.padT + h * CGFloat(1 - min(1.1, max(-0.1, u)))
    }

    // MARK: drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let r = dbRange()
        let floorY = size.height - Self.padB - Self.modeLane
        // frequency grid
        let grid: [Double] = [50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        for f in grid {
            let px = x(f, size)
            var p = Path()
            p.move(to: CGPoint(x: px, y: Self.padT))
            p.addLine(to: CGPoint(x: px, y: floorY))
            ctx.stroke(p, with: .color(Color.white.opacity(0.10)), lineWidth: 1)
            let label = f >= 1000 ? String(format: "%gk", f / 1000) : String(format: "%g", f)
            ctx.draw(Text(label).font(.padSmall(9, design: .monospaced))
                        .foregroundColor(.secondary),
                     at: CGPoint(x: px, y: size.height - Self.padB / 2), anchor: .center)
        }
        // dB grid
        var db = (r.lo / 10).rounded(.up) * 10
        while db <= r.hi {
            let py = y(db, size, r)
            var p = Path()
            p.move(to: CGPoint(x: Self.padL, y: py))
            p.addLine(to: CGPoint(x: size.width - Self.padR, y: py))
            ctx.stroke(p, with: .color(Color.white.opacity(db == 0 ? 0.22 : 0.10)), lineWidth: 1)
            ctx.draw(Text(String(format: "%+.0f", db)).font(.padSmall(9, design: .monospaced))
                        .foregroundColor(.secondary),
                     at: CGPoint(x: Self.padL - 6, y: py), anchor: .trailing)
            db += 10
        }
        // tonic harmonics
        var k = 1.0
        while response.tonicHz * k < Self.fHi {
            let px = x(response.tonicHz * k, size)
            var p = Path()
            p.move(to: CGPoint(x: px, y: Self.padT))
            p.addLine(to: CGPoint(x: px, y: floorY))
            ctx.stroke(p, with: .color(Self.harmColor.opacity(k == 1 ? 0.5 : 0.22)),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            k += 1
        }
        // modes lane
        let maxRad = response.modes.map { abs($0.rad) }.max() ?? 1
        for m in response.modes {
            let px = x(m.hz, size)
            let h = Self.modeLane * CGFloat(min(1, abs(m.rad) / max(maxRad, 1e-12)))
            var p = Path()
            p.move(to: CGPoint(x: px, y: floorY + Self.modeLane))
            p.addLine(to: CGPoint(x: px, y: floorY + Self.modeLane - max(1, h)))
            ctx.stroke(p, with: .color(Self.modeColor.opacity(m.rad >= 0 ? 0.9 : 0.5)), lineWidth: 1)
        }
        // traces
        trace(ctx, size, r, response.admDb, Self.admColor.opacity(0.45), 1)
        trace(ctx, size, r, response.radDb, Self.radColor.opacity(0.7), 1)
        trace(ctx, size, r, response.chainDb, Self.chainColor.opacity(0.75), 1)
        trace(ctx, size, r, response.radSmoothDb, Self.envColor, 2.5)
        // hover readout
        if let hx = hoverX, hx >= Self.padL, hx <= size.width - Self.padR {
            let f = hz(atX: hx, size)
            let i = nearestBin(f)
            var p = Path()
            p.move(to: CGPoint(x: hx, y: Self.padT))
            p.addLine(to: CGPoint(x: hx, y: floorY))
            ctx.stroke(p, with: .color(Color.white.opacity(0.5)), lineWidth: 1)
            let c = response.chainDb[i]
            let ratio = f / response.tonicHz
            let text = String(format: "%.0f Hz  (%.2f × tonic)\nradiation %+.1f dB · envelope %+.1f dB\nat the ear %@ · admittance %+.1f dB",
                              f, ratio, response.radDb[i], response.radSmoothDb[i],
                              c.isFinite ? String(format: "%+.1f dB", c) : "—",
                              response.admDb[i])
            let anchorLeft = hx < size.width * 0.6
            let origin = CGPoint(x: anchorLeft ? hx + 8 : hx - 8, y: Self.padT + 4)
            let resolved = ctx.resolve(Text(text).font(.padSmall(10, design: .monospaced))
                                        .foregroundColor(.primary))
            let sz = resolved.measure(in: CGSize(width: 320, height: 80))
            let rect = CGRect(x: anchorLeft ? origin.x : origin.x - sz.width,
                              y: origin.y, width: sz.width, height: sz.height)
                .insetBy(dx: -6, dy: -4)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 4),
                     with: .color(Color.black.opacity(0.75)))
            ctx.draw(resolved, at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), anchor: .topLeading)
        }
    }

    private func trace(_ ctx: GraphicsContext, _ size: CGSize,
                       _ r: (lo: Double, hi: Double), _ v: [Double],
                       _ color: Color, _ width: CGFloat) {
        var p = Path()
        var open = false
        for (i, f) in response.hz.enumerated() {
            let d = v[i]
            guard d.isFinite else { open = false; continue }
            let pt = CGPoint(x: x(f, size), y: y(d, size, r))
            if open { p.addLine(to: pt) } else { p.move(to: pt); open = true }
        }
        ctx.stroke(p, with: .color(color),
                   style: StrokeStyle(lineWidth: width, lineJoin: .round))
    }

    private func nearestBin(_ f: Double) -> Int {
        let n = response.hz.count
        let u = log(f / Self.fLo) / log(Self.fHi / Self.fLo)
        return min(n - 1, max(0, Int((u * Double(n - 1)).rounded())))
    }
}
