import Foundation

/// A held-input low-pass that keeps advancing between change-gated sensor reports.
struct AccelerationSmoother {
    private var seconds = 0.0
    private var input = 0.0
    private var output = 0.0
    private var lastTime: TimeInterval?

    mutating func value(at time: TimeInterval) -> Double {
        let dt = max(0, time - (lastTime ?? time))
        lastTime = time
        if seconds <= 0 {
            output = input
        } else {
            output += (input - output) * -expm1(-dt / seconds)
            if abs(output - input) < 1e-9 { output = input }
        }
        return output
    }

    mutating func setInput(_ value: Double, at time: TimeInterval) {
        _ = self.value(at: time)
        input = min(max(value, 0), 1)
    }

    mutating func setTime(_ seconds: Double, at time: TimeInterval) {
        _ = value(at: time)
        self.seconds = max(0, seconds)
    }

    mutating func reset() {
        input = 0
        output = 0
        lastTime = nil
    }
}
