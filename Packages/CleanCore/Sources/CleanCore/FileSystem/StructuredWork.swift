import Foundation

/// Runs blocking file-system work off the calling actor as a child task. Unlike `Task.detached`, the child inherits the
/// caller's cancellation, so `Task.isCancelled` inside the work turns true as soon as the caller's task is cancelled.
enum StructuredWork {
    static func run<T: Sendable>(priority: TaskPriority = .utility, _ work: @escaping @Sendable () -> T) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask(priority: priority) { work() }
            // Exactly one child was added, so `next()` returns its value (also after cancellation).
            return await group.next()!
        }
    }
}
