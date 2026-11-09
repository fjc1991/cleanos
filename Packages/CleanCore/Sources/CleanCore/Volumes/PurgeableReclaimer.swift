import Foundation
import os

/// Reclaims purgeable space the way macOS itself does it under pressure: a temporary file is written until the volume runs
/// low on free space, which makes the system evict purgeable content (snapshots, caches, optimized-storage copies), and the
/// file is deleted again. Nothing of the user's is touched.
///
/// The write is only worth it when the free space is small compared with the purgeable space: the file has to grow to roughly
/// the free space before macOS reacts, so on a disk with lots of free room it would mean writing hundreds of gigabytes for a
/// few gigabytes macOS hands back on its own when space is needed. `plannedWrite(available:purgeable:)` encodes that limit,
/// and the write stops as soon as macOS has released the purgeable space.
public enum PurgeableReclaimer {
    public struct Report: Sendable {
        public let purgeableBefore: Int64
        public let purgeableAfter: Int64
        public let availableBefore: Int64
        public let availableAfter: Int64
        public let written: Int64
        public let duration: TimeInterval
        /// True when the user cancelled before macOS released the space.
        public var cancelled: Bool = false
        /// Non-purgeable free space that became available.
        public var freed: Int64 { max(0, availableAfter - availableBefore) }
        /// Purgeable space that was released (either freed or dropped).
        public var purged: Int64 { max(0, purgeableBefore - purgeableAfter) }
    }

    public enum ReclaimError: Error, LocalizedError {
        case notWritable(String)
        case nothingToReclaim
        case writeFailed(String)
        /// Making macOS purge would mean writing this many bytes; macOS releases the space by itself when it is needed.
        case wouldWriteTooMuch(Int64)
        case alreadyRunning
        public var errorDescription: String? {
            switch self {
            case .notWritable(let path): "Cannot write a temporary file on this disk (\(path))."
            case .nothingToReclaim: "This disk reports no purgeable space."
            case .writeFailed(let reason): "Writing the temporary file failed: \(reason)"
            case .wouldWriteTooMuch(let bytes): "Reclaiming would mean writing about \(bytes.formattedBytes) of temporary data. macOS releases purgeable space by itself when an app needs it."
            case .alreadyRunning: "Purgeable space is already being reclaimed."
            }
        }
    }

    static let chunkSize = 64 * 1024 * 1024
    /// Capacities are re-read after this many chunks (512 MB).
    static let chunksPerCheck = 8
    /// Free space that never needs a reclaim: below this macOS has not started purging yet anyway.
    static let minimumWriteAllowance: Int64 = 20 * 1024 * 1024 * 1024
    static let margin: Int64 = 256 * 1024 * 1024

    /// Upper bound of what the reclaim writes, or nil when the write is out of proportion to the purgeable space (free space
    /// above max(2 × purgeable, 20 GB)). macOS starts purging once the file has used up about the free space; the bound adds
    /// the purgeable space it may hand back meanwhile and a margin. The write usually stops well before it.
    public static func plannedWrite(available: Int64, purgeable: Int64) -> Int64? {
        guard purgeable > 0, available <= max(2 * purgeable, minimumWriteAllowance) else { return nil }
        return max(0, available) + purgeable + margin
    }

    /// True once macOS has released (nearly) all of the purgeable space it reported at the start.
    static func hasReleased(purgeableBefore: Int64, purgeableNow: Int64) -> Bool {
        purgeableNow <= max(64 * 1024 * 1024, purgeableBefore / 10)
    }

    private static let inProgress = OSAllocatedUnfairLock(initialState: false)

    /// Runs the reclaim on the volume mounted at `mount`. `progress` receives bytes written so far; `isCancelled` is polled
    /// for every chunk. Only one reclaim runs at a time.
    public static func reclaim(mount: String, dryRun: Bool = FileRemover.isDryRun, progress: (@Sendable (Int64) -> Void)? = nil,
                               isCancelled: @Sendable () -> Bool = { false }) throws -> Report {
        let start = Date()
        let volumeURL = URL(filePath: mount)
        let before = try capacities(of: volumeURL)
        guard before.purgeable > 0 else { throw ReclaimError.nothingToReclaim }
        guard let target = plannedWrite(available: before.available, purgeable: before.purgeable) else {
            throw ReclaimError.wouldWriteTooMuch(before.available)
        }
        if dryRun {
            return Report(purgeableBefore: before.purgeable, purgeableAfter: before.purgeable, availableBefore: before.available,
                          availableAfter: before.available, written: 0, duration: 0)
        }
        let claimed = inProgress.withLock { running -> Bool in
            if running { return false }
            running = true
            return true
        }
        guard claimed else { throw ReclaimError.alreadyRunning }
        defer { inProgress.withLock { $0 = false } }

        let outcome = try writeUntilPurged(volumeURL: volumeURL, before: before, target: target, progress: progress, isCancelled: isCancelled)
        let after = try capacities(of: volumeURL)
        var report = Report(purgeableBefore: before.purgeable, purgeableAfter: after.purgeable, availableBefore: before.available,
                            availableAfter: after.available, written: outcome.written, duration: Date().timeIntervalSince(start))
        report.cancelled = outcome.cancelled
        record(report, mount: mount)
        return report
    }

    /// Writes zeros to an unlinked scratch file until macOS has released the purgeable space, the target is reached, the disk
    /// is full or the caller cancels; the file's blocks are given back before this returns.
    static func writeUntilPurged(volumeURL: URL, before: (available: Int64, purgeable: Int64), target: Int64,
                                 progress: (@Sendable (Int64) -> Void)?, isCancelled: @Sendable () -> Bool) throws -> (written: Int64, cancelled: Bool) {
        let scratch = scratchFile(for: volumeURL)
        let fm = FileManager.default
        try? fm.createDirectory(at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: scratch.path, contents: nil) else { throw ReclaimError.notWritable(scratch.path) }
        defer { try? fm.removeItem(at: scratch) }
        let fd = open(scratch.path, O_WRONLY)
        guard fd >= 0 else { throw ReclaimError.notWritable(scratch.path) }
        // The only close of the descriptor; truncating first hands the blocks back even before it runs.
        defer { ftruncate(fd, 0); close(fd) }
        // Never leave the file behind if the process dies mid-way: unlink immediately, keep writing through the descriptor.
        unlink(scratch.path)
        _ = fcntl(fd, F_NOCACHE, 1)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 4096)
        defer { buffer.deallocate() }
        memset(buffer, 0, chunkSize)
        var written: Int64 = 0
        var chunks = 0
        while written < target {
            if isCancelled() { return (written, true) }
            let result = write(fd, buffer, chunkSize)
            if result < 0 {
                if errno == ENOSPC || errno == EDQUOT { break }
                throw ReclaimError.writeFailed(String(cString: strerror(errno)))
            }
            written += Int64(result)
            progress?(written)
            if result < chunkSize { break }
            chunks += 1
            if chunks % chunksPerCheck == 0, let now = try? capacities(of: volumeURL),
               hasReleased(purgeableBefore: before.purgeable, purgeableNow: now.purgeable) {
                break
            }
        }
        fsync(fd)
        return (written, false)
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

    /// Fresh capacities: a new URL each time, because URL caches resource values and the loop must see macOS purge.
    static func capacities(of volume: URL) throws -> (available: Int64, purgeable: Int64) {
        let values = try URL(filePath: volume.path).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
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
