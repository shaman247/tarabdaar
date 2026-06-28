import StarpadCore
import SwiftUI

struct ContentView: View {
    @StateObject private var motion = MotionManager()
    @StateObject private var midi: MIDIEngine
    @StateObject private var noteManager = NoteManager()
    /// The Pitch Pad is the iPad's sole playing surface. It emits MPE
    /// through the shared `midi` engine (real USB-MIDI) and borrows
    /// `noteManager` as its tilt / DimensionMapping brain.
    @StateObject private var pad: PitchPadEngine
    /// Receives the Pitch Pad scale pushed from StarpadMac over SysEx.
    /// StarpadMac edits scales; this iPad performs them.
    @StateObject private var scaleSync = ScaleSyncReceiver()
    @State private var showCalibration = false
    @State private var showMappingPanel = false

    init() {
        // One MIDIEngine, shared by the pad (MPE out) and NoteManager
        // (kept alive only as the tilt/mapping host). StateObject's
        // autoclosures capture the same instance and run once.
        let sharedMidi = MIDIEngine()
        _midi = StateObject(wrappedValue: sharedMidi)
        _pad = StateObject(wrappedValue: PitchPadEngine(midi: sharedMidi))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if showCalibration {
                CalibrationView(motion: motion) { calibration in
                    motion.calibration = calibration
                    withAnimation { showCalibration = false }
                }
            } else {
                playingSurface

                if showMappingPanel {
                    MappingMatrixPanel(noteManager: noteManager, onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showMappingPanel = false
                            noteManager.paused = false
                        }
                    })
                    .transition(.move(edge: .leading))
                    .zIndex(10)
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onAppear {
            // NoteManager runs purely as the tilt sampler + mapping host;
            // its voice/glide MIDI paths stay idle because the pad never
            // activates its pitchChannels.
            noteManager.motionSource = motion
            pad.expression = noteManager
            midi.start()

            // Scale sync: open on the last state pushed from the Mac (scale
            // + tonic + margin, if any), then listen for live pushes over
            // USB-MIDI SysEx.
            if let synced = SyncedScaleStore.load() {
                pad.applySyncedState(synced)
            }
            scaleSync.onState = { [weak pad] state in pad?.applySyncedState(state) }
            scaleSync.start()

            if !motion.isCalibrated {
                showCalibration = true
            }
        }
    }

    /// The active playing surface — Pitch Pad or Chord Pad — chosen by the
    /// layout the Mac last pushed over the synced state (`pad.layout`).
    @ViewBuilder
    private var playingSurface: some View {
        let onMap = {
            noteManager.paused = true
            withAnimation(.easeInOut(duration: 0.2)) { showMappingPanel = true }
        }
        let onRecalibrate = { showCalibration = true }
        switch pad.layout {
        case .stringPad:
            StringPadViewIOS(engine: pad, noteManager: noteManager, scaleSync: scaleSync,
                             arrangement: scaleSync.stringArrangement
                                 ?? StringArrangement(notes: [], stringCount: 0),
                             onShowMapping: onMap, onRecalibrate: onRecalibrate)
        case .chordPad:
            ChordPadViewIOS(engine: pad, noteManager: noteManager, scaleSync: scaleSync,
                            onShowMapping: onMap, onRecalibrate: onRecalibrate)
        case .pitchPad:
            PitchPadViewIOS(engine: pad, noteManager: noteManager, scaleSync: scaleSync,
                            onShowMapping: onMap, onRecalibrate: onRecalibrate)
        }
    }
}

// MARK: - Mapping Matrix Panel

struct MappingMatrixPanel: View {
    @ObservedObject var noteManager: NoteManager
    var onDismiss: () -> Void

    @State private var selectedParam: MappableParameter? = nil
    @State private var selectedDim: InputDimension? = nil
    @State private var dragSource: (MappableParameter, InputDimension)? = nil
    @State private var dragTarget: (MappableParameter, InputDimension)? = nil
    @State private var isDragging = false
    @State private var matrixWidth: CGFloat = 0
    private var cellSide: CGFloat {
        let totalCols = 1 + dims.count // default + dims
        guard totalCols > 0, matrixWidth > labelWidth else { return 50 }
        return (matrixWidth - labelWidth) / CGFloat(totalCols)
    }

