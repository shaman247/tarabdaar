import SarangiKit

/// A shared drone pattern toggled by button onsets and advanced on a timer.
public struct DroneSequence {
    public static let defaultSteps = [0, 1, 2, 2]
    public static let interval = 2.0

    public static func normalized(_ steps: [Int]) -> [Int] {
        let valid = steps.filter { (0..<InstrumentState.droneSlotCount).contains($0) }
        return valid.isEmpty ? defaultSteps : valid
    }

    private var nextStep = 0
    private var buttonsDown: Set<JoyConControl> = []
    private var nextDeadline: Double?
    public private(set) var heldSlot: Int?
    public var isRunning: Bool { heldSlot != nil }

    public init() {}

    /// Editing the pattern restarts it without losing a held slot's release.
    public mutating func restart() { nextStep = 0 }

    public mutating func press(steps: [Int], enabled: Bool = true,
                               control: JoyConControl = .dpadDown,
                               now: Double = 0) -> Int? {
        guard buttonsDown.insert(control).inserted else { return nil }
        guard enabled else { return nil }
        if isRunning {
            heldSlot = nil
            nextDeadline = nil
            return nil
        }
        return advance(steps: steps, now: now)
    }

    /// A delayed tick plays one step and reanchors, never a burst of missed notes.
    public mutating func advanceIfDue(steps: [Int], now: Double) -> Int? {
        guard isRunning, let deadline = nextDeadline, now >= deadline else { return nil }
        return advance(steps: steps, now: now)
    }

    private mutating func advance(steps: [Int], now: Double) -> Int {
        let steps = Self.normalized(steps)
        let slot = steps[nextStep % steps.count]
        nextStep = (nextStep + 1) % steps.count
        heldSlot = slot
        nextDeadline = now + Self.interval
        return slot
    }

    public mutating func release(control: JoyConControl = .dpadDown) {
        buttonsDown.remove(control)
    }

    public mutating func cancel() -> Int? {
        defer {
            buttonsDown.removeAll()
            heldSlot = nil
            nextDeadline = nil
        }
        return heldSlot
    }
}
