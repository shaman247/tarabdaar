import Foundation

/// The sender-side queue discipline. NOT thread-safe by itself — confined
/// to the owning link's serial queue.
///
/// Invariants:
///  - Events append in order and are never dropped or reordered.
///  - At most ONE pending frame per state type: enqueueing a state frame
///    removes any unsent frame of the same type and appends the fresh one
///    at the tail. Moving state later is always safe — it is fresher data —
///    and the link therefore hands the transport at most one fresh state
///    frame per drain, so continuous data can never queue behind itself.
///  - On lane switchover the caller re-sends pending events verbatim
///    (receiver eventSeq dedupe covers double delivery) and calls
///    `removeAllState()` — the next tick regenerates fresher frames.
public final class LinkOutbox {
    public struct Item: Equatable {
        public let bytes: [UInt8]
        /// Non-nil = coalescable state frame of this type byte.
        public let stateType: UInt8?
        public init(bytes: [UInt8], stateType: UInt8?) {
            self.bytes = bytes
            self.stateType = stateType
        }
    }

    private var items: [Item] = []
    public init() {}

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public func enqueueEvent(_ bytes: [UInt8]) {
        items.append(Item(bytes: bytes, stateType: nil))
    }

    public func enqueueState(_ bytes: [UInt8], type: UInt8) {
        items.removeAll { $0.stateType == type }
        items.append(Item(bytes: bytes, stateType: type))
    }

    /// Convenience: encodes and enqueues with the right discipline.
    public func enqueue(_ frame: TLPFrame) {
        let bytes = frame.encode()
        if frame.isState {
            enqueueState(bytes, type: frame.typeByte)
        } else {
            enqueueEvent(bytes)
        }
    }

    public func dequeue() -> Item? {
        items.isEmpty ? nil : items.removeFirst()
    }

    /// Lane switch: pending state is stale the moment a new lane activates.
    public func removeAllState() {
        items.removeAll { $0.stateType != nil }
    }

    /// Pending events, oldest first (for verbatim re-send on lane switch).
    public var pendingEvents: [[UInt8]] {
        items.compactMap { $0.stateType == nil ? $0.bytes : nil }
    }

    public func removeAll() { items.removeAll() }
}