    private let dims = InputDimension.real
    private let params = MappableParameter.allCases
    private let cellHeight: CGFloat = 52
    private let labelWidth: CGFloat = 155
    private let headerFont = Font.system(size: 17, weight: .semibold, design: .default)
    private let font = Font.system(size: 15, weight: .regular, design: .default)
    private let smallFont = Font.system(size: 13, weight: .regular, design: .default)
    private let tinyFont = Font.system(size: 11, weight: .regular, design: .default)

    var body: some View {
        GeometryReader { geo in
            let matrixW = geo.size.width * 2.0 / 3.0
            let editorW = geo.size.width / 3.0

            HStack(spacing: 0) {
                // Left 2/3: Matrix
                VStack(spacing: 0) {
                    // Header row
                    HStack(spacing: 0) {
                        Text("← Mapping")
                            .font(headerFont)
                            .foregroundColor(.cyan)
                            .frame(width: labelWidth, alignment: .leading)
                            .padding(.leading, 12)
                            .contentShape(Rectangle())
                            .onTapGesture { onDismiss() }

                        Text("Default")
                            .font(smallFont).fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)

                        ForEach(dims, id: \.rawValue) { dim in
                            Text(dim.label)
                                .font(smallFont).fontWeight(.medium)
                                .foregroundColor(dimColor(dim))
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                        }
                    }
                    .background(Color(white: 0.06))

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 0) {
                            ForEach(MappableParameter.displayOrder.indices, id: \.self) { gi in
                                let group = MappableParameter.displayOrder[gi]
                                if gi > 0 { sectionDivider(group.group) }
                                else { sectionDivider(group.group) }
                                ForEach(group.params, id: \.rawValue) { param in
                                    paramRow(param: param)
                                }
                            }
                        }
                        .coordinateSpace(name: "matrixGrid")
                    }
                }
                .frame(width: matrixW)
                .onAppear { matrixWidth = matrixW }

                Divider().background(Color.gray.opacity(0.3))

