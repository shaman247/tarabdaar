import TarabdaarCore
import SwiftUI
// NOTE: deliberately does NOT import SarangiKit — its dormant coupled-network
// `ParamSpec` would collide with the registry's.

/// The Parameters tab (unification) — **the** parameter surface.
/// Every parameter of the String instrument lives here in one list: the
/// bow-stroke axes, the `bowed_string.json` physics scalars (formerly a
/// separate Sarangi tab), and the live taraf/tone axes. Each row shows the
/// parameter's value in native units and a mapping menu that binds it to a
/// tilt or drops it into a composite — no parameter is special.
///
/// Apply semantics come from `ParamRegistry`, and each row's description
/// states the SHARED scope/timing vocabulary (`ParamScope`/`ParamTiming`
/// — the same strings paramdoc renders into docs/parameters.md): live
/// (instant everywhere), in-place (running kernel, ~0.2 s debounce),
/// rebuild (crossfaded), hybrid (instant up to the built depth). The
/// unification is what collapsed the old duplicate pairs — "web buzz" vs
/// "jawari buzz", two "vibrato depth" knobs — into one row each.
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
    /// Every group starts open — the tab is a reference surface, and hunting
    /// for a knob behind a collapsed header costs more than the scroll does.
    @State private var expanded: Set<String> = Set(ParamRegistry.groups.map(\.name))
    /// Insert sections (the FX rack's four points) start CLOSED: the 16
    /// knobs of an untouched insert are 16 zeros, and 40 of the rack's 64
    /// EQ bands are inert while the point's EQ is off. The header row
    /// carries the state worth seeing at a glance.
    @State private var openInserts: Set<String> = []

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
                PresetToolbar(controller: controller)
                Divider()
                Text("PARAMETERS")
                    .font(.padCaption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("Every parameter of the String instrument, in native units. A value here is where the parameter rests when nothing is driving it; tilts and composites modulate on top. Use the mapping button on a row to bind it to a tilt or add it to a composite. Click a row label to show its description — it states the parameter's scope (global vs per-note) and timing: live (instant everywhere — the kind to bind for continuous control), in-place (lands on the running kernel ~0.2 s after the value settles), rebuild (crossfaded engine rebuild), or hybrid (instant up to the built depth). Double-click a label to reset it.")
                    .font(.padCaption)
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
                        groupBody(group.params)
                    } label: {
                        Text(group.name).font(.padSubheadline).bold()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// A group's rows. A group built from an INSERT DEFINITION
    /// instantiated at several points (the FX rack: one insert, four
    /// points) renders as one collapsible section per point instead of
    /// N × 16 flat rows — the registry marks the derived specs, so this
    /// stays generic (`ParamRegistry.insertSections`).
    @ViewBuilder
    private func groupBody(_ params: [ParamSpec]) -> some View {
        let split = ParamRegistry.insertSections(of: params)
        VStack(spacing: 2) {
            ForEach(split.flat) { spec in
                ParamRow(controller: controller, stringStore: stringStore,
                         spec: spec)
            }
            ForEach(split.inserts, id: \.point.id) { section in
                insertSection(section.point, section.params)
            }
        }
        .padding(.top, 2)
    }

    /// One insert point: a header row (name, what it processes, and what
    /// it is currently doing) that opens onto the point's own knobs.
    private func insertSection(_ point: FXInsertPoint,
                               _ params: [ParamSpec]) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { searching || openInserts.contains(point.keyPrefix) },
            set: { on in
                if on { openInserts.insert(point.keyPrefix) }
                else { openInserts.remove(point.keyPrefix) }
            })) {
            VStack(spacing: 2) {
                ForEach(params) { spec in
                    // inside the point's own section the row drops the
                    // point qualifier the menus need
                    ParamRow(controller: controller, stringStore: stringStore,
                             spec: spec, label: spec.insert?.knobLabel)
                }
            }
            .padding(.top, 2)
        } label: {
            HStack(spacing: 8) {
                Text(point.name).font(.padCaption).bold()
                Text(insertState(point))
                    .font(.padCaption2.monospacedDigit())
                    .foregroundStyle(insertIsActive(point)
                                     ? Color.accentColor : .secondary)
                Text(point.blurb)
                    .font(.padCaption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 4)
    }

    private func insertIsActive(_ point: FXInsertPoint) -> Bool {
        controller.paramValue(point.key("eq_on")) >= 0.5
            || controller.paramValue(point.key("rev_on")) >= 0.5
    }

    /// The header's one-line state: the two toggles, plus the reverb it
    /// would run (the summary that makes the collapsed rows safe to hide).
    private func insertState(_ point: FXInsertPoint) -> String {
        var parts: [String] = []
        if controller.paramValue(point.key("eq_on")) >= 0.5 {
            parts.append("EQ on")
        }
        if controller.paramValue(point.key("rev_on")) >= 0.5 {
            let room = controller.paramValue(point.key("rev_type")) >= 0.5
            let mix = controller.paramValue(point.key("rev_mix"))
            parts.append(String(format: "%@ %.0f%% wet",
                                room ? "Room" : "Bigverb", 100 * mix))
        }
        return parts.isEmpty ? "off" : parts.joined(separator: " · ")
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
    /// Row label override — an insert section names its own point, so the
    /// rows inside it show the bare knob label (see `ParamInsert`).
    var label: String? = nil

    /// Tooltips are unreliable, so a single click on the label expands the
    /// help text inline under the row instead.
    @State private var showHelp = false

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

    /// Stepped params read as whole numbers, and so do the ranges that run
    /// to 100+ (Hz, cents, ms) whatever the current value.
    private func format(_ v: Double) -> String {
        ParamFormat.value(v, decimals: 3, integer: spec.step != nil,
                          integerAbove: spec.hi >= 100 ? 0 : .infinity)
    }

    private var boundTilts: [InputDimension] {
        controller.tiltDimensions(for: MapTarget(paramKey: spec.key))
    }
    private var memberOf: [CompositeParam] {
        controller.compositesContaining(spec.key)
    }
    private var isMapped: Bool { !boundTilts.isEmpty || !memberOf.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row
            if showHelp {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.key)
                        .font(.padCaption2.monospaced())
                    Text(helpText)
                        .foregroundStyle(.secondary)
                }
                .font(.padCaption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 8)
                .padding(.bottom, 4)
            }
        }
        .help("\(spec.key)\n\n\(helpText)")
    }

    private var row: some View {
        HStack(spacing: 8) {
            Text(label ?? spec.label)
                .font(.padCaption)
                .foregroundStyle(showHelp ? Color.accentColor : Color.primary)
                .frame(width: Typography.scaledWidth(150), alignment: .leading)
                .contentShape(Rectangle())
                // The single tap must fire immediately — an exclusive
                // double/single composition holds it for the double-click
                // window, which reads as lag. Simultaneous recognition
                // means a double-click's two single taps also fire; the
                // reset handler pins the help open so the net state is
                // deterministic (reset + help shown).
                .onTapGesture { showHelp.toggle() }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    controller.resetParam(spec.key)
                    showHelp = true
                })
            Slider(value: binding, in: bounds)
            Text(format(value))
                .frame(width: Typography.scaledWidth(54), alignment: .trailing)
                .font(.padCaption.monospacedDigit())
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
    }

    /// Scope + timing come from the SHARED vocabulary in `ParamRegistry`
    /// (`ParamScope`/`ParamTiming.summary`) — the same strings paramdoc
    /// renders into docs/parameters.md, so this description can never
    /// tell a different story than the documentation. (fix:
    /// the old text derived timing from the apply STRATEGY alone and
    /// claimed "crossfaded engine rebuild" for every in-place key.)
    private var helpText: String {
        spec.help
            + "\n\nScope: \(spec.scope.label) — \(spec.scope.summary)."
            + "\nTiming: \(spec.timing.label) — \(spec.timing.summary)."
    }

    /// Compact read-out of what drives this parameter: tilt chips + the
    /// composites it belongs to.
    @ViewBuilder
    private var mappingChips: some View {
        HStack(spacing: 3) {
            ForEach(boundTilts, id: \.rawValue) { d in
                Text(d.shortLabel)
                    .font(.padCaption2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 3))
            }
            ForEach(memberOf) { c in
                Text(c.name)
                    .font(.padCaption2)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.2),
                                in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .frame(width: Typography.scaledWidth(130), alignment: .leading)
    }

    private var mappingMenu: some View {
        Menu {
            Menu("Bind to tilt") {
                ForEach(ControlAxes.dims, id: \.rawValue) { dim in
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
