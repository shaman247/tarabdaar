import AppKit
import TarabdaarCore
import SwiftUI

/// Controls tab (unification): the performance-control mapping
/// editor.
///
/// Two sections, one language — everything by NAME (transport CCs are an
/// implementation detail and never shown):
///  * **Tilt controls** — per tilt 1/2/3, an arbitrary set of targets with
///    a two-handle range slider for the endpoints, in the target's native
///    units. A target is a composite parameter OR any single parameter
///    from `ParamRegistry` — a tilt can drive "Taraf Purity" or
///    "vibrato depth (¢)" with the same machinery. The iPad streams only
///    its raw tilt report; the Mac evaluates these bindings
///    (`AppController.applyTiltAxis`), so nothing syncs.
///  * **Composite parameters** — named 0…1 controls BUILT FROM several
///    parameters: each member sweeps its own lo→hi range as the composite
///    goes 0→1. Edited identically (add/remove members, drag ranges).
///    Ships with Taraf Purity / Taraf Decay / Tone Tilt / Expression as
///    editable defaults.
struct TiltControlsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("TILT CONTROLS")
                    .font(.padCaption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("Each control axis drives any set of composites or single parameters between the endpoints of its range slider, in the target's own units (left = fully one way, right = fully the other; rest sits halfway). \u{201C}From center\u{201D} holds the low endpoint through the resting half and sweeps only past neutral. Five axes: Arm \u{2195}/\u{2194}/\u{27F2} are the iPad's tilt axes through the guided arm calibration (Setup tab; every axis runs \u{2212}1\u{2026}+1 with rest = 0, sweep extremes = \u{00B1}1) — uncalibrated they carry raw pitch/roll/yaw, uncentered; Stick X/Y are the Joy-Con stick. The Mac evaluates all bindings, so edits take effect immediately.")
                    .font(.padCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(ControlAxes.dims, id: \.rawValue) { dim in
                    Panel(title: dim.label) {
                        TiltBindingSection(controller: controller, dim: dim)
                    }
                }
                Text("COMPOSITE PARAMETERS")
                    .font(.padCaption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                Text("A composite parameter is a named 0\u{2013}1 control built from several parameters: each member sweeps its own low\u{2192}high range as the composite rises. Bind composites to tilts above, or drive them from audition scores. Most members follow the tilt instantly; a few are engine-build values that re-apply through a crossfaded rebuild about a fifth of a second after the value settles (hover a member for which).")
                    .font(.padCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(controller.composites) { comp in
                    CompositeEditor(controller: controller, compositeID: comp.id)
                }
                Button {
                    controller.addComposite()
                } label: {
                    Label("Add composite parameter", systemImage: "plus")
                }
                .disabled(controller.composites.count >= CompositeParam.maxSlots)
                Divider().padding(.top, 8)
                Text("Composites and tilt bindings save with the preset — Save preset… on the Parameters tab (⌘5).")
                    .font(.padCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Tilt bindings

/// One tilt's binding list: an Add menu (composites, then every parameter
/// grouped as in the Parameters tab), then a row per bound target.
private struct TiltBindingSection: View {
    @ObservedObject var controller: AppController
    let dim: InputDimension

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer()
                Menu("Add") {
                    Menu("Composite") {
                        ForEach(unboundComposites, id: \.self) { t in
                            Button(controller.targetDisplayName(t)) {
                                controller.addTiltBinding(t, dim: dim)
                            }
                        }
                    }
                    .disabled(unboundComposites.isEmpty)
                    ForEach(ParamRegistry.groups, id: \.name) { group in
                        let free = group.params.filter { isUnbound($0.key) }
                        Menu(group.name) {
                            ForEach(free) { spec in
                                Button(spec.label) {
                                    controller.addTiltBinding(
                                        MapTarget(paramKey: spec.key), dim: dim)
                                }
                            }
                        }
                        .disabled(free.isEmpty)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            let bound = controller.tiltBindings(for: dim)
            if bound.isEmpty {
                Text("Nothing bound")
                    .font(.padCaption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(bound, id: \.self) { t in
                TiltBindingRow(controller: controller, dim: dim, target: t)
            }
        }
    }

    private func isUnbound(_ key: String) -> Bool {
        controller.tiltMapping
            .mapping(for: MapTarget(paramKey: key)).binding(for: dim) == nil
    }

    private var unboundComposites: [MapTarget] {
        (0..<CompositeParam.maxSlots)
            .map { MapTarget(compositeSlot: $0) }
            .filter {
                controller.tiltMapping.mapping(for: $0).binding(for: dim) == nil
            }
    }
}

/// One binding row: display name, a two-handle range slider for the
/// endpoints (the target's native units; handles may cross = inverted),
/// the "From center" rest-zero shape toggle, and remove.
private struct TiltBindingRow: View {
    @ObservedObject var controller: AppController
    let dim: InputDimension
    let target: MapTarget

    private var binding: DimensionBinding? {
        controller.tiltMapping.mapping(for: target).binding(for: dim)
    }
    private var lo: Double { binding?.controlPoints.first?.y ?? 0 }
    private var hi: Double { binding?.controlPoints.last?.y ?? 0 }
    private var fromCenter: Bool { (binding?.controlPoints.count ?? 0) >= 3 }

    /// Slider bounds: the target's native range, widened to include any
    /// stored endpoint outside it.
    private var sliderRange: ClosedRange<Double> {
        ParamFormat.sliderBounds(target.defaultRange, including: lo, hi)
    }

    var body: some View {
        RangeSliderRow(
            label: controller.targetDisplayName(target),
            labelWidth: Typography.scaledWidth(140),
            labelHelp: controller.targetDisplayName(target),
            readoutWidth: Typography.scaledWidth(44),
            lo: Binding(
                get: { lo },
                set: { controller.setTiltBinding(target, dim: dim,
                                                 lo: $0, hi: hi,
                                                 fromCenter: fromCenter) }),
            hi: Binding(
                get: { hi },
                set: { controller.setTiltBinding(target, dim: dim,
                                                 lo: lo, hi: $0,
                                                 fromCenter: fromCenter) }),
            range: sliderRange,
            sliderHelp: "Drag either handle: left value = tilted fully one way, right value = fully the other. Handles may cross for an inverted mapping."
        ) {
            Toggle("From center", isOn: Binding(
                get: { fromCenter },
                set: { controller.setTiltBinding(target, dim: dim, lo: lo,
                                                 hi: hi, fromCenter: $0) }))
                .toggleStyle(.checkbox)
                .font(.padCaption2)
            Spacer(minLength: 0)
            RemoveButton(help: "Remove this binding") {
                controller.removeTiltBinding(target, dim: dim)
            }
        }
    }
}

/// One two-endpoint row: label · lo readout · range slider · hi readout ·
/// whatever the tab puts after it. Shared by the tilt bindings and the
/// composite members — the same shape in the same units.
private struct RangeSliderRow<Trailing: View>: View {
    let label: String
    let labelWidth: CGFloat
    let labelHelp: String
    let readoutWidth: CGFloat
    let lo: Binding<Double>
    let hi: Binding<Double>
    let range: ClosedRange<Double>
    let sliderHelp: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.padCaption)
                .frame(width: labelWidth, alignment: .leading)
                .help(labelHelp)
            Text(ParamFormat.value(lo.wrappedValue))
                .font(.padCaption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: readoutWidth, alignment: .trailing)
            TiltRangeSlider(lo: lo, hi: hi, range: range)
                .frame(minWidth: 180)
                .help(sliderHelp)
            Text(ParamFormat.value(hi.wrappedValue))
                .font(.padCaption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: readoutWidth, alignment: .leading)
            trailing()
        }
    }
}

/// The row-trailing "remove this" button.
private struct RemoveButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

// MARK: - Composite parameters

/// One composite's editor: rename field, Add-base-parameter menu, a row
/// per member (label + range slider in the base parameter's native
/// bounds), delete.
private struct CompositeEditor: View {
    @ObservedObject var controller: AppController
    let compositeID: CompositeParam.ID

    private var composite: CompositeParam? {
        controller.composites.first { $0.id == compositeID }
    }

    var body: some View {
        if let comp = composite {
            Panel(title: comp.name) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Name")
                            .font(.padCaption2)
                            .foregroundStyle(.secondary)
                        TextField("", text: Binding(
                            get: { comp.name },
                            set: { controller.renameComposite(compositeID,
                                                              to: $0) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        Spacer()
                        Menu("Add parameter") {
                            ForEach(ParamRegistry.groups, id: \.name) { group in
                                let free = group.params.filter {
                                    !used.contains($0.key)
                                }
                                Menu(group.name) {
                                    ForEach(free) { spec in
                                        Button(spec.label) {
                                            controller.addCompositeMember(
                                                compositeID, key: spec.key)
                                        }
                                    }
                                }
                                .disabled(free.isEmpty)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Button {
                            controller.removeComposite(compositeID)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Delete this composite parameter")
                    }
                    if comp.members.isEmpty {
                        Text("No parameters — add one to give this control an effect")
                            .font(.padCaption)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(comp.members) { m in
                        CompositeMemberRow(controller: controller,
                                           compositeID: compositeID,
                                           member: m)
                    }
                }
            }
        }
    }

    private var used: Set<String> {
        Set(composite?.members.map(\.key) ?? [])
    }
}

/// One member row: the parameter's label + a range slider (the value it
/// holds at composite 0 / composite 1, in native units) + remove.
/// Parameters that need an engine rebuild are marked.
private struct CompositeMemberRow: View {
    @ObservedObject var controller: AppController
    let compositeID: CompositeParam.ID
    let member: CompositeMember

    private var info: (key: String, label: String, lo: Double, hi: Double) {
        AppController.paramInfo(member.key)
    }

    private var sliderRange: ClosedRange<Double> {
        ParamFormat.sliderBounds((info.lo, info.hi),
                                 including: member.lo, member.hi)
    }

    private var isLive: Bool {
        ParamRegistry.liveKeys.contains(member.key)
    }

    var body: some View {
        RangeSliderRow(
            label: info.label,
            labelWidth: Typography.scaledWidth(128),
            labelHelp: isLive
                ? "Applies instantly while the composite moves"
                : "Re-applies through a crossfaded engine rebuild, ~0.2 s after the value settles",
            readoutWidth: Typography.scaledWidth(46),
            lo: Binding(
                get: { member.lo },
                set: { controller.setCompositeMemberRange(
                    compositeID, key: member.key, lo: $0, hi: member.hi) }),
            hi: Binding(
                get: { member.hi },
                set: { controller.setCompositeMemberRange(
                    compositeID, key: member.key, lo: member.lo, hi: $0) }),
            range: sliderRange,
            sliderHelp: "The value this base parameter holds at composite 0 (left) and composite 1 (right). Handles may cross for an inverted sweep."
        ) {
            Spacer(minLength: 0)
            RemoveButton(help: "Remove this base parameter from the composite") {
                controller.removeCompositeMember(compositeID, key: member.key)
            }
        }
    }
}

// MARK: - Range slider

/// A single-track range slider with TWO handles (macOS SwiftUI has none
/// built in): lo (hollow) and hi (filled), with the mapped span tinted
/// between them. A drag grabs whichever handle is nearest at its start and
/// moves only that one; handles may cross (the span dims to show the
/// inverted state).
struct TiltRangeSlider: View {
    @Binding var lo: Double
    @Binding var hi: Double
    let range: ClosedRange<Double>

    /// Which handle the current drag owns (nil between drags).
    @State private var dragging: Handle?
    private enum Handle { case lo, hi }

    private let knobR: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width - 2 * knobR, 1)
            let midY = geo.size.height / 2
            let xLo = knobR + w * frac(lo)
            let xHi = knobR + w * frac(hi)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 3)
                    .padding(.horizontal, knobR - 1)
                Rectangle()
                    .fill(Color.accentColor.opacity(lo <= hi ? 0.55 : 0.25))
                    .frame(width: abs(xHi - xLo), height: 3)
                    .offset(x: min(xLo, xHi))
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Circle().fill(Color(white: 0.15)))
                    .frame(width: 2 * knobR, height: 2 * knobR)
                    .position(x: xLo, y: midY)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 2 * knobR, height: 2 * knobR)
                    .position(x: xHi, y: midY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragging == nil {
                            // grab the nearest handle at drag start
                            dragging = abs(g.startLocation.x - xLo)
                                <= abs(g.startLocation.x - xHi) ? .lo : .hi
                        }
                        let f = Double((g.location.x - knobR) / w)
                        let v = range.lowerBound
                            + min(max(f, 0), 1)
                            * (range.upperBound - range.lowerBound)
                        switch dragging {
                        case .lo: lo = v
                        case .hi: hi = v
                        case nil: break
                        }
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
        .frame(height: 16)
    }

    private func frac(_ v: Double) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((v - range.lowerBound) / span, 0), 1))
    }
}
