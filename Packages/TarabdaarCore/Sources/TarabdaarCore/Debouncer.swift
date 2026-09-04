import Foundation

/// ONE trailing-edge debounce: `schedule` replaces any pending body and
/// runs the newest one `delay` after the last call, on `queue`. Callable
/// from any thread. Every settle-then-act path in the app (the physics
/// push, the tarab rebuild and save, the tanpura table build) is one of
/// these, so their delays read side by side.
public final class Debouncer {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: DispatchWorkItem?

    public init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    /// Run `body` once the calls have settled for `delay`.
    public func schedule(_ body: @escaping () -> Void) {
        let work = DispatchWorkItem(block: body)
        lock.lock()
        pending?.cancel()
        pending = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Drop the pending body, if any (the caller acted right away).
    public func cancel() {
        lock.lock()
        pending?.cancel()
        pending = nil
        lock.unlock()
    }
}