                // Right 1/3: Curve editor
                curveEditorPanel
                    .frame(width: editorW)
            }
        }
        .background(Color.black.opacity(0.97))
    }

    // MARK: - Curve Editor Panel

    @ViewBuilder
    private var curveEditorPanel: some View {
        if let param = selectedParam, let dim = selectedDim {
            if dim == InputDimension.none {
                // Default value editor
                defaultValueEditor(param: param)
            } else if noteManager.dimensionMapping.isConnected(param, dim) {
                CurveEditorView(
                    parameter: param,
                    dimension: dim,
                    binding: bindingProxy(param: param, dim: dim)
                )
            } else {
                paramDescription(param: param)
            }
        } else {
            VStack {
                Text("Tap a cell to edit").font(smallFont).foregroundColor(.gray.opacity(0.4))
                Spacer()
            }.padding()
        }
    }

    private func defaultValueEditor(param: MappableParameter) -> some View {
        let mapping = noteManager.dimensionMapping.mapping(for: param)
        let pr = param.defaultRange

        return VStack(spacing: 12) {
            Text(param.label)
                .font(headerFont).foregroundColor(.white)
            if let detail = param.detail {
                Text(detail).font(smallFont).foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }

            Divider().background(Color.gray.opacity(0.3))

            Text("Default Value")
                .font(smallFont).foregroundColor(.gray)

            Text("Used when no dimension is active")
                .font(tinyFont).foregroundColor(.gray.opacity(0.5))

            // Large draggable value
            Text(formatVal(mapping.defaultValue))
                .font(.system(size: 32, weight: .medium, design: .default))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { drag in
                            let step = (pr.1 - pr.0) * 0.002
                            let delta = Double(drag.translation.width) * step
                            let newVal = max(pr.0, min(pr.1, mapping.defaultValue + delta))
                            var m = noteManager.dimensionMapping.mapping(for: param)
                            m.defaultValue = newVal
                            noteManager.dimensionMapping.mappings[param.storageKey] = m
                        }
                )

            HStack {
                Text(formatVal(pr.0)).font(smallFont).foregroundColor(.gray.opacity(0.4))
                Spacer()
                Text(formatVal(pr.1)).font(smallFont).foregroundColor(.gray.opacity(0.4))
            }
            .padding(.horizontal, 20)

            if let unit = param.unit.isEmpty ? nil : param.unit {
                Text(unit).font(smallFont).foregroundColor(.gray)
            }

            Spacer()
        }
        .padding()
    }

    private func paramDescription(param: MappableParameter) -> some View {
        VStack(spacing: 8) {
            Text(param.label).font(font).foregroundColor(.white)
            if let detail = param.detail {
                Text(detail).font(smallFont).foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            Text("Tap a cell to edit").font(tinyFont).foregroundColor(.gray.opacity(0.4))
            Spacer()
        }.padding()
    }

    private func bindingProxy(param: MappableParameter, dim: InputDimension) -> Binding<DimensionBinding> {
        Binding(
            get: {
                noteManager.dimensionMapping.mapping(for: param).binding(for: dim)
                    ?? DimensionBinding(dimension: dim,
                                        rangeMin: param.defaultRange.0,
                                        rangeMax: param.defaultRange.1)
            },
            set: { newBinding in
                noteManager.dimensionMapping.setBinding(for: param, dimension: dim, to: newBinding)
            }
        )
    }

    // MARK: - Matrix Helpers

    private func sectionDivider(_ label: String) -> some View {
        HStack {
            Text(label).font(tinyFont).foregroundColor(.gray).padding(.leading, 12)
            Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 0.5)
        }
        .padding(.vertical, 3)
    }

    private func paramRow(param: MappableParameter) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(param.label)
                    .font(font)
                    .foregroundColor(selectedParam == param ? .white : Color(white: 0.7))
                if let detail = param.detail {
                    Text(detail).font(tinyFont).foregroundColor(.gray.opacity(0.5)).lineLimit(1)
                }
            }
            .frame(width: labelWidth, alignment: .leading)
            .padding(.leading, 12)

            defaultCell(param: param)

            ForEach(dims, id: \.rawValue) { dim in
                matrixCell(param: param, dim: dim)
            }
        }
        .background(selectedParam == param ? Color.white.opacity(0.03) : Color.clear)
    }

    private func defaultCell(param: MappableParameter) -> some View {
        let mapping = noteManager.dimensionMapping.mapping(for: param)
        let isSelected = selectedParam == param && selectedDim == InputDimension.none
        // Default is "active" when no dimension is bound AND the parameter always uses its value
        let isActive = mapping.bindings.isEmpty && param.defaultAlwaysActive
        let activeColor = Color.white

        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? activeColor.opacity(0.15) : Color(white: 0.04))
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? Color.white :
                        (isActive ? activeColor.opacity(0.4) : Color(white: 0.1)),
                        lineWidth: isSelected ? 2 : 0.5)

            Text(formatVal(mapping.defaultValue))
                .font(smallFont)
                .foregroundColor(isActive ? .white : .white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .padding(.horizontal, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedParam = param
            selectedDim = InputDimension.none
        }
    }

    private func matrixCell(param: MappableParameter, dim: InputDimension) -> some View {
        let connected = noteManager.dimensionMapping.isConnected(param, dim)
        let isSelected = selectedParam == param && selectedDim == dim
        let isDragTarget = dragTarget?.0 == param && dragTarget?.1 == dim

        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(isDragTarget ? Color.white.opacity(0.15) :
                      (connected ? dimColor(dim).opacity(0.25) : Color(white: 0.04)))
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? Color.white :
                        (connected ? dimColor(dim).opacity(0.5) : Color(white: 0.1)),
                        lineWidth: isSelected ? 2 : 0.5)

            if connected {
                miniCurve(param: param, dim: dim)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .padding(.horizontal, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if connected {
                selectedParam = param; selectedDim = dim
            } else {
                noteManager.dimensionMapping.toggleBinding(for: param, dimension: dim)
                selectedParam = param; selectedDim = dim
            }
        }
        .onLongPressGesture {
            if connected {
                noteManager.dimensionMapping.toggleBinding(for: param, dimension: dim)
                if selectedDim == dim && selectedParam == param { selectedDim = nil }
            }
        }
    }

    private func miniCurve(param: MappableParameter, dim: InputDimension) -> some View {
        GeometryReader { geo in
            if let b = noteManager.dimensionMapping.mapping(for: param).binding(for: dim) {
                let w = geo.size.width - 4
                let h = geo.size.height - 4
                let yr = param.defaultRange
                let span = max(yr.1 - yr.0, 0.001)
                Path { path in
                    let steps = 20
                    for s in 0...steps {
                        let t = Double(s) / Double(steps)
                        let y = b.evaluate(t)
                        let sx = 2 + CGFloat(t) * w
                        let sy = 2 + CGFloat(1.0 - (y - yr.0) / span) * h
                        if s == 0 { path.move(to: CGPoint(x: sx, y: sy)) }
                        else { path.addLine(to: CGPoint(x: sx, y: sy)) }
                    }
                }
                .stroke(dimColor(dim), lineWidth: 1)
            }
        }
    }

    /// Flat list of parameters in display order (for cellAt coordinate mapping).
    private var displayParams: [MappableParameter] {
        MappableParameter.displayOrder.flatMap(\.params)
    }

    private func cellAt(_ point: CGPoint) -> (MappableParameter, InputDimension)? {
        let rowH = cellSide
        let dividerHeight: CGFloat = 12 // sectionDivider height
        let groups = MappableParameter.displayOrder

        // Walk through groups to find which row the Y coordinate falls in
        var y = point.y
        var paramIndex = 0
        for (gi, group) in groups.enumerated() {
            // Each group has a divider above it
            let _ = gi // all groups have dividers now
            y -= dividerHeight
            if y < 0 { return nil }

            let groupHeight = CGFloat(group.params.count) * rowH
            if y < groupHeight {
                let rowInGroup = Int(y / rowH)
                paramIndex = rowInGroup
                let flatParams = displayParams
                let offset = groups[0..<gi].reduce(0) { $0 + $1.params.count }
                let idx = offset + paramIndex
                guard idx >= 0, idx < flatParams.count else { return nil }

                let cellAreaX = point.x - labelWidth
                guard cellAreaX >= 0, cellSide > 0 else { return nil }
                let colIdx = Int(cellAreaX / cellSide)
                // Column 0 is Default — skip for drag operations
                guard colIdx >= 1, colIdx <= dims.count else { return nil }
                return (flatParams[idx], dims[colIdx - 1])
            }
            y -= groupHeight
        }
        return nil
    }

    private func moveBinding(from srcP: MappableParameter, srcDim: InputDimension,
                             to tgtP: MappableParameter, tgtDim: InputDimension) {
        guard let binding = noteManager.dimensionMapping.mapping(for: srcP).binding(for: srcDim) else { return }
        // Remove from source
        noteManager.dimensionMapping.toggleBinding(for: srcP, dimension: srcDim)
        // Add to target (if not already connected)
        if !noteManager.dimensionMapping.isConnected(tgtP, tgtDim) {
            noteManager.dimensionMapping.toggleBinding(for: tgtP, dimension: tgtDim)
        }
        // Copy the curve data, updating the dimension
        var moved = binding
        moved.dimension = tgtDim
        noteManager.dimensionMapping.setBinding(for: tgtP, dimension: tgtDim, to: moved)
        selectedParam = tgtP
        selectedDim = tgtDim
    }

    private func formatVal(_ value: Double) -> String {
        if abs(value) >= 100 { return String(format: "%.0f", value) }
        if abs(value) >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    private func dimColor(_ dim: InputDimension) -> Color {
        if dim.isTilt { return .cyan }
        if dim.isPerNote { return .green }
        if dim.isSlider { return .orange }
        return .gray
    }
}

#Preview {
    ContentView()
}
