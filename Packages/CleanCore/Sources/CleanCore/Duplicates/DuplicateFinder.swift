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

    /// What the last `find` left out.
    public struct Stats: Sendable, Equatable {
        /// Files at least `minimumSize` that were looked at.
        public var filesConsidered = 0
        /// iCloud / File Provider placeholders that are not downloaded: reading them would download them, so they are skipped.
        public var skippedNotDownloaded = 0
        /// Extra paths of hard-linked files: they share one copy on disk, so they are not duplicates.
        public var hardLinksCollapsed = 0
        public init() {}
    }

    /// Counts of the most recent `find` (read after it returns).
    public private(set) var lastStats = Stats()

    /// Cancelling the calling task stops the file walk and the hashing; a cancelled search returns no groups.
    public func find(roots: [URL], options: Options = Options(), progress: (@Sendable (String) -> Void)? = nil) async -> [DuplicateGroup] {
        progress?("Listing files…")
        lastStats = Stats()
        let collected = await StructuredWork.run { Self.collect(roots: roots, options: options) }
        lastStats = collected.stats
        if Task.isCancelled { return [] }
        let candidates = collected.candidates
        let bySize = Dictionary(grouping: candidates, by: \.size).filter { $0.value.count > 1 }
        progress?("Comparing \(bySize.values.reduce(0) { $0 + $1.count }) files of equal size…")

        var byPartial: [String: [Candidate]] = [:]
        await withTaskGroup(of: (String, Candidate)?.self) { group in
            var pending = bySize.values.flatMap { $0 }.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard !Task.isCancelled, let candidate = pending.next() else { return false }
                group.addTask { Self.hash(candidate.url, partial: true).map { ("\(candidate.size):\($0)", candidate) } }
                return true
            }
            while running < options.maxConcurrency, addNext() { running += 1 }
            for await entry in group {
                if let (key, candidate) = entry { byPartial[key, default: []].append(candidate) }
                if !addNext() { running -= 1 }
            }
        }
        if Task.isCancelled { return [] }
        let partialGroups = byPartial.values.filter { $0.count > 1 }
        progress?("Verifying \(partialGroups.reduce(0) { $0 + $1.count }) candidates…")

        var byFull: [String: [Candidate]] = [:]
        await withTaskGroup(of: (String, Candidate)?.self) { group in
            var pending = partialGroups.flatMap { $0 }.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard !Task.isCancelled, let candidate = pending.next() else { return false }
                group.addTask { Self.hash(candidate.url, partial: false).map { ("\(candidate.size):\($0)", candidate) } }
                return true
            }
            while running < options.maxConcurrency, addNext() { running += 1 }
            for await entry in group {
                if let (key, candidate) = entry { byFull[key, default: []].append(candidate) }
                if !addNext() { running -= 1 }
            }
        }
        if Task.isCancelled { return [] }
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

    /// `SF_DATALESS`: the file's contents live in iCloud or a File Provider and reading it downloads them.
    static let datalessFlag: UInt32 = 0x4000_0000

    /// True for a placeholder whose contents are not on this Mac (reading it would start a download).
    static func isPlaceholder(flags: UInt32, downloadingStatus: URLUbiquitousItemDownloadingStatus?) -> Bool {
        if flags & datalessFlag != 0 { return true }
        if let downloadingStatus, downloadingStatus != .current { return true }
        return false
    }

    /// Regular, non-empty, downloaded files of at least `minimumSize`, one path per file on disk (hard links collapse).
    nonisolated static func collect(roots: [URL], options: Options) -> (candidates: [Candidate], stats: Stats) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey, .isPackageKey]
        var out: [Candidate] = []
        var stats = Stats()
        var seen: Set<FileID> = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                if Task.isCancelled { return (out, stats) }
                if options.excludedPathPrefixes.contains(where: { url.path.hasPrefix($0) }) { enumerator.skipDescendants(); continue }
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let size = Int64(values.fileSize ?? 0)
                // Empty files all have the same contents without being copies of anything.
                guard size > 0, size >= options.minimumSize else { continue }
                var st = stat()
                guard lstat(url.path, &st) == 0 else { continue }
                stats.filesConsidered += 1
                let status = (st.st_flags & datalessFlag) != 0 ? nil
                    : (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
                if isPlaceholder(flags: st.st_flags, downloadingStatus: status) { stats.skippedNotDownloaded += 1; continue }
                if !seen.insert(FileID(device: st.st_dev, inode: st.st_ino)).inserted { stats.hardLinksCollapsed += 1; continue }
                out.append(Candidate(url: url, size: size, created: values.creationDate, modified: values.contentModificationDate))
            }
        }
        return (out, stats)
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
