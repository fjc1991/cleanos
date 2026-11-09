import Foundation

/// Caches `DirectorySizer` results per path for a short time so re-rendering a list never re-walks the disk.
public actor SizeCache {
    public struct Entry: Sendable {
        public let result: SizeResult
        public let computedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<SizeResult, Never>] = [:]
    public let maxAge: TimeInterval

    public init(maxAge: TimeInterval = 300) {
        self.maxAge = maxAge
    }

    /// Returns the cached size, or measures the item on a background task.
    public func size(of url: URL) async -> SizeResult {
        let key = url.standardizedFileURL.path
        if let entry = entries[key], Date().timeIntervalSince(entry.computedAt) < maxAge {
            return entry.result
        }
        if let task = inFlight[key] { return await task.value }
        let task = Task.detached(priority: .utility) { DirectorySizer.size(of: url) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        entries[key] = Entry(result: result, computedAt: .now)
        return result
    }

    /// The cached size if it is younger than `maxAge`, like `size(of:)` would return without measuring.
    public func cached(_ url: URL) -> SizeResult? {
        guard let entry = entries[url.standardizedFileURL.path], Date().timeIntervalSince(entry.computedAt) < maxAge else { return nil }
        return entry.result
    }

    public func invalidate(_ url: URL) {
        entries[url.standardizedFileURL.path] = nil
    }

    public func invalidateAll() {
        entries.removeAll()
    }
}
