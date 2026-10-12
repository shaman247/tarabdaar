import Foundation

/// An empty bank is a successful clear; a failed build preserves the running engine.
enum EngineBuildResult<Engine> {
    case ready(Engine)
    case empty
    case failed
}

/// Main-thread requests/publication, with a locked generation check before worker construction.
final class EngineBuildCoordinator<Engine> {
    typealias Work = () -> Void
    typealias Schedule = (@escaping Work) -> Void

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pending = false
    private var succeeded = false

    /// A newer model edit must replace this pending snapshot rather than only update the old engine.
    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    /// Repeated enables reuse pending or successful builds, including an empty bank.
    var needsBuild: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending && !succeeded
    }

    func request(on queue: DispatchQueue,
                 build: @escaping () -> EngineBuildResult<Engine>,
                 publish: @escaping (Engine?) -> Void,
                 failed: @escaping Work) {
        request(scheduleBuild: { queue.async(execute: DispatchWorkItem(block: $0)) },
                schedulePublication: { DispatchQueue.main.async(execute: DispatchWorkItem(block: $0)) },
                build: build, publish: publish, failed: failed)
    }

    /// Injected schedulers preserve main-thread requests/publication while exposing the worker boundary.
    func request(scheduleBuild: Schedule, schedulePublication: @escaping Schedule,
                 build: @escaping () -> EngineBuildResult<Engine>,
                 publish: @escaping (Engine?) -> Void,
                 failed: @escaping Work) {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        generation &+= 1
        let token = generation
        pending = true
        succeeded = false
        lock.unlock()
        scheduleBuild { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            let result = build()
            // Dispose an already-obsolete engine on the worker whenever possible.
            guard self.isCurrent(token) else { return }
            schedulePublication { [weak self] in
                dispatchPrecondition(condition: .onQueue(.main))
                guard let self else { return }
                self.lock.lock()
                guard token == self.generation else { self.lock.unlock(); return }
                self.pending = false
                switch result {
                case .ready, .empty: self.succeeded = true
                case .failed: self.succeeded = false
                }
                self.lock.unlock()
                // Publication and disposal of rejected engines never hold the state lock.
                switch result {
                case .ready(let engine): publish(engine)
                case .empty: publish(nil)
                case .failed: failed()
                }
            }
        }
    }

    /// Cancel outstanding work on disable while retaining an already-successful idle mount.
    func invalidate() {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        generation &+= 1
        pending = false
        lock.unlock()
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == generation
    }
}
