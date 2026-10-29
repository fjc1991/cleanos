import Foundation

/// What the update checker needs to know about an installed app (kept independent of CleanCore).
public struct UpdatableApp: Sendable, Hashable {
    public let bundleID: String
    public let name: String
    public let appURL: URL
    public let shortVersion: String?
    public let buildVersion: String?
    public let sparkleFeedURL: URL?
    public let hasMASReceipt: Bool

    public init(bundleID: String, name: String, appURL: URL, shortVersion: String?, buildVersion: String?, sparkleFeedURL: URL?, hasMASReceipt: Bool) {
        self.bundleID = bundleID; self.name = name; self.appURL = appURL; self.shortVersion = shortVersion; self.buildVersion = buildVersion
        self.sparkleFeedURL = sparkleFeedURL; self.hasMASReceipt = hasMASReceipt
    }
}

// MARK: - Sparkle

/// Reads Sparkle appcasts and compares them with the installed version.
public struct SparkleSource: Sendable {
    public let apps: [UpdatableApp]
    public let session: URLSession
    public init(apps: [UpdatableApp], session: URLSession = .shared) { self.apps = apps; self.session = session }

    public struct AppcastItem: Sendable, Hashable {
        public var title: String?
        public var version: String?            // sparkle:version (build)
        public var shortVersion: String?       // sparkle:shortVersionString
        public var url: URL?
        public var releaseNotesURL: URL?
        public var minimumSystemVersion: String?
        public var isCritical = false
    }

    public func checkForUpdates() async -> [AvailableUpdate] {
        var updates: [AvailableUpdate] = []
        await withTaskGroup(of: AvailableUpdate?.self) { group in
            for app in apps where app.sparkleFeedURL != nil {
                group.addTask { await check(app) }
            }
            for await update in group { if let update { updates.append(update) } }
        }
        return updates.sorted { $0.displayName < $1.displayName }
    }

    func check(_ app: UpdatableApp) async -> AvailableUpdate? {
        guard let feed = app.sparkleFeedURL else { return nil }
        var request = URLRequest(url: feed)
        request.setValue("CleanOS/1.0 Sparkle/2.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, _) = try? await session.data(for: request) else { return nil }
        return Self.newestUpdate(for: app, appcast: data)
    }

    public static func newestUpdate(for app: UpdatableApp, appcast: Data, systemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString) -> AvailableUpdate? {
        let items = parse(appcast).filter { item in
            guard let minimum = item.minimumSystemVersion else { return true }
            return VersionComparison.compare(currentOSVersion(), to: minimum) != .older
        }
        guard let newest = items.max(by: { lhs, rhs in
            VersionComparison.compare(lhs.shortVersion ?? lhs.version ?? "0", to: rhs.shortVersion ?? rhs.version ?? "0") == .older
        }) else { return nil }
        let latest = newest.shortVersion ?? newest.version ?? ""
        let installed = app.shortVersion ?? app.buildVersion ?? "0"
        var newer = VersionComparison.isNewer(latest, than: installed)
        if !newer, let build = newest.version, let installedBuild = app.buildVersion, latest == installed {
            newer = VersionComparison.isNewer(build, than: installedBuild)
        }
        guard newer else { return nil }
        return AvailableUpdate(identifier: app.bundleID, displayName: app.name, installedVersion: installed, latestVersion: latest,
                               origin: .sparkle, appURL: app.appURL, downloadURL: newest.url, releaseNotesURL: newest.releaseNotesURL)
    }

    static func currentOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Minimal RSS/appcast parser.
    public static func parse(_ data: Data) -> [AppcastItem] {
        let parser = XMLParser(data: data)
        let delegate = AppcastDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    final class AppcastDelegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""
        private var element = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            element = elementName
            text = ""
            switch elementName {
            case "item": current = AppcastItem()
            case "enclosure":
                current?.url = attributes["url"].flatMap(URL.init(string:))
                if let v = attributes["sparkle:version"] { current?.version = v }
                if let s = attributes["sparkle:shortVersionString"] { current?.shortVersion = s }
            case "sparkle:criticalUpdate": current?.isCritical = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "item": if let current { items.append(current) }; current = nil
            case "title": if current != nil, current?.title == nil { current?.title = value }
            case "sparkle:version": if current?.version == nil { current?.version = value }
            case "sparkle:shortVersionString": if current?.shortVersion == nil { current?.shortVersion = value }
            case "sparkle:releaseNotesLink": current?.releaseNotesURL = URL(string: value)
            case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value
            case "link": if current?.releaseNotesURL == nil, let url = URL(string: value) { current?.releaseNotesURL = url }
            default: break
            }
        }
    }
}

// MARK: - Homebrew

public struct HomebrewSource: Sendable {
    public let brewPath: String?
    public init(brewPath: String? = HomebrewSource.locateBrew()) { self.brewPath = brewPath }

    public static func locateBrew() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var isAvailable: Bool { brewPath != nil }

    public func checkForUpdates(includeAutoUpdating: Bool = true) async -> [AvailableUpdate] {
        guard let brewPath else { return [] }
        var arguments = ["outdated", "--json=v2"]
        if includeAutoUpdating { arguments.append("--greedy") }
        guard let output = await Self.run(brewPath, arguments) else { return [] }
        return Self.parseOutdated(output)
    }

