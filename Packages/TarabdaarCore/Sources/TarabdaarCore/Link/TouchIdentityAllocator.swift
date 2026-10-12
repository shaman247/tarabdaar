import Foundation

/// A UInt16 identity pool shared by the input lanes feeding one host.
/// Released values are reused only after a full cursor wrap; held values
/// and identities retained by downstream glide chains are skipped.
public final class TouchIdentityAllocator {
    private let lock = NSLock()
    private var nextID: UInt16 = 0
    private var active = Set<UInt16>()
    private let retaining: ((UInt16) -> Bool)?

    /// `retaining` must not call back into this allocator.
    public init(retaining: ((UInt16) -> Bool)? = nil) {
        self.retaining = retaining
    }

    func allocate() -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        for _ in 0...Int(UInt16.max) {
            let id = nextID
            nextID &+= 1
            if !active.contains(id), retaining?(id) != true {
                active.insert(id)
                return id
            }
        }
        return nil
    }

    func release(_ id: UInt16) {
        lock.lock()
        active.remove(id)
        lock.unlock()
    }
}
