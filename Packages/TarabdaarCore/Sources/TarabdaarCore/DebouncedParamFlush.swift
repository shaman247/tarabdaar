import Foundation

/// THE REBUILD FUNNEL: rebuild-path parameter values arriving from any
/// thread (a composite sweep, a tilt binding, the strike blend) merged
/// into ONE debounced main-thread flush — the last value per key wins, and
/// a burst of axis frames costs a single crossfaded rebuild rather than
/// one per frame.
///
/// Extracted from `AppController.queueRebuildValues`; the flush itself
/// (the physics store + the hybrid headroom cache) stays with the owner.
public final class DebouncedParamFlush {

    private let lock = NSLock()
    private var pending: [String: Double] = [:]
    private var scheduled = false

    private let delay: TimeInterval
    private let flush: ([String: Double]) -> Void
    /// Injected for tests; the app schedules on the main queue.
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    public init(delay: TimeInterval = 0.25,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void
                    = { d, work in
                        DispatchQueue.main.asyncAfter(deadline: .now() + d,
                                                      execute: work)
                    },
                flush: @escaping ([String: Double]) -> Void) {
        self.delay = delay
        self.schedule = schedule
        self.flush = flush
    }

    /// Merge values into the pending set, scheduling the flush if none is
    /// already in flight. Thread-safe; empty input is a no-op.
    public func queue(_ values: [String: Double]) {
        guard !values.isEmpty else { return }
        lock.lock()
        pending.merge(values) { _, new in new }
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard needsSchedule else { return }
        schedule(delay) { [weak self] in self?.fire() }
    }

    private func fire() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        scheduled = false
        lock.unlock()
        flush(batch)
    }
}
