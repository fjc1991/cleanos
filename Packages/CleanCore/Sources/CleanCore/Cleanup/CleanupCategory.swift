import Foundation

/// Static description of a Clean Up row.
public struct CleanupCategoryInfo: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let description: String
    public let systemImage: String
    /// Default tier of the items; some scanners override per item.
    public let tier: RiskTier
    /// Rows that produce one group per volume.
    public let isPerVolume: Bool

    public init(id: String, title: String, description: String, systemImage: String, tier: RiskTier, isPerVolume: Bool = false) {
        self.id = id; self.title = title; self.description = description; self.systemImage = systemImage; self.tier = tier; self.isPerVolume = isPerVolume
    }
}

/// What a scanner knows about the machine.
public struct CleanupContext: Sendable {
    public var home: String
    public var volumes: [VolumeInfo]
    public var enabledVolumeIDs: Set<String>
    public var installedApps: [InstalledApp]
    public var runningBundleIDs: Set<String>
    public var rules: Rules
    public var preferredLanguages: [String]
    /// False when the user scoped the scan to one external disk.
    public var includeRootVolume: Bool

    public init(home: String = NSHomeDirectory(), volumes: [VolumeInfo] = VolumeCatalog.mountedVolumes(), enabledVolumeIDs: Set<String> = [],
                installedApps: [InstalledApp] = [], runningBundleIDs: Set<String> = [], rules: Rules = .bundled,
                preferredLanguages: [String] = Locale.preferredLanguages, includeRootVolume: Bool = true) {
        self.home = home; self.volumes = volumes; self.enabledVolumeIDs = enabledVolumeIDs; self.installedApps = installedApps
        self.runningBundleIDs = runningBundleIDs; self.rules = rules; self.preferredLanguages = preferredLanguages
        self.includeRootVolume = includeRootVolume
    }

    /// The boot volume (unless scoped out) plus every external volume in scope. Read-only volumes are never in scope.
    public var scopedVolumes: [VolumeInfo] {
        volumes.filter { !$0.isReadOnly && (($0.isRoot && includeRootVolume) || (!$0.isRoot && enabledVolumeIDs.contains($0.id))) }
    }
    public var homeURL: URL { URL(filePath: home) }
}

public struct CleanupResult: Sendable {
    public let category: CleanupCategoryInfo
    /// Top-level items: group nodes (per app, per volume) or leaves.
    public let items: [ScanItem]
    public let duration: TimeInterval
    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    public var leafCount: Int { items.flatMap(\.leaves).count }
    public init(category: CleanupCategoryInfo, items: [ScanItem], duration: TimeInterval) {
        self.category = category; self.items = items; self.duration = duration
    }
}

public protocol CleanupScanner: Sendable {
    var info: CleanupCategoryInfo { get }
    func scan(_ context: CleanupContext) async -> [ScanItem]
}

/// Folders a scan was not allowed to list, collected while one category is scanned.
final class UnreadableFolders: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(path: String, errno: Int32)] = []

    func record(_ url: URL, errno code: Int32) {
        let path = url.standardizedFileURL.path
        lock.withLock { if !entries.contains(where: { $0.path == path }) { entries.append((path, code)) } }
    }

    var all: [(path: String, errno: Int32)] { lock.withLock { entries } }
}

/// Helpers shared by the scanners.
enum CleanupSupport {
    static let fileKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .totalFileAllocatedSizeKey]

    /// Set by `CleanupEngine` for the duration of one category scan; listings refused with EPERM/EACCES land here.
    @TaskLocal static var unreadable: UnreadableFolders?

    /// Contents of a folder; empty when it does not exist or cannot be read. A refused listing is recorded so the
    /// category can say so instead of looking clean.
    static func children(of url: URL, skippingHidden: Bool = true) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(fileKeys),
                                                               options: skippingHidden ? [.skipsHiddenFiles] : [])
        } catch {
            recordIfDenied(url, error: error)
            return []
        }
    }

    static func recordIfDenied(_ url: URL, error: Error) {
        guard let code = DirectorySizer.permissionDenial(in: error) else { return }
        unreadable?.record(url, errno: code)
    }

    /// A display-only row naming the folders a category could not read, so an unreadable folder does not look clean.
    static func unreadableNote(_ entries: [(path: String, errno: Int32)], category: CleanupCategoryInfo, home: String) -> ScanItem? {
        guard !entries.isEmpty else { return nil }
        func display(_ path: String) -> String { path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }
        func list(_ paths: [String]) -> String { paths.count <= 2 ? paths.joined(separator: " and ") : "\(paths[0]) and \(paths.count - 1) more folders" }
        // EPERM comes from privacy protection (fixed by Full Disk Access), EACCES from plain file permissions (it is not).
        let privacy = entries.filter { $0.errno == EPERM }.map { display($0.path) }
        let posix = entries.filter { $0.errno != EPERM }.map { display($0.path) }
        var parts: [String] = []
        if !privacy.isEmpty { parts.append("Full Disk Access is required to read \(list(privacy))") }
        if !posix.isEmpty { parts.append((privacy.isEmpty ? "Y" : "y") + "our account is not allowed to read \(list(posix))") }
        let count = entries.count
        return ScanItem(id: "\(category.id):unreadable", title: count == 1 ? "1 folder could not be read" : "\(count) folders could not be read",
                        subtitle: parts.joined(separator: "; "), kind: .registration, group: category.title, size: 0, tier: .protected,
                        matchedBy: ["folder listing refused"], payload: ["type": "note", "paths": entries.map(\.path).joined(separator: "\n")])
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Builds leaf items for the URLs, measured concurrently.
    static func items(for urls: [URL], group: String, tier: RiskTier, matchedBy: [String], needsRoot: Bool = false,
                      payload: [String: String] = [:], home: String) async -> [ScanItem] {
        let sizes = await DirectorySizer.sizes(of: urls, maxConcurrency: 6)
        return urls.map { url in
            let size = sizes[url]
            let protection = FileProtection.classify(url)
            return ScanItem(url: url, title: url.lastPathComponent, subtitle: protection.explanation ?? displayPath(url, home: home),
                            kind: (size?.directoryCount ?? 0) > 0 || isDirectory(url) ? .directory : .file, group: group,
                            size: size?.bytes ?? 0, tier: protection == .none ? tier : .protected, matchedBy: matchedBy + (protection == .none ? [] : ["system protection: \(protection)"]),
                            needsRoot: needsRoot || !FileRemover.isUserRemovable(url), modificationDate: modificationDate(url), payload: payload)
        }
        .sorted { $0.size > $1.size }
    }

    static func displayPath(_ url: URL, home: String) -> String {
        let path = url.deletingLastPathComponent().path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func group(id: String, title: String, subtitle: String? = nil, children: [ScanItem], iconPath: String? = nil) -> ScanItem {
        var payload: [String: String] = [:]
        if let iconPath { payload["iconPath"] = iconPath }
        return ScanItem(id: id, title: title, subtitle: subtitle, kind: .group, group: title, children: children, payload: payload).rollingUpSizes()
    }

    /// Finds the installed app that owns a cache/log folder name, for grouping and icons.
    static func owner(of name: String, apps: [InstalledApp], shared: SharedIdentifiers) -> InstalledApp? {
        let reduced = NameMatcher.reduce(name, style: .folder)
        for app in apps {
            let reasons = NameMatcher.match(reduced: reduced, identity: app.identity,
                                            allowed: ["bundleID", "subBundleID", "extensionID", "name", "executable"], shared: shared)
            if !reasons.isEmpty { return app }
        }
        return nil
    }
}
