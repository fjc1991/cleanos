import Foundation

/// Result of measuring a file-system item.
public struct SizeResult: Sendable, Equatable, Codable {
    public var bytes: Int64
    public var fileCount: Int
    public var directoryCount: Int

    public init(bytes: Int64, fileCount: Int, directoryCount: Int) {
        self.bytes = bytes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
    }

    public static let zero = SizeResult(bytes: 0, fileCount: 0, directoryCount: 0)

    public static func + (lhs: SizeResult, rhs: SizeResult) -> SizeResult {
        SizeResult(bytes: lhs.bytes + rhs.bytes, fileCount: lhs.fileCount + rhs.fileCount,
                   directoryCount: lhs.directoryCount + rhs.directoryCount)
    }

    /// `N files and M folders`, matching the wording of the original apps.
    public var itemSummary: String {
        var parts: [String] = []
        if fileCount > 0 { parts.append(fileCount == 1 ? "1 file" : "\(fileCount) files") }
        if directoryCount > 0 { parts.append(directoryCount == 1 ? "1 folder" : "\(directoryCount) folders") }
        return parts.isEmpty ? "empty" : parts.joined(separator: " and ")
    }
}

/// Measures items on disk using allocated size (what the volume actually gives back when the item is removed).
/// Symbolic links are never followed, so a link to a huge folder counts as one small file.
public enum DirectorySizer {
    static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
    ]

    /// Measures one item synchronously. Call from a background task for large trees.
    public static func size(of url: URL, isCancelled: @Sendable () -> Bool = { false }) -> SizeResult {
        guard let values = try? url.resourceValues(forKeys: keys) else { return .zero }
        if values.isSymbolicLink == true {
            return SizeResult(bytes: bytes(from: values), fileCount: 1, directoryCount: 0)
        }
        guard values.isDirectory == true else {
            return SizeResult(bytes: bytes(from: values), fileCount: 1, directoryCount: 0)
        }
        var result = SizeResult(bytes: 0, fileCount: 0, directoryCount: 1)
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
        ) else { return result }
        for case let child as URL in enumerator {
            if isCancelled() { break }
            guard let v = try? child.resourceValues(forKeys: keys) else { continue }
            if v.isDirectory == true, v.isSymbolicLink != true {
                result.directoryCount += 1
                continue
            }
            result.fileCount += 1
            result.bytes += bytes(from: v)
        }
        return result
    }

    /// Measures many items concurrently, at most `maxConcurrency` at a time.
    public static func sizes(of urls: [URL], maxConcurrency: Int = 4) async -> [URL: SizeResult] {
        var results: [URL: SizeResult] = [:]
        await withTaskGroup(of: (URL, SizeResult).self) { group in
            var iterator = urls.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard let url = iterator.next() else { return false }
                group.addTask { (url, size(of: url, isCancelled: { Task.isCancelled })) }
                return true
            }
            while running < max(1, maxConcurrency), addNext() { running += 1 }
            for await (url, size) in group {
                results[url] = size
                if !addNext() { running -= 1 }
            }
        }
        return results
    }

    static func bytes(from v: URLResourceValues) -> Int64 {
        Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
    }
}
