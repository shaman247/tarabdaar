import StarpadCore
import SwiftUI
// NOTE: deliberately does NOT import SarangiKit — its dormant coupled-network
// `ParamSpec` would collide with the registry's.

/// The Parameters tab (2026-07-24 unification) — **the** parameter surface.
/// Every parameter of the String instrument lives here in one list: the
/// bow-stroke axes, the `bowed_string.json` physics scalars (formerly a
/// separate Sarangi tab), and the live taraf/tone axes. Each row shows the
/// parameter's value in native units and a mapping menu that binds it to a
/// tilt or drops it into a composite — no parameter is special.
///
/// Apply semantics come from `ParamRegistry`: `.live` rows take effect
/// instantly, `.rebuild` rows ride a debounced off-main engine rebuild, and
/// `.hybrid` rows (jawari buzz, vibrato depth) are instant up to their
/// built value and rebuild above it. That is what collapsed the old
/// duplicate pairs — "web buzz" vs "jawari buzz", two "vibrato depth"
/// knobs — into one row each.
struct ParametersView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var stringStore: StringParamStore
    @ObservedObject var sarangiStore: SarangiStore

    init(controller: AppController) {
        self.controller = controller
        self.stringStore = controller.stringParams
        self.sarangiStore = controller.sarangi
    }

    @State private var search = ""
    @State private var expanded: Set<String> = ["Bow stroke"]

    /// Groups filtered by the search box (empty groups drop out).
    private var groups: [(name: String, params: [ParamSpec])] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ParamRegistry.groups }
        return ParamRegistry.groups.compactMap { g in
            let hits = g.params.filter {
                $0.label.lowercased().contains(q)
                    || $0.key.lowercased().contains(q)
                    || $0.help.lowercased().contains(q)
            }
            return hits.isEmpty ? nil : (name: g.name, params: hits)
        }
    }

    private var searching: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InstrumentPresetToolbar(controller: controller)
                Divider()
                Text("PARAMETERS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("Every parameter of the String instrument, in native units. A value here is where the parameter rests when nothing is driving it; tilts and composites modulate on top. Use the mapping button on a row to bind it to a tilt or add it to a composite. Double-click a row label to reset it. Rows tagged \u{201C}rebuild\u{201D} re-apply a moment after the value settles; everything else is instant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter parameters", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Spacer()
                    Button("Reset all") { controller.resetAllParams() }
                        .help("Back to the shipped default: the Sarangi Live artifact physics and every resting value")
                }
                ForEach(groups, id: \.name) { group in
                    DisclosureGroup(isExpanded: Binding(
                        get: { searching || expanded.contains(group.name) },
                        set: { on in
                            if on { expanded.insert(group.name) }
                            else { expanded.remove(group.name) }
                        })) {
                        VStack(spacing: 2) {
                            ForEach(group.params) { spec in
                                ParamRow(controller: controller,
                                         stringStore: stringStore,
                                         spec: spec)
                            }
                        }
                        .padding(.top, 2)
                    } label: {
                        Text(group.name).font(.subheadline).bold()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - One parameter row

/// Label · slider (native range) · readout · mapping menu · binding chips.
/// The value is read and written through `AppController`'s unified
/// accessors, so the row never needs to know which store owns the
/// parameter or how it reaches the engine.
private struct ParamRow: View {
    @ObservedObject var controller: AppController
    /// Observed so `.rebuild` rows (whose values live in the physics
    /// store) redraw when the store changes.
    @ObservedObject var stringStore: StringParamStore
    let spec: ParamSpec

    private var value: Double { controller.paramValue(spec.key) }

    /// The authored range is an AUTHORING HINT, the artifact is truth: a
    /// fit round moves values wherever the physics wants them, so a loaded
    /// value outside [lo, hi] widens the slider instead of being
    /// snap-clamped by the first drag.
    private var bounds: ClosedRange<Double> {
        let v = value
        guard v < spec.lo || v > spec.hi else { return spec.lo...spec.hi }
        let pad = max((spec.hi - spec.lo) * 0.25, abs(v) * 0.25)
        return min(spec.lo, v - pad)...max(spec.hi, v + pad)
    }

    private var binding: Binding<Double> {
        let base = Binding(
            get: { controller.paramValue(spec.key) },
            set: { controller.setParamValue(spec.key, $0) })
        guard let step = spec.step else { return base }
        return Binding(get: { base.wrappedValue },
                       set: { base.wrappedValue = ($0 / step).rounded() * step })
    }

    private func format(_ v: Double) -> String {
        if spec.step != nil { return String(format: "%.0f", v) }
        if abs(v) < 0.001, v != 0 { return String(format: "%.1e", v) }
        return spec.hi >= 100 ? String(format: "%.0f", v)
                              : String(format: "%.3f", v)
    }

    private var boundTilts: [InputDimension] {
        controller.tiltDimensions(for: MapTarget(paramKey: spec.key))
    }
    private var memberOf: [CompositeParam] {
        controller.compositesContaining(spec.key)
    }
    private var isMapped: Bool { !boundTilts.isEmpty || !memberOf.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            Text(spec.label)
                .font(.caption)
                .frame(width: 150, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { controller.resetParam(spec.key) }
            Slider(value: binding, in: bounds)
            Text(format(value))
                .frame(width: 54, alignment: .trailing)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            mappingChips
            mappingMenu
            Button {
                controller.resetParam(spec.key)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reset to \(format(controller.paramDefault(spec.key)))")
            .opacity(controller.paramIsDefault(spec.key) ? 0.25 : 1)
            .disabled(controller.paramIsDefault(spec.key))
        }
        .help(helpText)
    }

    /// The apply strategy is an implementation detail as of 2026-07-24 —
    /// a rebuild is now crossfaded in (no cut ring, no click) about a fifth
    /// of a second after the value settles, so no row is tagged. The
    /// tooltip still says which, for anyone chasing latency.
    private var helpText: String {
        var s = spec.help
        switch spec.apply {
        case .live:    s += "\n\nApplies instantly."
        case .rebuild: s += "\n\nRe-applies through a crossfaded engine rebuild (~0.2 s after the value settles)."
        case .hybrid:  s += "\n\nInstant up to the built value; above it, a crossfaded rebuild (~0.2 s)."
        }
        return s
    }

    /// Compact read-out of what drives this parameter: tilt chips + the
    /// composites it belongs to.
    @ViewBuilder
    private var mappingChips: some View {
        HStack(spacing: 3) {
            ForEach(boundTilts, id: \.rawValue) { d in
                Text(d.shortLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 3))
            }
            ForEach(memberOf) { c in
                Text(c.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.2),
                                in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .frame(width: 130, alignment: .leading)
    }

    private var mappingMenu: some View {
        Menu {
            Menu("Bind to tilt") {
                ForEach(TiltAxisWire.dims, id: \.rawValue) { dim in
                    Button {
                        controller.toggleTiltBinding(
                            MapTarget(paramKey: spec.key), dim: dim)
                    } label: {
                        Text(boundTilts.contains(dim)
                             ? "\u{2713} \(dim.label)" : dim.label)
                    }
                }
            }
            Menu("Add to composite") {
                if controller.composites.isEmpty {
                    Text("No composites yet")
                }
                ForEach(controller.composites) { c in
                    Button {
                        controller.toggleCompositeMember(c.id, key: spec.key)
                    } label: {
                        Text(memberOf.contains { $0.id == c.id }
                             ? "\u{2713} \(c.name)" : c.name)
                    }
                }
                Divider()
                Button("New composite from this") {
                    if let c = controller.addComposite() {
                        controller.renameComposite(c.id, to: spec.label)
                        controller.addCompositeMember(c.id, key: spec.key)
                    }
                }
                .disabled(controller.composites.count >= CompositeParam.maxSlots)
            }
        } label: {
            Image(systemName: isMapped
                  ? "slider.horizontal.below.square.filled.and.square"
                  : "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(isMapped ? Color.accentColor : .secondary)
        .help("Bind this parameter to a tilt, or add it to a composite")
    }
}
