import Foundation
import CryptoKit

/// Files with identical contents.
public struct DuplicateGroup: Identifiable, Sendable, Hashable {
    public let id: String
    public let size: Int64
    public var files: [ScanItem]
    public var wastedBytes: Int64 { size * Int64(max(0, files.count - 1)) }
}

/// Size bucket → partial hash → full hash, the classic three-stage duplicate search.
public actor DuplicateFinder {
    public init() {}

    public struct Options: Sendable {
        public var minimumSize: Int64 = 100 * 1024
        public var excludedPathPrefixes: [String] = []
        public var maxConcurrency = 4
        public init() {}
    }

    public func find(roots: [URL], options: Options = Options(), progress: (@Sendable (String) -> Void)? = nil) async -> [DuplicateGroup] {
        progress?("Listing files…")
        let candidates = await Task.detached(priority: .utility) { Self.collect(roots: roots, options: options) }.value
        let bySize = Dictionary(grouping: candidates, by: \.size).filter { $0.value.count > 1 }
        progress?("Comparing \(bySize.values.reduce(0) { $0 + $1.count }) files of equal size…")

        var byPartial: [String: [Candidate]] = [:]
        await withTaskGroup(of: (String, Candidate)?.self) { group in
            var pending = bySize.values.flatMap { $0 }.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard let candidate = pending.next() else { return false }
                group.addTask { Self.hash(candidate.url, partial: true).map { ("\(candidate.size):\($0)", candidate) } }
                return true
            }
            while running < options.maxConcurrency, addNext() { running += 1 }
            for await entry in group {
                if let (key, candidate) = entry { byPartial[key, default: []].append(candidate) }
                if !addNext() { running -= 1 }
            }
        }
        let partialGroups = byPartial.values.filter { $0.count > 1 }
        progress?("Verifying \(partialGroups.reduce(0) { $0 + $1.count }) candidates…")

        var byFull: [String: [Candidate]] = [:]
        await withTaskGroup(of: (String, Candidate)?.self) { group in
            var pending = partialGroups.flatMap { $0 }.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard let candidate = pending.next() else { return false }
                group.addTask { Self.hash(candidate.url, partial: false).map { ("\(candidate.size):\($0)", candidate) } }
                return true
            }
            while running < options.maxConcurrency, addNext() { running += 1 }
            for await entry in group {
                if let (key, candidate) = entry { byFull[key, default: []].append(candidate) }
                if !addNext() { running -= 1 }
            }
        }
        return byFull.compactMap { key, candidates -> DuplicateGroup? in
            guard candidates.count > 1 else { return nil }
            let files = candidates.sorted { ($0.created ?? .distantFuture, $0.url.pathComponents.count) < ($1.created ?? .distantFuture, $1.url.pathComponents.count) }
                .map { c in ScanItem(url: c.url, title: c.url.lastPathComponent, subtitle: c.url.deletingLastPathComponent().path, kind: .file, group: "Duplicates",
                                     size: c.size, tier: .normal, matchedBy: ["identical contents"], needsRoot: !FileRemover.isUserRemovable(c.url), modificationDate: c.modified) }
            return DuplicateGroup(id: key, size: candidates[0].size, files: files)
        }
        .sorted { $0.wastedBytes > $1.wastedBytes }
    }

    /// Keeps the oldest copy in the shallowest folder of every group and returns the rest.
    public static func smartSelection(_ groups: [DuplicateGroup]) -> [ScanItem] {
        groups.flatMap { Array($0.files.dropFirst()) }
    }

    struct Candidate: Sendable { let url: URL; let size: Int64; let created: Date?; let modified: Date? }

    nonisolated static func collect(roots: [URL], options: Options) -> [Candidate] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey, .isPackageKey]
        var out: [Candidate] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                if Task.isCancelled { return out }
                if options.excludedPathPrefixes.contains(where: { url.path.hasPrefix($0) }) { enumerator.skipDescendants(); continue }
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let size = Int64(values.fileSize ?? 0)
                guard size >= options.minimumSize else { continue }
                out.append(Candidate(url: url, size: size, created: values.creationDate, modified: values.contentModificationDate))
            }
        }
        return out
    }

    /// SHA-256 of the first and last 64 KB (partial) or of the whole file.
    nonisolated static func hash(_ url: URL, partial: Bool) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        if partial {
            let chunk = 64 * 1024
            guard let head = try? handle.read(upToCount: chunk) else { return nil }
            hasher.update(data: head)
            if let size = try? handle.seekToEnd(), size > UInt64(chunk * 2) {
                try? handle.seek(toOffset: size - UInt64(chunk))
                if let tail = try? handle.read(upToCount: chunk) { hasher.update(data: tail) }
            }
        } else {
            while let data = try? handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                hasher.update(data: data)
                if Task.isCancelled { return nil }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
