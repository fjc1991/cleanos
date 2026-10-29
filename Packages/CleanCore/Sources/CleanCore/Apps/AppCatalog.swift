import Foundation
import CoreServices

/// An application found in one of the scan locations.
public struct InstalledApp: Identifiable, Hashable, Sendable, Codable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String?
    public let build: String?
    public let isSystem: Bool
    public let modificationDate: Date?
    public let creationDate: Date?
    public let lastOpenedDate: Date?
    public var identity: AppIdentity
    public var size: Int64?

    public var developerName: String? { identity.developerName }
    public var teamID: String? { identity.teamID }

    public init(url: URL, name: String, bundleID: String, version: String?, build: String?, isSystem: Bool,
                modificationDate: Date?, creationDate: Date?, lastOpenedDate: Date?, identity: AppIdentity, size: Int64? = nil) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.isSystem = isSystem
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.lastOpenedDate = lastOpenedDate
        self.identity = identity
        self.size = size
    }
}

/// Enumerates installed apps and keeps a snapshot on disk so the Trash watcher and the Remains scan can diff against it.
public actor AppCatalog {
    public static var snapshotURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.cleanos/InstalledApps.json")
    }

    public let rules: Rules
    private var identityCache: [String: AppIdentity] = [:]

    public init(rules: Rules = .bundled) {
        self.rules = rules
    }

    /// Places outside the user's Locations where vendors park updaters and helpers that own leftovers of their own.
    public static let wellKnownExtraLocations: [URL] = [
        "/Library/Application Support/Microsoft/MAU2.0", "/Library/Google/GoogleSoftwareUpdate", "/Library/Application Support/Adobe",
        "/Library/Application Support/Logitech.localized", "/Library/PreferencePanes", "/Applications/Utilities",
        "/Library/Application Support/Paragon Software", "/opt/homebrew/Caskroom",
    ].map { URL(filePath: $0) }

    /// Finds `.app` bundles up to three levels below each location (vendor folders like `/Applications/MacCleaner 4 Pro/`).
    /// `extraBundleURLs` lets the caller add bundles it knows about, such as the apps currently running.
    public func scan(locations: [URL], extraBundleURLs: [URL] = [], includeSystem: Bool = false, skipList: [String] = [],
                     progress: (@Sendable (Int) -> Void)? = nil) async -> [InstalledApp] {
        var bundleURLs = Self.findAppBundles(in: locations + Self.wellKnownExtraLocations, skipList: skipList)
        let known = Set(bundleURLs.map { $0.standardizedFileURL.path })
        for url in extraBundleURLs where url.pathExtension == "app" && !known.contains(url.standardizedFileURL.path) && !url.path.hasPrefix("/System/") {
            bundleURLs.append(url)
        }

        let shared = rules.shared
        let cache = identityCache
        var results: [InstalledApp] = []
        await withTaskGroup(of: InstalledApp?.self) { group in
            var iterator = bundleURLs.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard let url = iterator.next() else { return false }
                let cached = cache[Self.cacheKey(url)]
                group.addTask { Self.makeApp(url: url, shared: shared, cachedIdentity: cached) }
                return true
            }
            while running < 4, addNext() { running += 1 }
            for await app in group {
                if let app {
                    results.append(app)
                    progress?(results.count)
                }
                if !addNext() { running -= 1 }
            }
        }
        for app in results { identityCache[Self.cacheKey(app.url)] = app.identity }
        return results
            .filter { includeSystem || !$0.isSystem }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Synchronous enumeration (NSEnumerator cannot be iterated from an async context).
    public static func findAppBundles(in locations: [URL], skipList: [String]) -> [URL] {
        var bundleURLs: [URL] = []
        var seen: Set<String> = []
        let fm = FileManager.default
        for location in locations {
            guard let enumerator = fm.enumerator(at: location, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                if enumerator.level > 4 { enumerator.skipDescendants(); continue }
                guard url.pathExtension == "app" else { continue }
                enumerator.skipDescendants()
                let path = url.standardizedFileURL.path
                if seen.contains(path) { continue }
                if skipList.contains(where: { path.hasPrefix($0) }) { continue }
                seen.insert(path)
                bundleURLs.append(url)
            }
        }
        return bundleURLs
    }

    static func cacheKey(_ url: URL) -> String {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(mod)"
    }

    public static func makeApp(url: URL, shared: SharedIdentifiers, cachedIdentity: AppIdentity?) -> InstalledApp? {
        guard let identity = cachedIdentity ?? AppInspector.inspect(bundleURL: url, shared: shared) else { return nil }
        let info = AppInspector.infoPlist(at: url) ?? [:]
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .contentAccessDateKey])
        let path = url.path
        let isSystem = path.hasPrefix("/System/") || identity.bundleID.hasPrefix("com.apple.")
        return InstalledApp(
            url: url,
            name: identity.name,
            bundleID: identity.bundleID,
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            isSystem: isSystem,
            modificationDate: values?.contentModificationDate,
            creationDate: values?.creationDate,
            lastOpenedDate: lastUsedDate(for: url) ?? values?.contentAccessDate,
            identity: identity
        )
    }

    /// Spotlight's last-used date when the index has it; nil otherwise.
    static func lastUsedDate(for url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: - Snapshot

    public func saveSnapshot(_ apps: [InstalledApp]) throws {
        let url = Self.snapshotURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(apps).write(to: url, options: .atomic)
    }

    public func loadSnapshot() -> [InstalledApp] {
        guard let data = try? Data(contentsOf: Self.snapshotURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([InstalledApp].self, from: data)) ?? []
    }

    /// Apps grouped by team ID when at least two share one ("Anthropic AI Group · 2 Applications").
    public static func developerGroups(_ apps: [InstalledApp]) -> [String: [InstalledApp]] {
        var groups: [String: [InstalledApp]] = [:]
        for app in apps {
            guard let team = app.teamID, !team.isEmpty, !app.isSystem else { continue }
            groups[team, default: []].append(app)
        }
        return groups.filter { $0.value.count >= 2 }
    }
}
