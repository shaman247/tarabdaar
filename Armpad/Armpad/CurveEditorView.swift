import SwiftUI

/// Edits the control points of a DimensionBinding's transfer curve.
struct CurveEditorView: View {
    let parameter: MappableParameter
    let dimension: Dimension
    @Binding var binding: DimensionBinding

    private let graphPad: CGFloat = 40
    private let pointSize: CGFloat = 26
    private let font = Font.system(size: 15, weight: .regular, design: .default)
    private let smallFont = Font.system(size: 12, weight: .regular, design: .default)
    private let axisFont = Font.system(size: 13, weight: .regular, design: .default)

    /// The clamp range: min/max of endpoint Y values.
    private var endpointRange: (Double, Double) {
        let first = binding.controlPoints.first?.y ?? 0
        let last = binding.controlPoints.last?.y ?? 1
        return (min(first, last), max(first, last))
    }

    /// Y axis always shows the full parameter range.
    private var yRange: (Double, Double) { parameter.defaultRange }

    /// X axis display range: [-1, +1] for tilts, [0, 1] for everything else.
    private var xDisplay: (Double, Double) {
        dimension.isTilt ? (-1, 1) : (0, 1)
    }

    var body: some View {
        VStack(spacing: 4) {
            // Header
            HStack {
                Text(dimension.label)
                    .font(font).foregroundColor(.cyan)
                Text("→").foregroundColor(.gray)
                Text(parameter.label)
                    .font(font).foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 8)

            // Square graph
            GeometryReader { geo in
                let side = min(geo.size.width - 16, geo.size.height) - graphPad * 2
                let gw = max(side, 40)
                let gh = gw
                let yr = yRange
                let totalW = gw + graphPad * 2
                let totalH = gh + graphPad * 2

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(white: 0.04))
                        .frame(width: totalW, height: totalH)

                    // Grid
                    graphGrid(width: gw, height: gh, yr: yr)
                        .offset(x: graphPad, y: graphPad)

                    // Curve
                    clampedCurvePath(width: gw, height: gh, yr: yr)
                        .stroke(Color.cyan, lineWidth: 2)
                        .offset(x: graphPad, y: graphPad)

                    // Control points
                    ForEach(binding.controlPoints.indices, id: \.self) { i in
                        let pt = binding.controlPoints[i]
                        let screenX = graphPad + CGFloat(pt.x) * gw
                        let screenY = graphPad + yToScreen(pt.y, gh: gh, yr: yr)
                        let isEndpoint = i == 0 || i == binding.controlPoints.count - 1

                        Circle()
                            .fill(Color.cyan)
                            .frame(width: pointSize, height: pointSize)
                            .overlay(Circle().fill(Color.white).frame(width: 6, height: 6))
                            .position(x: screenX, y: screenY)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { drag in
                                        var newX = Double((drag.location.x - graphPad) / gw)
                                        let rawScreenY = Double((drag.location.y - graphPad) / gh)
                                        var newY = yr.0 + (1.0 - rawScreenY) * (yr.1 - yr.0)

                                        if i == 0 { newX = 0 }
                                        else if i == binding.controlPoints.count - 1 { newX = 1 }
                                        else {
                                            let prev = binding.controlPoints[i - 1].x + 0.01
                                            let next = binding.controlPoints[i + 1].x - 0.01
                                            newX = max(prev, min(next, newX))
                                        }
                                        newX = max(0, min(1, newX))

                                        // Endpoints: clamp to full param range. Interior: clamp to endpoint range.
                                        if isEndpoint {
                                            newY = max(yr.0, min(yr.1, newY))
                                        } else {
                                            let er = self.endpointRange
                                            newY = max(er.0, min(er.1, newY))
                                        }

                                        binding.controlPoints[i] = ControlPoint(x: newX, y: newY)
                                    }
                                    .onEnded { drag in
                                        guard !isEndpoint, binding.controlPoints.count > 2 else { return }
                                        let rawX = Double((drag.location.x - graphPad) / gw)
                                        let rawY = Double((drag.location.y - graphPad) / gh)
                                        if rawX < -0.15 || rawX > 1.15 || rawY < -0.15 || rawY > 1.15 {
                                            binding.controlPoints.remove(at: i)
                                        }
                                    }
                            )
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5)
                                    .onEnded { _ in
                                        guard !isEndpoint, binding.controlPoints.count > 2 else { return }
                                        binding.controlPoints.remove(at: i)
                                    }
                            )
                    }

                    // X axis: dimension name centered, endpoint values at edges
                    Text(dimension.label)
                        .font(axisFont).foregroundColor(.gray)
                        .position(x: graphPad + gw / 2, y: totalH - 8)
                    Text(formatVal(xDisplay.0))
                        .font(axisFont).foregroundColor(.gray.opacity(0.6))
                        .position(x: graphPad, y: totalH - 8)
                    Text(formatVal(xDisplay.1))
                        .font(axisFont).foregroundColor(.gray.opacity(0.6))
                        .position(x: graphPad + gw, y: totalH - 8)

                    // Y axis: parameter name centered, full range at edges
                    Text(parameter.label)
                        .font(axisFont).foregroundColor(.gray)
                        .rotationEffect(.degrees(-90))
                        .position(x: 10, y: graphPad + gh / 2)
                    Text(formatVal(yr.0))
                        .font(axisFont).foregroundColor(.gray.opacity(0.6))
                        .position(x: graphPad / 2, y: graphPad + gh)
                    Text(formatVal(yr.1))
                        .font(axisFont).foregroundColor(.gray.opacity(0.6))
                        .position(x: graphPad / 2, y: graphPad)

                    // Endpoint Y labels (if different from the axis bounds)
                    let epFirst = binding.controlPoints.first?.y ?? yr.0
                    let epLast = binding.controlPoints.last?.y ?? yr.1
                    let epsToLabel = Set([epFirst, epLast]).subtracting([yr.0, yr.1])
                    ForEach(Array(epsToLabel), id: \.self) { epY in
                        let sy = graphPad + yToScreen(epY, gh: gh, yr: yr)
                        // Dashed line at the endpoint value
                        Path { path in
                            path.move(to: CGPoint(x: graphPad, y: sy))
                            path.addLine(to: CGPoint(x: graphPad + gw, y: sy))
                        }
                        .stroke(Color.cyan.opacity(0.2), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))

                        Text(formatVal(epY))
                            .font(axisFont).foregroundColor(.cyan.opacity(0.5))
                            .position(x: graphPad / 2, y: sy)
                    }
                }
                .frame(width: totalW, height: totalH)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard binding.controlPoints.count < 4 else { return }
                    let newX = Double((location.x - graphPad) / gw)
                    let newY = yr.0 + (1.0 - Double((location.y - graphPad) / gh)) * (yr.1 - yr.0)
                    guard newX > 0.01 && newX < 0.99 else { return }
                    let er = endpointRange
                    let clampedY = max(er.0, min(er.1, newY))
                    binding.controlPoints.append(ControlPoint(x: max(0, min(1, newX)), y: clampedY))
                    binding.sortPoints()
                }
            }

            // Point values immediately below graph
            VStack(spacing: 3) {
                ForEach(binding.controlPoints.indices, id: \.self) { i in
                    pointRow(index: i)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }

    private func pointRow(index i: Int) -> some View {
        let isEndpoint = i == 0 || i == binding.controlPoints.count - 1
        let xd = xDisplay
        let displayX = xd.0 + binding.controlPoints[i].x * (xd.1 - xd.0)
        return HStack(spacing: 6) {
            Text("P\(i + 1)")
                .font(smallFont).foregroundColor(.cyan)
                .frame(width: 22)

            Text("X").font(smallFont).foregroundColor(.gray)
            if isEndpoint {
                Text(formatVal(displayX))
                    .font(font)
                    .foregroundColor(.gray.opacity(0.4))
                    .frame(width: 48, alignment: .center)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.03))
                    .cornerRadius(3)
            } else {
                dragField(value: displayX, range: xd.0...xd.1, step: (xd.1 - xd.0) * 0.002) { newVal in
                    let normalized = (newVal - xd.0) / (xd.1 - xd.0)
                    binding.controlPoints[i].x = max(0, min(1, normalized))
                    binding.sortPoints()
                }
            }

            Text("Y").font(smallFont).foregroundColor(.gray)
            if isEndpoint {
                let pr = parameter.defaultRange
                dragField(value: binding.controlPoints[i].y,
                          range: pr.0...pr.1,
                          step: (pr.1 - pr.0) * 0.002) { newVal in
                    binding.controlPoints[i].y = max(pr.0, min(pr.1, newVal))
                }
            } else {
                let er = endpointRange
                dragField(value: binding.controlPoints[i].y,
                          range: er.0...er.1,
                          step: max(er.1 - er.0, 0.01) * 0.002) { newVal in
                    binding.controlPoints[i].y = max(er.0, min(er.1, newVal))
                }
            }

            if !isEndpoint {
                Button(action: { binding.controlPoints.remove(at: i) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(smallFont).foregroundColor(.red.opacity(0.6))
                }
            }

            Spacer()
        }
    }

    private func dragField(value: Double, range: ClosedRange<Double>, step: Double,
                           onChange: @escaping (Double) -> Void) -> some View {
        Text(formatVal(value))
            .font(font)
            .foregroundColor(.white)
            .frame(width: 48, alignment: .center)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.06))
            .cornerRadius(3)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        let delta = Double(drag.translation.width) * step
                        let newVal = max(range.lowerBound, min(range.upperBound, value + delta))
                        onChange(newVal)
                    }
            )
    }

    private func yToScreen(_ y: Double, gh: CGFloat, yr: (Double, Double)) -> CGFloat {
        let span = yr.1 - yr.0
        guard span > 0 else { return gh / 2 }
        return CGFloat(1.0 - (y - yr.0) / span) * gh
    }

    private func graphGrid(width: CGFloat, height: CGFloat, yr: (Double, Double)) -> some View {
        Path { path in
            path.addRect(CGRect(x: 0, y: 0, width: width, height: height))
            // Horizontal center
            path.move(to: CGPoint(x: 0, y: height / 2))
            path.addLine(to: CGPoint(x: width, y: height / 2))
            // Vertical center
            path.move(to: CGPoint(x: width / 2, y: 0))
            path.addLine(to: CGPoint(x: width / 2, y: height))
        }
        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
    }

    private func clampedCurvePath(width: CGFloat, height: CGFloat, yr: (Double, Double)) -> Path {
        Path { path in
            let totalSteps = 60
            for s in 0...totalSteps {
                let t = Double(s) / Double(totalSteps)
                let y = binding.evaluate(t)
                let sx = CGFloat(t) * width
                let sy = yToScreen(y, gh: height, yr: yr)
                if s == 0 { path.move(to: CGPoint(x: sx, y: sy)) }
                else { path.addLine(to: CGPoint(x: sx, y: sy)) }
            }
        }
    }

    private func formatVal(_ value: Double) -> String {
        if abs(value) >= 100 { return String(format: "%.0f", value) }
        if abs(value) >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}
