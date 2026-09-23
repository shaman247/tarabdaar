import SwiftUI
import SarangiKit
import TarabdaarCore

struct BowTransformsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(BowAxis.allCases, id: \.rawValue) { axis in
                    BowCurveEditor(axis: axis, points: Binding(
                        get: { controller.bowAxisCurve(axis) },
                        set: { controller.setBowAxisCurve(axis, $0) }))
                }
            }
            .padding(24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct BowCurveEditor: View {
    let axis: BowAxis
    @Binding var points: [BowAxisPoint]
    @State private var selected: Int?
    @State private var dragging: Int?
    @State private var dragOrigin: BowAxisPoint?

    private var selection: Int? {
        selected.flatMap { points.indices.contains($0) ? $0 : nil }
    }
    private var canRemove: Bool {
        guard let i = selection else { return false }
        return i > 0 && i < points.count - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(axis.title).font(.title3.bold())
                Spacer()
                Button("Add point", systemImage: "plus") { addInLargestGap() }
                    .disabled(points.count >= BowAxisTransform.maxPoints)
                Button("Remove point", systemImage: "minus") { removeSelected() }
                    .disabled(!canRemove)
                Button("Identity") { replace(BowAxisTransform.identity) }
                Button("Factory curve") {
                    replace(TarabdaarPreset.factoryBowAxisCurves()[axis.rawValue] ?? BowAxisTransform.identity)
                }
            }
            HStack(spacing: 8) {
                Text("Output").font(.padCaption).foregroundStyle(.secondary)
                VStack(spacing: 4) {
                    HStack {
                        Text("1")
                        Spacer()
                    }.font(.padCaption2).foregroundStyle(.secondary)
                    graph.frame(height: 220)
                    HStack {
                        Text("0")
                        Spacer()
                        Text("Input")
                        Spacer()
                        Text("1")
                    }.font(.padCaption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Text("\(points.count) points").foregroundStyle(.secondary)
                Spacer()
                if let i = selection {
                    Text("Input")
                    TextField("Input", value: coordinateBinding(i, input: true),
                              format: .number.precision(.fractionLength(3)))
                        .frame(width: 70).disabled(i == 0 || i == points.count - 1)
                    Text("Output")
                    TextField("Output", value: coordinateBinding(i, input: false),
                              format: .number.precision(.fractionLength(3)))
                        .frame(width: 70)
                }
            }
            .font(.padCaption.monospacedDigit())
            .textFieldStyle(.roundedBorder)
            .frame(height: 26)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
    }

    private var graph: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Canvas { context, size in
                    var grid = Path()
                    for i in 0...4 {
                        let t = Double(i) / 4
                        grid.move(to: location(BowAxisPoint(x: t, y: 0), size))
                        grid.addLine(to: location(BowAxisPoint(x: t, y: 1), size))
                        grid.move(to: location(BowAxisPoint(x: 0, y: t), size))
                        grid.addLine(to: location(BowAxisPoint(x: 1, y: t), size))
                    }
                    context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                    var identity = Path()
                    identity.move(to: location(BowAxisPoint(x: 0, y: 0), size))
                    identity.addLine(to: location(BowAxisPoint(x: 1, y: 1), size))
                    context.stroke(identity, with: .color(.secondary.opacity(0.4)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    var curve = Path()
                    for (i, point) in points.enumerated() {
                        if i == 0 { curve.move(to: location(point, size)) }
                        else { curve.addLine(to: location(point, size)) }
                    }
                    context.stroke(curve, with: .color(.accentColor), lineWidth: 2.5)
                }
                ForEach(points.indices, id: \.self) { i in
                    Circle()
                        .fill(selection == i ? Color.orange : Color.accentColor)
                        .overlay(Circle().stroke(Color.primary.opacity(0.8), lineWidth: 1.5))
                        .frame(width: 11, height: 11)
                        .position(location(points[i], size))
                        .accessibilityLabel("\(axis.title) point \(i + 1)")
                        .accessibilityValue(String(format: "Input %.3f, output %.3f", points[i].x, points[i].y))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { selected = i }
                }
            }
            .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragging == nil {
                        if let i = nearest(value.startLocation, size) {
                            selected = i
                            dragging = i
                            dragOrigin = points[i]
                        } else {
                            let point = coordinates(value.startLocation, size)
                            if let i = insert(point) { dragging = i; dragOrigin = point }
                        }
                    }
                    if let i = dragging, let origin = dragOrigin {
                        move(i, x: origin.x + value.translation.width / max(1, size.width - 20),
                             y: origin.y - value.translation.height / max(1, size.height - 20))
                    }
                }
                .onEnded { _ in dragging = nil; dragOrigin = nil })
        }
    }

    private func location(_ point: BowAxisPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: 10 + point.x * max(1, size.width - 20),
                y: 10 + (1 - point.y) * max(1, size.height - 20))
    }

    private func coordinates(_ p: CGPoint, _ size: CGSize) -> BowAxisPoint {
        BowAxisPoint(x: min(1, max(0, (p.x - 10) / max(1, size.width - 20))),
                     y: min(1, max(0, 1 - (p.y - 10) / max(1, size.height - 20))))
    }

    private func nearest(_ p: CGPoint, _ size: CGSize) -> Int? {
        points.indices.min(by: {
            let a = location(points[$0], size), b = location(points[$1], size)
            return hypot(a.x - p.x, a.y - p.y) < hypot(b.x - p.x, b.y - p.y)
        }).flatMap { i in
            let a = location(points[i], size)
            return hypot(a.x - p.x, a.y - p.y) <= 16 ? i : nil
        }
    }

    private func coordinateBinding(_ i: Int, input: Bool) -> Binding<Double> {
        Binding(get: { points.indices.contains(i) ? (input ? points[i].x : points[i].y) : 0 },
                set: { value in
                    guard points.indices.contains(i) else { return }
                    move(i, x: input ? value : points[i].x, y: input ? points[i].y : value)
                })
    }

    private func move(_ i: Int, x: Double, y: Double) {
        guard points.indices.contains(i), x.isFinite, y.isFinite else { return }
        var edited = points
        let spacing = BowAxisTransform.minSpacing * 1.01
        let input = i == 0 ? 0 : i == points.count - 1 ? 1
            : min(points[i + 1].x - spacing, max(points[i - 1].x + spacing, x))
        edited[i] = BowAxisPoint(x: input, y: min(1, max(0, y)))
        points = edited
    }

    @discardableResult private func insert(_ point: BowAxisPoint) -> Int? {
        guard points.count < BowAxisTransform.maxPoints,
              points.allSatisfy({ abs($0.x - point.x) >= BowAxisTransform.minSpacing * 1.01 }) else { return nil }
        let i = points.firstIndex { $0.x > point.x } ?? points.count
        var edited = points
        edited.insert(point, at: i)
        points = edited
        selected = i
        return i
    }

    private func addInLargestGap() {
        guard let i = (0..<(points.count - 1)).max(by: {
            points[$0 + 1].x - points[$0].x < points[$1 + 1].x - points[$1].x
        }) else { return }
        let x = (points[i].x + points[i + 1].x) / 2
        insert(BowAxisPoint(x: x, y: BowAxisTransform(points: points).apply(x)))
    }

    private func removeSelected() {
        guard canRemove, let i = selection else { return }
        var edited = points
        edited.remove(at: i)
        points = edited
        selected = nil
    }

    private func replace(_ curve: [BowAxisPoint]) {
        selected = nil
        dragging = nil
        dragOrigin = nil
        points = curve
    }
}
