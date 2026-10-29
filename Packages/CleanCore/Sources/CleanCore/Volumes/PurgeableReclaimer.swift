import Foundation

/// Reclaims purgeable space the way macOS itself does it under pressure: a temporary file is written until the volume
/// reports no free space, which makes the system evict purgeable content (snapshots, caches, optimized-storage copies),
/// and the file is deleted again. Nothing of the user's is touched; the disk is full for a few seconds.
public enum PurgeableReclaimer {
    public struct Report: Sendable {
        public let purgeableBefore: Int64
        public let purgeableAfter: Int64
        public let availableBefore: Int64
        public let availableAfter: Int64
        public let written: Int64
        public let duration: TimeInterval
        /// Non-purgeable free space that became available.
        public var freed: Int64 { max(0, availableAfter - availableBefore) }
        /// Purgeable space that was released (either freed or dropped).
        public var purged: Int64 { max(0, purgeableBefore - purgeableAfter) }
    }

    public enum ReclaimError: Error, LocalizedError {
        case notWritable(String)
        case nothingToReclaim
        case writeFailed(String)
        public var errorDescription: String? {
            switch self {
            case .notWritable(let path): "Cannot write a temporary file on this disk (\(path))."
            case .nothingToReclaim: "This disk reports no purgeable space."
            case .writeFailed(let reason): "Writing the temporary file failed: \(reason)"
            }
        }
    }

    static let chunkSize = 64 * 1024 * 1024

    /// Runs the reclaim on the volume mounted at `mount`. `progress` receives bytes written so far.
    public static func reclaim(mount: String, dryRun: Bool = FileRemover.isDryRun, progress: (@Sendable (Int64) -> Void)? = nil) throws -> Report {
        let start = Date()
        let volumeURL = URL(filePath: mount)
        let before = try capacities(of: volumeURL)
        guard before.purgeable > 0 else { throw ReclaimError.nothingToReclaim }
        if dryRun {
            return Report(purgeableBefore: before.purgeable, purgeableAfter: before.purgeable, availableBefore: before.available,
                          availableAfter: before.available, written: 0, duration: 0)
        }
        let scratch = scratchFile(for: volumeURL)
        let fm = FileManager.default
        try? fm.createDirectory(at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: scratch.path, contents: nil) else { throw ReclaimError.notWritable(scratch.path) }
        defer { try? fm.removeItem(at: scratch) }
        let fd = open(scratch.path, O_WRONLY)
        guard fd >= 0 else { throw ReclaimError.notWritable(scratch.path) }
        defer { close(fd) }
        // Never leave the file behind if the process dies mid-way: unlink immediately, keep writing through the descriptor.
        unlink(scratch.path)
        fcntl(fd, F_NOCACHE, 1)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 4096)
        defer { buffer.deallocate() }
        memset(buffer, 0, chunkSize)
        var written: Int64 = 0
        // Upper bound: everything the volume could give up plus a margin, so a disk with a huge free area is not filled for nothing.
        let target = before.purgeable + before.available + 256 * 1024 * 1024
        while written < target {
            let result = write(fd, buffer, chunkSize)
            if result < 0 {
                if errno == ENOSPC || errno == EDQUOT { break }
                throw ReclaimError.writeFailed(String(cString: strerror(errno)))
            }
            written += Int64(result)
            progress?(written)
            if result < chunkSize { break }
        }
        fsync(fd)
        ftruncate(fd, 0)
        close(fd)
        let after = try capacities(of: volumeURL)
        let report = Report(purgeableBefore: before.purgeable, purgeableAfter: after.purgeable, availableBefore: before.available,
                            availableAfter: after.available, written: written, duration: Date().timeIntervalSince(start))
        record(report, mount: mount)
        return report
    }

    // MARK: - Memory of previous attempts (macOS keeps a reserved slice it never releases; do not nag about it)

    public struct Attempt: Codable, Sendable {
        public let date: Date
        public let purgeableBefore: Int64
        public let purgeableAfter: Int64
        public let availableBefore: Int64
        public let availableAfter: Int64
        public var purged: Int64 { max(0, purgeableBefore - purgeableAfter) }
        public var freed: Int64 { max(0, availableAfter - availableBefore) }
    }

    static var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/com.cleanos/purge-state.json")
    }

    static func record(_ report: Report, mount: String) {
        var state = loadState()
        state[mount] = Attempt(date: .now, purgeableBefore: report.purgeableBefore, purgeableAfter: report.purgeableAfter,
                               availableBefore: report.availableBefore, availableAfter: report.availableAfter)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    public static func lastAttempt(mount: String) -> Attempt? { loadState()[mount] }

    static func loadState() -> [String: Attempt] {
        guard let data = try? Data(contentsOf: stateURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Attempt].self, from: data)) ?? [:]
    }

    /// True when a recent attempt released almost nothing: what is left is the slice macOS reserves for itself.
    public static func looksReserved(mount: String, purgeable: Int64) -> Bool {
        guard let attempt = lastAttempt(mount: mount), Date().timeIntervalSince(attempt.date) < 24 * 3600 else { return false }
        return attempt.purged < max(50 * 1024 * 1024, purgeable / 10) && attempt.purgeableAfter >= purgeable - 50 * 1024 * 1024
    }

    static func capacities(of volume: URL) throws -> (available: Int64, purgeable: Int64) {
        let values = try volume.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? available
        return (available, max(0, important - available))
    }

    /// The temporary file lives on the volume being reclaimed: the user's cache folder for the startup disk, a hidden file at the root otherwise.
    static func scratchFile(for volume: URL) -> URL {
        let name = ".cleanos-purge-\(UUID().uuidString).tmp"
        if volume.path == "/" || volume.path == "/System/Volumes/Data" {
            return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/com.cleanos.app").appending(path: name)
        }
        return volume.appending(path: name)
    }
}
