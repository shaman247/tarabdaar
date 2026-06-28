import StarpadCore
import SwiftUI

/// Calibration view that shows all 7 measurements and allows recalibrating any individual one.
/// Also serves as the initial calibration flow on first launch.
struct CalibrationView: View {
    @ObservedObject var motion: MotionManager
    var onComplete: (CalibrationData) -> Void

    // The 7 calibration steps
    enum Step: Int, CaseIterable {
        case rest = 0
        case tilt1Positive = 1
        case tilt1Negative = 2
        case tilt2Positive = 3
        case tilt2Negative = 4
        case tilt3Positive = 5
        case tilt3Negative = 6

        var title: String {
            switch self {
            case .rest: return "Rest"
            case .tilt1Positive: return "Tilt 1: Up"
            case .tilt1Negative: return "Tilt 1: Down"
            case .tilt2Positive: return "Tilt 2: Towards"
            case .tilt2Negative: return "Tilt 2: Away"
            case .tilt3Positive: return "Tilt 3: Inward"
            case .tilt3Negative: return "Tilt 3: Outward"
            }
        }

        var instruction: String {
            switch self {
            case .rest: return "Neutral playing position"
            case .tilt1Positive: return "Move forearm up"
            case .tilt1Negative: return "Move forearm down"
            case .tilt2Positive: return "Tilt towards you"
            case .tilt2Negative: return "Tilt away from you"
            case .tilt3Positive: return "Rotate arm inward"
            case .tilt3Negative: return "Rotate arm outward"
            }
        }

        var icon: String {
            switch self {
            case .rest: return "hand.raised.fill"
            case .tilt1Positive: return "arrow.up"
            case .tilt1Negative: return "arrow.down"
            case .tilt2Positive: return "arrow.left"
            case .tilt2Negative: return "arrow.right"
            case .tilt3Positive: return "arrow.counterclockwise"
            case .tilt3Negative: return "arrow.clockwise"
            }
        }
    }

    @State private var activeStep: Step? = nil  // which step is being captured (nil = overview)
    @State private var capturedPoints: [Step: CalibrationPoint3D] = [:]

