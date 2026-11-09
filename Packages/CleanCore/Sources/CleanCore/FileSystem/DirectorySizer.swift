import Foundation

/// Result of measuring a file-system item.
public struct SizeResult: Sendable, Equatable, Codable {
    public var bytes: Int64
    public var fileCount: Int
    public var directoryCount: Int
    /// Folders inside the item that could not be read (EPERM/EACCES). Their contents are missing from `bytes`.
    public var deniedDirectoryCount: Int

    public init(bytes: Int64, fileCount: Int, directoryCount: Int, deniedDirectoryCount: Int = 0) {
        self.bytes = bytes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.deniedDirectoryCount = deniedDirectoryCount
    }

    enum CodingKeys: String, CodingKey { case bytes, fileCount, directoryCount, deniedDirectoryCount }

    /// Results encoded before `deniedDirectoryCount` existed still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bytes = try container.decode(Int64.self, forKey: .bytes)
        fileCount = try container.decode(Int.self, forKey: .fileCount)
        directoryCount = try container.decode(Int.self, forKey: .directoryCount)
        deniedDirectoryCount = try container.decodeIfPresent(Int.self, forKey: .deniedDirectoryCount) ?? 0
    }

    public static let zero = SizeResult(bytes: 0, fileCount: 0, directoryCount: 0)

    public static func + (lhs: SizeResult, rhs: SizeResult) -> SizeResult {
        SizeResult(bytes: lhs.bytes + rhs.bytes, fileCount: lhs.fileCount + rhs.fileCount,
                   directoryCount: lhs.directoryCount + rhs.directoryCount,
                   deniedDirectoryCount: lhs.deniedDirectoryCount + rhs.deniedDirectoryCount)
    }

    /// `N files and M folders`, matching the wording of the original apps.
    public var itemSummary: String {
        var parts: [String] = []
        if fileCount > 0 { parts.append(fileCount == 1 ? "1 file" : "\(fileCount) files") }
        if directoryCount > 0 { parts.append(directoryCount == 1 ? "1 folder" : "\(directoryCount) folders") }
        return parts.isEmpty ? "empty" : parts.joined(separator: " and ")
    }
}

/// Identity of a file on disk: hard links share it.
struct FileID: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
}

/// Measures items on disk using allocated size (what the volume actually gives back when the item is removed).
/// Symbolic links are never followed, so a link to a huge folder counts as one small file. Hard-linked files are counted
/// once, and the walk never enters another mounted volume.
public enum DirectorySizer {
    static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .linkCountKey,
    ]

    /// Measures one item synchronously. Call from a background task for large trees.
    /// `excluding` lists absolute folder paths the walk does not enter (for example `/System/Volumes`).
    public static func size(of url: URL, excluding excludedPaths: Set<String> = [], isCancelled: @Sendable () -> Bool = { false }) -> SizeResult {
        guard let values = try? url.resourceValues(forKeys: keys) else { return .zero }
        if values.isSymbolicLink == true {
            return SizeResult(bytes: bytes(from: values), fileCount: 1, directoryCount: 0)
        }
        guard values.isDirectory == true else {
            return SizeResult(bytes: bytes(from: values), fileCount: 1, directoryCount: 0)
        }
        var result = SizeResult(bytes: 0, fileCount: 0, directoryCount: 1)
        var rootStat = stat()
        guard lstat(url.path, &rootStat) == 0 else { return result }
        var denied = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, error in
                if permissionDenial(in: error) != nil { denied += 1 }
                return true
            }
        ) else { return result }
        var seenLinked: Set<FileID> = []
        for case let child as URL in enumerator {
            if isCancelled() { break }
            guard let v = try? child.resourceValues(forKeys: keys) else { continue }
            if v.isDirectory == true, v.isSymbolicLink != true {
                var st = stat()
                let path = child.path
                if lstat(path, &st) == 0,
                   !mayDescend(into: path, device: st.st_dev, rootDevice: rootStat.st_dev, mountPoint: mountPoint(of: path), excluded: excludedPaths) {
                    enumerator.skipDescendants()
                    continue
                }
                result.directoryCount += 1
                continue
            }
            if v.isSymbolicLink != true, (v.linkCount ?? 1) > 1 {
                var st = stat()
                if lstat(child.path, &st) == 0, !seenLinked.insert(FileID(device: st.st_dev, inode: st.st_ino)).inserted { continue }
            }
            result.fileCount += 1
            result.bytes += bytes(from: v)
        }
        result.deniedDirectoryCount = denied
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

    /// Whether a walk that started on `rootDevice` enters the folder at `path`. Excluded folders are never entered. A folder
    /// on another device is entered only when it is not the root of a mounted volume: a firmlink into a sibling APFS volume of
    /// the same group (`/usr/local`, `/Library`) is followed, a mount point (`/Volumes/X`, `/System/Volumes/Data`, a disk image
    /// mounted inside the tree) is not. `mountPoint` is the mount path of the volume holding `path`; it is evaluated only when
    /// the devices differ, and an unknown mount point counts as a boundary.
    static func mayDescend(into path: String, device: dev_t, rootDevice: dev_t, mountPoint: @autoclosure () -> String?, excluded: Set<String>) -> Bool {
        if excluded.contains(path) { return false }
        if device == rootDevice { return true }
        guard let mount = mountPoint() else { return false }
        return mount != path
    }

    /// Mount path (`f_mntonname`) of the volume holding `path`.
    static func mountPoint(of path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return withUnsafePointer(to: &fs.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// The errno (EPERM or EACCES) when `error` says a folder could not be read for lack of permission.
    /// EPERM is what privacy protection (TCC, Full Disk Access) returns; EACCES is plain POSIX permissions.
    static func permissionDenial(in error: Error) -> Int32? {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return Int32(ns.code) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, let code = permissionDenial(in: underlying) { return code }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return EACCES }
        return nil
    }
}
