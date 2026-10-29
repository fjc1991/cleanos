import Foundation

/// A mounted volume the user can clean.
public struct VolumeInfo: Identifiable, Hashable, Sendable, Codable {
    /// Volume UUID when the file system reports one, otherwise the mount path.
    public var id: String
    public var url: URL
    public var name: String
    public var format: String
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isLocal: Bool
    public var isRoot: Bool
    public var totalCapacity: Int64
    public var availableCapacity: Int64
    public var availableForImportantUsage: Int64

    public var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }
    /// Space macOS could reclaim on demand (snapshots, caches it manages). Only APFS reports this.
    public var purgeableCapacity: Int64 { max(0, availableForImportantUsage - availableCapacity) }
    public var isExternal: Bool { !isRoot && !isInternal }
    public var isAPFS: Bool { format.localizedCaseInsensitiveContains("apfs") }
    public var usedFraction: Double { totalCapacity > 0 ? Double(usedCapacity) / Double(totalCapacity) : 0 }
}

/// Enumerates mounted volumes. Hidden system volumes (`/System/Volumes/*`, Recovery, Preboot) and
/// disk images mounted in temporary folders are never listed.
public enum VolumeCatalog {
    static let keys: Set<URLResourceKey> = [
        .volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
        .volumeIsRootFileSystemKey, .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeUUIDStringKey,
        .volumeIsBrowsableKey,
    ]

    public static func mountedVolumes(includeNetwork: Bool = false) -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                         options: [.skipHiddenVolumes]) ?? []
        var out: [VolumeInfo] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: keys) else { continue }
            let isRoot = v.volumeIsRootFileSystem ?? (url.path == "/")
            let path = url.path
            guard isRoot || path.hasPrefix("/Volumes/") else { continue }
            guard v.volumeIsBrowsable ?? true else { continue }
            let isLocal = v.volumeIsLocal ?? true
            if !isLocal && !includeNetwork { continue }
            out.append(VolumeInfo(
                id: v.volumeUUIDString ?? path,
                url: url,
                name: v.volumeName ?? url.lastPathComponent,
                format: v.volumeLocalizedFormatDescription ?? "Unknown",
                isInternal: v.volumeIsInternal ?? isRoot,
                isRemovable: v.volumeIsRemovable ?? false,
                isEjectable: v.volumeIsEjectable ?? false,
                isLocal: isLocal,
                isRoot: isRoot,
                totalCapacity: Int64(v.volumeTotalCapacity ?? 0),
                availableCapacity: Int64(v.volumeAvailableCapacity ?? 0),
                availableForImportantUsage: v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            ))
        }
        return out.sorted { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The volume a path lives on, if it is one of the listed volumes.
    public static func volume(containing url: URL, in volumes: [VolumeInfo]) -> VolumeInfo? {
        let path = url.standardizedFileURL.path
        return volumes
            .filter { $0.isRoot ? true : path.hasPrefix($0.url.path + "/") || path == $0.url.path }
            .max { $0.url.path.count < $1.url.path.count }
    }
}
