import Foundation
import UniformTypeIdentifiers

/// Totals per file kind for Manage Files and the Overview bar.
public struct FileCategoryTotal: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let systemImage: String
    public var bytes: Int64
    public var count: Int
    /// Largest items of the category (capped).
    public var items: [ScanItem]
}

public struct FileCategoriesResult: Sendable {
    public var categories: [FileCategoryTotal]
    public var homeFolders: [ScanItem]
    public var systemBytes: Int64
    public var duration: TimeInterval
    public func total(_ id: String) -> Int64 { categories.first { $0.id == id }?.bytes ?? 0 }
}

/// One walk over the home folder (and enabled volumes) classifying files by UTType.
public actor FileCategoriesScanner {
    public init() {}

    static let definitions: [(id: String, title: String, image: String, types: [UTType], extensions: Set<String>)] = [
        ("archives", "Archives", "archivebox", [.archive, .diskImage], ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "dmg", "iso", "pkg"]),
        ("documents", "Documents", "doc.text", [.pdf, .text, .presentation, .spreadsheet, .rtf, .epub], ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "md", "rtf", "csv", "epub", "odt", "ods", "odp", "tex", "json", "xml", "parquet", "dta", "sav", "rds"]),
        ("movies", "Movie files", "film", [.movie, .video], ["mp4", "mov", "m4v", "mkv", "avi", "wmv", "webm", "flv", "mpg", "mpeg"]),
        ("music", "Music files", "music.note", [.audio], ["mp3", "m4a", "aac", "flac", "wav", "aiff", "ogg", "wma", "alac"]),
        ("pictures", "Pictures", "photo", [.image], ["jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "raw", "cr2", "nef", "arw", "psd", "svg"]),
    ]

    public static var categoryInfos: [(id: String, title: String, image: String)] { definitions.map { ($0.id, $0.title, $0.image) } }

    /// Cancelling the calling task stops the walk; the totals gathered until then are returned.
    public func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser, volumes: [VolumeInfo] = [], itemLimit: Int = 300,
                     includeSystem: Bool = true) async -> FileCategoriesResult {
        let start = Date()
        var result = await StructuredWork.run { Self.walk(home: home, volumes: volumes, itemLimit: itemLimit, includeSystem: includeSystem) }
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    /// Folders the "System" total walks, and what it leaves out: `/System/Volumes` holds the mount points of the data volume
    /// (the whole of the user's data again) and of the other volumes of the startup disk.
    static let systemRoots = ["/System", "/Library", "/private/var", "/usr"]
    static let systemExclusions: Set<String> = ["/System/Volumes"]

    nonisolated static func walk(home: URL, volumes: [VolumeInfo], itemLimit: Int, includeSystem: Bool) -> FileCategoriesResult {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isPackageKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentTypeKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var totals = definitions.map { FileCategoryTotal(id: $0.id, title: $0.title, systemImage: $0.image, bytes: 0, count: 0, items: []) }
        var buckets: [[ScanItem]] = Array(repeating: [], count: definitions.count)
        var folderBytes: [String: Int64] = [:]
        var folderIsDirectory: [String: Bool] = [:]
        let fm = FileManager.default
        var roots = [home]
        roots.append(contentsOf: volumes.filter { !$0.isRoot && !$0.isReadOnly }.map(\.url))
        for root in roots {
            var rootStat = stat()
            guard lstat(root.path, &rootStat) == 0 else { continue }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants, .producesRelativePathURLs], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                if Task.isCancelled { break }
                guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
                let bytes: Int64
                let isPackage = values.isPackage == true
                if root == home, enumerator.level == 1 { folderIsDirectory[url.relativePath] = values.isDirectory == true }
                if isPackage {
                    bytes = DirectorySizer.size(of: url, isCancelled: { Task.isCancelled }).bytes
                } else if values.isRegularFile == true {
                    bytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                } else {
                    // A folder: never walk into another mounted volume (a disk image or share mounted inside the tree).
                    var st = stat()
                    let path = url.path
                    if values.isDirectory == true, lstat(path, &st) == 0,
                       !DirectorySizer.mayDescend(into: path, device: st.st_dev, rootDevice: rootStat.st_dev, mountPoint: DirectorySizer.mountPoint(of: path), excluded: []) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if root == home, let top = url.relativePath.split(separator: "/").first {
                    folderBytes[String(top), default: 0] += bytes
                }
                guard let index = classify(url: url, type: values.contentType) else { continue }
                totals[index].bytes += bytes
                totals[index].count += 1
                buckets[index].append(ScanItem(url: url, title: url.lastPathComponent, subtitle: url.deletingLastPathComponent().path, kind: isPackage ? .bundle : .file,
                                               group: totals[index].title, size: bytes, tier: .caution, matchedBy: ["file kind"],
                                               needsRoot: !FileRemover.isUserRemovable(url), modificationDate: values.contentModificationDate)
                    .markedProtectedIfRefused(home: home.path))
                if buckets[index].count > itemLimit * 4 {
                    buckets[index].sort { $0.size > $1.size }
                    buckets[index] = Array(buckets[index].prefix(itemLimit))
                }
            }
        }
        for index in totals.indices {
            totals[index].items = Array(buckets[index].sorted { $0.size > $1.size }.prefix(itemLimit))
        }
        // Display only: the rows show where the space goes (hidden folders included, so the total is right), but whole
        // top-level folders such as ~/Documents, ~/Library or ~/.ssh are never offered for removal.
        let folders = folderBytes.map { name, bytes in
            ScanItem(url: home.appending(path: name), title: name, subtitle: "~", kind: folderIsDirectory[name] == false ? .file : .directory,
                     group: "Home folder", size: bytes, tier: .protected, matchedBy: ["home folder"])
        }
        .sorted { $0.size > $1.size }
        var systemBytes: Int64 = 0
        if includeSystem {
            for path in systemRoots {
                systemBytes += DirectorySizer.size(of: URL(filePath: path), excluding: systemExclusions, isCancelled: { Task.isCancelled }).bytes
            }
        }
        return FileCategoriesResult(categories: totals, homeFolders: folders, systemBytes: systemBytes, duration: 0)
    }

    static func classify(url: URL, type: UTType?) -> Int? {
        let ext = url.pathExtension.lowercased()
        for (index, definition) in definitions.enumerated() {
            if definition.extensions.contains(ext) { return index }
            if let type, definition.types.contains(where: { type.conforms(to: $0) }) { return index }
        }
        return nil
    }
}