    // Pre-populate from existing calibration on appear
    @State private var initialized = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let step = activeStep {
                captureView(for: step)
            } else {
                overviewGrid
            }
        }
        .onAppear {
            if !initialized {
                initialized = true
                loadExisting()
            }
        }
    }

    // MARK: - Load existing calibration data into captured points

    private func loadExisting() {
        guard let cal = motion.calibration else { return }
        capturedPoints[.rest] = cal.rest
        let stepPairs: [(pos: Step, neg: Step)] = [
            (.tilt1Positive, .tilt1Negative),
            (.tilt2Positive, .tilt2Negative),
            (.tilt3Positive, .tilt3Negative)
        ]
        for (i, pair) in stepPairs.enumerated() {
            if i < cal.axes.count {
                capturedPoints[pair.pos] = cal.axes[i].positiveEnd
                capturedPoints[pair.neg] = cal.axes[i].negativeEnd
            }
        }
    }

    // MARK: - Overview Grid (shows all 7 measurements)

    private var overviewGrid: some View {
        VStack(spacing: 12) {
            HStack {
                Text("CALIBRATION")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Spacer()

                // Live sensor readout
                HStack(spacing: 16) {
                    sensorValue(label: "Pitch", value: motion.pitchDegrees)
                    sensorValue(label: "Roll", value: motion.rollDegrees)
                    sensorValue(label: "Yaw", value: motion.yawDegrees)
                }
            }

            // List of 7 measurements
            VStack(spacing: 2) {
                ForEach(Step.allCases, id: \.rawValue) { step in
                    measurementRow(for: step)
                }
            }

            HStack(spacing: 16) {
                Button(action: {
                    capturedPoints.removeAll()
                    activeStep = .rest
                }) {
                    Label("Recalibrate All", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Spacer()

                if allCaptured {
                    Button(action: buildAndComplete) {
                        Text("Done")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                } else {
                    Button(action: { activeStep = firstMissing }) {
                        Text(capturedPoints.isEmpty ? "Start Calibration" : "Continue")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding()
    }

    private func measurementRow(for step: Step) -> some View {
        let captured = capturedPoints[step]
        let isCaptured = captured != nil

        return HStack(spacing: 10) {
            Image(systemName: step.icon)
                .font(.caption)
                .foregroundColor(isCaptured ? .green : .gray)
                .frame(width: 20)

            Text(step.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isCaptured ? .white : .gray)
                .frame(width: 100, alignment: .leading)

            Text(step.instruction)
                .font(.system(size: 11))
                .foregroundColor(.gray.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)

            if let pt = captured {
                Text(String(format: "P%+.0f° R%+.0f° Y%+.0f°", pt.pitchDegrees, pt.rollDegrees, pt.yawDegrees))
                    .font(.system(size: 10))
                    .foregroundColor(.green.opacity(0.6))
                    .frame(width: 160, alignment: .trailing)
            } else {
                Text("—")
                    .font(.system(size: 10))
                    .foregroundColor(.gray.opacity(0.3))
                    .frame(width: 160, alignment: .trailing)
            }

            Button(action: { activeStep = step }) {
                Text(isCaptured ? "Redo" : "Set")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isCaptured ? Color.gray.opacity(0.3) : Color.blue.opacity(0.7))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isCaptured ? Color.green.opacity(0.03) : Color.clear)
    }

    // MARK: - Individual Capture View

    private func captureView(for step: Step) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: step.icon)
                .font(.system(size: 50))
                .foregroundColor(.blue)

            Text(step.title)
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text(step.instruction)
                .font(.title3)
                .foregroundColor(.gray)

            // Live readout
            HStack(spacing: 20) {
                sensorValue(label: "Pitch", value: motion.pitchDegrees)
                sensorValue(label: "Roll", value: motion.rollDegrees)
                sensorValue(label: "Yaw", value: motion.yawDegrees)
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)

            Spacer()

            HStack(spacing: 20) {
                Button("Back") {
                    activeStep = nil
                }
                .foregroundColor(.gray)

                Button(action: {
                    capturedPoints[step] = CalibrationPoint3D(
                        pitch: motion.pitch, roll: motion.roll, yaw: motion.yaw
                    )
                    // Advance to next uncaptured step, or return to overview
                    if let next = nextUncapturedStep(after: step) {
                        withAnimation { activeStep = next }
                    } else {
                        withAnimation { activeStep = nil }
                    }
                }) {
                    Text("Capture")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(width: 180, height: 48)
                        .background(Color.blue)
                        .cornerRadius(14)
                }
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Helpers

    private func sensorValue(label: String, value: Double) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            Text(String(format: "%+.1f°", value))
                .font(.system(.body))
                .foregroundColor(.green)
        }
    }

    private var allCaptured: Bool {
        Step.allCases.allSatisfy { capturedPoints[$0] != nil }
    }

    private var firstMissing: Step? {
        Step.allCases.first { capturedPoints[$0] == nil }
    }

    private func nextUncapturedStep(after current: Step) -> Step? {
        let steps = Step.allCases
        guard let idx = steps.firstIndex(of: current) else { return nil }
        return steps.dropFirst(idx + 1).first { capturedPoints[$0] == nil }
    }

    private func buildAndComplete() {
        guard let rest = capturedPoints[.rest] else { return }

        let defs = CalibrationData.defaultAxes
        let stepPairs: [(pos: Step, neg: Step)] = [
            (.tilt1Positive, .tilt1Negative),
            (.tilt2Positive, .tilt2Negative),
            (.tilt3Positive, .tilt3Negative)
        ]

        var axes: [TiltAxis] = []
        for (i, pair) in stepPairs.enumerated() {
            guard let posPoint = capturedPoints[pair.pos],
                  let negPoint = capturedPoints[pair.neg] else { return }
            axes.append(TiltAxis(
                name: defs[i].name,
                instruction_positive: defs[i].instrPos,
                instruction_negative: defs[i].instrNeg,
                icon_positive: defs[i].iconPos,
                icon_negative: defs[i].iconNeg,
                positiveEnd: posPoint,
                negativeEnd: negPoint
            ))
        }

        let calibration = CalibrationData(rest: rest, axes: axes)
        calibration.save()
        onComplete(calibration)
    }
}
