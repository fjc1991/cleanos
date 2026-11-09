import Foundation
import UniformTypeIdentifiers

/// Finds the biggest files (and app bundles) under the given roots.
public actor LargeFilesScanner {
    public init() {}

    public struct Options: Sendable {
        public var minimumSize: Int64 = 50 * 1024 * 1024
        public var limit = 500
        public var excludedPathPrefixes: [String] = []
        public init() {}
    }

    /// Cancelling the calling task stops the walk; what was found until then is returned.
    public func scan(roots: [URL], options: Options = Options(), progress: (@Sendable (Int) -> Void)? = nil) async -> [ScanItem] {
        let found = await StructuredWork.run { Self.walk(roots: roots, options: options, progress: progress) }
        return Array(found.sorted { $0.size > $1.size }.prefix(options.limit))
    }

    static let keys: Set<URLResourceKey> = [.isRegularFileKey, .isPackageKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey,
                                            .contentModificationDateKey, .contentAccessDateKey, .contentTypeKey, .isSymbolicLinkKey]

    nonisolated static func walk(roots: [URL], options: Options, progress: (@Sendable (Int) -> Void)?) -> [ScanItem] {
        var items: [ScanItem] = []
        let fm = FileManager.default
        var scanned = 0
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                if Task.isCancelled { return items }
                let path = url.path
                if options.excludedPathPrefixes.contains(where: { path.hasPrefix($0) }) { enumerator.skipDescendants(); continue }
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isSymbolicLink == true { continue }
                scanned += 1
                if scanned % 5000 == 0 { progress?(scanned) }
                if values.isPackage == true {
                    let size = DirectorySizer.size(of: url, isCancelled: { Task.isCancelled })
                    if size.bytes >= options.minimumSize { items.append(item(url, bytes: size.bytes, values: values, kind: .bundle)) }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let bytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                if bytes >= options.minimumSize { items.append(item(url, bytes: bytes, values: values, kind: .file)) }
            }
        }
        return items
    }

    static func item(_ url: URL, bytes: Int64, values: URLResourceValues, kind: ItemKind) -> ScanItem {
        let type = values.contentType
        var payload: [String: String] = [:]
        if let type { payload["kind"] = type.localizedDescription ?? type.identifier }
        if let accessed = values.contentAccessDate { payload["lastOpened"] = ISO8601DateFormatter().string(from: accessed) }
        return ScanItem(url: url, title: url.lastPathComponent, subtitle: url.deletingLastPathComponent().path, kind: kind, group: "Biggest Files",
                        size: bytes, tier: kind == .bundle ? .caution : .normal, matchedBy: ["size ≥ threshold"],
                        needsRoot: !FileRemover.isUserRemovable(url), modificationDate: values.contentModificationDate, payload: payload)
    }
}
