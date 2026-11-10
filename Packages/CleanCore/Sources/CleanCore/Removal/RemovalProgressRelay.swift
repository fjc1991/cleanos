import Foundation

/// Collects a removal's progress calls, which arrive from the executor once or twice per item (hundreds a second
/// for small caches), so a window can pick up the latest state at its own pace instead of redrawing for each item.
public final class RemovalProgressRelay: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var done = 0
        public var total = 0
        /// The item being removed, or the last one while the next has not started.
        public var current: ScanItem?
        /// Items finished since the last `take()`, oldest first; only the most recent few are kept.
        public var finished: [ScanItem] = []
        /// Size of everything finished so far.
        public var freed: Int64 = 0
        /// False when nothing was reported since the last `take()`.
        public var changed = false
    }

    private let lock = NSLock()
    private let keeping: Int
    private var snapshot = Snapshot()
    private var inFlight: ScanItem?

    /// - Parameter keeping: how many finished items to hold between two `take()` calls.
    public init(keeping: Int = 5) {
        self.keeping = max(1, keeping)
    }

    /// The executor's progress callback: `current` is the item being started, or nil when one has just finished.
    public func report(done: Int, total: Int, current: ScanItem?) {
        lock.lock(); defer { lock.unlock() }
        if done > snapshot.done, let item = inFlight {
            snapshot.finished.append(item)
            if snapshot.finished.count > keeping { snapshot.finished.removeFirst() }
            snapshot.freed += item.size
            inFlight = nil
        }
        if let current {
            inFlight = current
            snapshot.current = current
        }
        snapshot.done = done
        snapshot.total = total
        snapshot.changed = true
    }

    /// The state now. What finished since the previous call is handed out once.
    public func take() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let result = snapshot
        snapshot.finished = []
        snapshot.changed = false
        return result
    }
}