    /// Parses `brew outdated --json=v2`.
    public static func parseOutdated(_ json: String) -> [AvailableUpdate] {
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var updates: [AvailableUpdate] = []
        for formula in object["formulae"] as? [[String: Any]] ?? [] {
            guard let name = formula["name"] as? String else { continue }
            let installed = (formula["installed_versions"] as? [String])?.first ?? "?"
            let current = formula["current_version"] as? String ?? "?"
            updates.append(AvailableUpdate(identifier: name, displayName: name, installedVersion: installed, latestVersion: current, origin: .homebrewFormula))
        }
        for cask in object["casks"] as? [[String: Any]] ?? [] {
            guard let name = cask["name"] as? String else { continue }
            let installed = (cask["installed_versions"] as? [String])?.first ?? "?"
            let current = cask["current_version"] as? String ?? "?"
            updates.append(AvailableUpdate(identifier: name, displayName: name, installedVersion: installed, latestVersion: current, origin: .homebrewCask))
        }
        return updates
    }

    /// `brew upgrade [--cask] <token>`; returns the combined output and whether it succeeded.
    public func upgrade(_ update: AvailableUpdate) async -> (Bool, String) {
        guard let brewPath else { return (false, "Homebrew is not installed.") }
        var arguments = ["upgrade"]
        if update.origin == .homebrewCask { arguments.append("--cask") }
        arguments.append(update.identifier)
        let output = await Self.run(brewPath, arguments, mergeStderr: true) ?? ""
        return (!output.contains("Error:"), output)
    }

    static func run(_ executable: String, _ arguments: [String], mergeStderr: Bool = false) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            environment["HOMEBREW_NO_ENV_HINTS"] = "1"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = mergeStderr ? pipe : FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }.value
    }
}

// MARK: - Mac App Store

public struct AppStoreSource: Sendable {
    public let apps: [UpdatableApp]
    public let session: URLSession
    public let country: String
    public init(apps: [UpdatableApp], session: URLSession = .shared, country: String = Locale.current.region?.identifier.lowercased() ?? "us") {
        self.apps = apps; self.session = session; self.country = country
    }

    public func checkForUpdates() async -> [AvailableUpdate] {
        var updates: [AvailableUpdate] = []
        await withTaskGroup(of: AvailableUpdate?.self) { group in
            var pending = apps.filter(\.hasMASReceipt).makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard let app = pending.next() else { return false }
                group.addTask { await check(app) }
                return true
            }
            while running < 4, addNext() { running += 1 }
            for await update in group {
                if let update { updates.append(update) }
                if !addNext() { running -= 1 }
            }
        }
        return updates.sorted { $0.displayName < $1.displayName }
    }

    func check(_ app: UpdatableApp) async -> AvailableUpdate? {
        guard let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(app.bundleID)&country=\(country)"),
              let (data, _) = try? await session.data(from: url) else { return nil }
        return Self.update(for: app, lookup: data)
    }

    public static func update(for app: UpdatableApp, lookup: Data) -> AvailableUpdate? {
        guard let object = try? JSONSerialization.jsonObject(with: lookup) as? [String: Any],
              let result = (object["results"] as? [[String: Any]])?.first, let latest = result["version"] as? String else { return nil }
        let installed = app.shortVersion ?? "0"
        guard VersionComparison.isNewer(latest, than: installed) else { return nil }
        let notes = (result["trackViewUrl"] as? String).flatMap(URL.init(string:))
        return AvailableUpdate(identifier: app.bundleID, displayName: app.name, installedVersion: installed, latestVersion: latest,
                               origin: .appStore, appURL: app.appURL, downloadURL: URL(string: "macappstore://showUpdatesPage"), releaseNotesURL: notes)
    }
}

// MARK: - Manager

/// Runs every source and caches the result on disk for an hour.
public actor UpdateManager {
    public static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/com.cleanos/Updates.json")
    }
    public let cacheMaxAge: TimeInterval
    public init(cacheMaxAge: TimeInterval = 3600) { self.cacheMaxAge = cacheMaxAge }

    public struct Snapshot: Codable, Sendable {
        public var checkedAt: Date
        public var updates: [AvailableUpdate]
    }

    public func cached() -> Snapshot? {
        guard let data = try? Data(contentsOf: Self.cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data), Date().timeIntervalSince(snapshot.checkedAt) < cacheMaxAge else { return nil }
        return snapshot
    }

    public func check(apps: [UpdatableApp], includeHomebrew: Bool = true, skipList: Set<String> = []) async -> Snapshot {
        async let sparkle = SparkleSource(apps: apps).checkForUpdates()
        async let store = AppStoreSource(apps: apps).checkForUpdates()
        async let brew = includeHomebrew ? HomebrewSource().checkForUpdates() : []
        var all = await sparkle + store + brew
        all.removeAll { skipList.contains($0.identifier) || skipList.contains($0.displayName) }
        let snapshot = Snapshot(checkedAt: .now, updates: all)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(snapshot).write(to: Self.cacheURL, options: .atomic)
        return snapshot
    }
}
