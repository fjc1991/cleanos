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

/// What one source found, including the apps it could not check (so a failure never looks like "up to date").
public struct UpdateCheckResult: Sendable {
    public var updates: [AvailableUpdate] = []
    /// Names of the apps (or "Homebrew") whose check failed.
    public var failed: [String] = []
    /// Number of checks that completed.
    public var succeeded = 0
    /// Every network request of a source failed because the Mac is offline.
    public var isOffline = false
    var offlineFailures = 0

    public init() {}

    mutating func record(_ outcome: Result<AvailableUpdate?, CheckFailure>, name: String) {
        switch outcome {
        case .success(let update): succeeded += 1; if let update { updates.append(update) }
        case .failure(let failure): failed.append(name); if failure == .offline { offlineFailures += 1 }
        }
    }

    /// Marks the result offline when nothing succeeded and at least one request found no connection.
    mutating func finish() {
        isOffline = succeeded == 0 && offlineFailures > 0
        updates.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func merged(with other: UpdateCheckResult) -> UpdateCheckResult {
        var out = self
        out.updates += other.updates; out.failed += other.failed; out.succeeded += other.succeeded
        out.isOffline = isOffline || other.isOffline; out.offlineFailures += other.offlineFailures
        return out
    }
}

enum CheckFailure: Error, Equatable { case offline, rateLimited, other }

enum UpdateHTTP {
    /// Keeps "Sparkle" so feeds that vary their response by updater still serve the appcast.
    static let userAgent = "CleanOS/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") Sparkle/2"

    /// Only https links from a feed or lookup are kept; anything else is dropped at parse time.
    static func secureURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host()?.isEmpty == false else { return nil }
        return url
    }

    static func fetch(_ url: URL, session: URLSession) async throws(CheckFailure) -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let loaded: (Data, URLResponse)
        do { loaded = try await session.data(for: request) } catch {
            let offline: Set<URLError.Code> = [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff]
            throw (error as? URLError).map { offline.contains($0.code) } == true ? .offline : .other
        }
        let (data, response) = loaded
        guard let http = response as? HTTPURLResponse else { return data }
        if http.statusCode == 403 || http.statusCode == 429 { throw .rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw .other }
        return data
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
        public var maximumSystemVersion: String?
        public var os: String?                 // sparkle:os on the enclosure
        public var channel: String?            // sparkle:channel (beta etc.)
        public var isCritical = false
    }

    public func checkForUpdates() async -> UpdateCheckResult {
        var result = UpdateCheckResult()
        await withTaskGroup(of: (String, Result<AvailableUpdate?, CheckFailure>).self) { group in
            for app in apps where app.sparkleFeedURL != nil {
                group.addTask { (app.name, await check(app)) }
            }
            for await (name, outcome) in group { result.record(outcome, name: name) }
        }
        result.finish()
        return result
    }

    func check(_ app: UpdatableApp) async -> Result<AvailableUpdate?, CheckFailure> {
        guard let feed = app.sparkleFeedURL else { return .success(nil) }
        do throws(CheckFailure) {
            let data = try await UpdateHTTP.fetch(feed, session: session)
            guard let items = Self.parseFeed(data) else { return .failure(.other) }
            return .success(Self.newestUpdate(for: app, items: items))
        } catch { return .failure(error) }
    }

    public static func newestUpdate(for app: UpdatableApp, appcast: Data, systemVersion: String = currentOSVersion()) -> AvailableUpdate? {
        newestUpdate(for: app, items: parse(appcast), systemVersion: systemVersion)
    }

    /// Picks the newest item Sparkle itself would offer: default channel, macOS, supported by this system.
    /// Like Sparkle, the feed's `sparkle:version` is compared with the installed CFBundleVersion; short
    /// versions are only for display, or the fallback when either build is missing.
    static func newestUpdate(for app: UpdatableApp, items: [AppcastItem], systemVersion: String = currentOSVersion()) -> AvailableUpdate? {
        func build(_ item: AppcastItem) -> String { item.version ?? item.shortVersion ?? "0" }
        let candidates = items.filter { item in
            let supported = (item.minimumSystemVersion.map { VersionComparison.compare(systemVersion, to: $0) != .older } ?? true)
                && (item.maximumSystemVersion.map { VersionComparison.compare(systemVersion, to: $0) != .newer } ?? true)
            return supported && item.channel == nil && (item.os == nil || item.os == "macos") && (item.version ?? item.shortVersion) != nil
        }
        guard let newest = candidates.max(by: { VersionComparison.compare(build($0), to: build($1)) == .older }) else { return nil }
        let isNewer = if let feedBuild = newest.version, let installedBuild = app.buildVersion {
            VersionComparison.isNewer(feedBuild, than: installedBuild)
        } else {
            VersionComparison.isNewer(newest.shortVersion ?? build(newest), than: app.shortVersion ?? app.buildVersion ?? "0")
        }
        guard isNewer else { return nil }
        // Show like with like: short versions when the feed has them (plus builds if those are equal), else builds.
        var installed = app.shortVersion ?? app.buildVersion ?? "?"
        var latest = newest.shortVersion ?? build(newest)
        if newest.shortVersion == nil, let installedBuild = app.buildVersion {
            installed = installedBuild
        } else if latest == installed, let feedBuild = newest.version, let installedBuild = app.buildVersion {
            installed += " (\(installedBuild))"; latest += " (\(feedBuild))"
        }
        return AvailableUpdate(identifier: app.bundleID, displayName: app.name, installedVersion: installed, latestVersion: latest,
                               origin: .sparkle, appURL: app.appURL, downloadURL: newest.url, releaseNotesURL: newest.releaseNotesURL)
    }

    public static func currentOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Minimal RSS/appcast parser.
    public static func parse(_ data: Data) -> [AppcastItem] { parseFeed(data) ?? [] }

    /// Returns nil when the data is not XML with items (for example an error page served instead of the feed).
    static func parseFeed(_ data: Data) -> [AppcastItem]? {
        let parser = XMLParser(data: data)
        let delegate = AppcastDelegate()
        parser.delegate = delegate
        return parser.parse() || !delegate.items.isEmpty ? delegate.items : nil
    }

    final class AppcastDelegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""
        private var inDeltas = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            text = ""
            switch elementName {
            case "item": current = AppcastItem()
            case "sparkle:deltas": inDeltas = true
            case "enclosure" where !inDeltas && attributes["sparkle:deltaFrom"] == nil:
                current?.url = UpdateHTTP.secureURL(attributes["url"])
                if let v = attributes["sparkle:version"] { current?.version = v }
                if let s = attributes["sparkle:shortVersionString"] { current?.shortVersion = s }
                if let os = attributes["sparkle:os"] { current?.os = os }
            case "sparkle:criticalUpdate": current?.isCritical = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "item": if let current { items.append(current) }; current = nil
            case "sparkle:deltas": inDeltas = false
            case "title": if current != nil, current?.title == nil { current?.title = value }
            case "sparkle:version": if current?.version == nil { current?.version = value }
            case "sparkle:shortVersionString": if current?.shortVersion == nil { current?.shortVersion = value }
            case "sparkle:releaseNotesLink": current?.releaseNotesURL = UpdateHTTP.secureURL(value)
            case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value
            case "sparkle:maximumSystemVersion": current?.maximumSystemVersion = value
            case "sparkle:channel": current?.channel = value
            case "link": if current?.releaseNotesURL == nil, let url = UpdateHTTP.secureURL(value) { current?.releaseNotesURL = url }
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

    /// `brew outdated` without `--greedy` by default: casks that update themselves would otherwise show forever.
    public func checkForUpdates(includeAutoUpdating: Bool = false) async -> UpdateCheckResult {
        var result = UpdateCheckResult()
        guard let brewPath else { return result }
        var arguments = ["outdated", "--json=v2"]
        if includeAutoUpdating { arguments.append("--greedy") }
        guard let run = await Self.run(brewPath, arguments, timeout: .seconds(60)), var updates = Self.parseOutdated(run.output) else {
            result.failed = ["Homebrew"]
            return result
        }
        // Names and install locations of outdated casks, so a cask row can be matched to the app it installs.
        let casks = updates.filter { $0.origin == .homebrewCask }.map(\.identifier)
        if !casks.isEmpty, let info = await Self.run(brewPath, ["info", "--cask", "--json=v2"] + casks, timeout: .seconds(60)) {
            updates = Self.parseOutdated(run.output, casks: Self.parseCaskInfo(info.output)) ?? updates
        }
        result.updates = updates
        result.succeeded = 1
        return result
    }

    struct CaskInfo: Sendable { var name: String?; var appURL: URL? }

    /// Parses `brew outdated --json=v2`, skipping pinned formulae; nil when the output is not valid JSON.
    public static func parseOutdated(_ json: String) -> [AvailableUpdate]? { parseOutdated(json, casks: [:]) }

    static func parseOutdated(_ json: String, casks info: [String: CaskInfo]) -> [AvailableUpdate]? {
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var updates: [AvailableUpdate] = []
        for formula in object["formulae"] as? [[String: Any]] ?? [] {
            guard let name = formula["name"] as? String, formula["pinned"] as? Bool != true else { continue }
            let installed = (formula["installed_versions"] as? [String])?.first ?? "?"
            let current = formula["current_version"] as? String ?? "?"
            updates.append(AvailableUpdate(identifier: name, displayName: name, installedVersion: installed, latestVersion: current, origin: .homebrewFormula))
        }
        for cask in object["casks"] as? [[String: Any]] ?? [] {
            guard let name = cask["name"] as? String else { continue }
            let installed = (cask["installed_versions"] as? [String])?.first ?? "?"
            let current = cask["current_version"] as? String ?? "?"
            updates.append(AvailableUpdate(identifier: name, displayName: info[name]?.name ?? name, installedVersion: installed, latestVersion: current,
                                           origin: .homebrewCask, appURL: info[name]?.appURL))
        }
        return updates
    }

    /// Parses `brew info --cask --json=v2`: each cask's display name and the app bundle it installs.
    static func parseCaskInfo(_ json: String) -> [String: CaskInfo] {
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: CaskInfo] = [:]
        for cask in object["casks"] as? [[String: Any]] ?? [] {
            let app = (cask["artifacts"] as? [[String: Any]])?.first { $0["app"] != nil }
            let target = app?["target"] as? String ?? ((app?["app"] as? [Any])?.first as? String).map { "/Applications/\($0)" }
            let info = CaskInfo(name: (cask["name"] as? [String])?.first, appURL: target.map { URL(filePath: $0) })
            for key in [cask["token"], cask["full_token"]].compactMap({ $0 as? String }) { out[key] = info }
        }
        return out
    }

    /// `brew upgrade [--cask] <token>`; returns whether it exited successfully and the combined output.
    public func upgrade(_ update: AvailableUpdate) async -> (Bool, String) {
        guard let brewPath else { return (false, "Homebrew is not installed.") }
        var arguments = ["upgrade"]
        if update.origin == .homebrewCask { arguments.append("--cask") }
        arguments.append(update.identifier)
        guard let run = await Self.run(brewPath, arguments, mergeStderr: true, timeout: .seconds(600)) else { return (false, "Could not start Homebrew.") }
        if run.killed { return (false, run.output + "\nHomebrew did not finish within 10 minutes and was stopped.") }
        return (run.status == 0, run.output)
    }

    /// Runs brew with output in a temporary file (so a lingering child cannot block the read) and stops it after `timeout`.
    static func run(_ executable: String, _ arguments: [String], mergeStderr: Bool = false, timeout: Duration) async -> (status: Int32, output: String, killed: Bool)? {
        let log = FileManager.default.temporaryDirectory.appending(path: "cleanos-brew-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil), let handle = try? FileHandle(forWritingTo: log) else { return nil }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = mergeStderr ? handle : FileHandle.nullDevice
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
            try await Task.sleep(for: .seconds(5))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        defer { watchdog.cancel() }
        let status: Int32? = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { process.terminationHandler = nil; continuation.resume(returning: nil) }
        }
        guard let status else { return nil }
        let output = String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self)
        return (status, output, process.terminationReason == .uncaughtSignal)
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

    /// Four lookups at a time; on 403/429 no further requests are issued and the remaining apps count as not checked.
    public func checkForUpdates() async -> UpdateCheckResult {
        var result = UpdateCheckResult()
        await withTaskGroup(of: (String, Result<AvailableUpdate?, CheckFailure>).self) { group in
            var pending = apps.filter(\.hasMASReceipt).makeIterator()
            var rateLimited = false
            func addNext() -> Bool {
                guard !rateLimited, let app = pending.next() else { return false }
                group.addTask { (app.name, await check(app)) }
                return true
            }
            for _ in 0..<4 { guard addNext() else { break } }
            for await (name, outcome) in group {
                result.record(outcome, name: name)
                if case .failure(.rateLimited) = outcome { rateLimited = true }
                _ = addNext()
            }
            while let app = pending.next() { result.failed.append(app.name) }
        }
        result.finish()
        return result
    }

    func check(_ app: UpdatableApp) async -> Result<AvailableUpdate?, CheckFailure> {
        do throws(CheckFailure) {
            var data = try await UpdateHTTP.fetch(Self.lookupURL(bundleID: app.bundleID, country: country), session: session)
            guard let results = Self.results(in: data) else { return .failure(.other) }
            if results.isEmpty, country != "us" {   // not sold in this storefront: try the US one
                data = try await UpdateHTTP.fetch(Self.lookupURL(bundleID: app.bundleID, country: "us"), session: session)
                guard Self.results(in: data) != nil else { return .failure(.other) }
            }
            return .success(Self.update(for: app, lookup: data))
        } catch { return .failure(error) }
    }

    static func lookupURL(bundleID: String, country: String) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "bundleId", value: bundleID), URLQueryItem(name: "country", value: country),
                                 URLQueryItem(name: "entity", value: "macSoftware")]
        return components.url!
    }

    static func results(in lookup: Data) -> [[String: Any]]? {
        (try? JSONSerialization.jsonObject(with: lookup) as? [String: Any])?["results"] as? [[String: Any]]
    }

    public static func update(for app: UpdatableApp, lookup: Data) -> AvailableUpdate? {
        guard let result = results(in: lookup)?.first(where: { $0["bundleId"] as? String == app.bundleID }),
              let latest = result["version"] as? String else { return nil }
        let installed = app.shortVersion ?? "0"
        guard VersionComparison.isNewer(latest, than: installed) else { return nil }
        return AvailableUpdate(identifier: app.bundleID, displayName: app.name, installedVersion: installed, latestVersion: latest,
                               origin: .appStore, appURL: app.appURL, releaseNotesURL: UpdateHTTP.secureURL(result["trackViewUrl"] as? String))
    }
}

// MARK: - Manager

/// Runs every source and caches the result on disk for an hour.
public actor UpdateManager {
    public static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/com.cleanos/Updates.json")
    }
    public let cacheMaxAge: TimeInterval
    let cacheFile: URL
    let session: URLSession
    public init(cacheMaxAge: TimeInterval = 3600, cacheFile: URL = UpdateManager.cacheURL, session: URLSession = .shared) {
        self.cacheMaxAge = cacheMaxAge; self.cacheFile = cacheFile; self.session = session
    }

    public struct Snapshot: Codable, Sendable {
        public var checkedAt: Date
        public var updates: [AvailableUpdate]
        /// Apps (or "Homebrew") that could not be checked.
        public var failed: [String]
        public var isOffline: Bool
    }

    public func cached() -> Snapshot? {
        guard let snapshot = load(), Date().timeIntervalSince(snapshot.checkedAt) < cacheMaxAge else { return nil }
        return snapshot
    }

    public func check(apps: [UpdatableApp], includeHomebrew: Bool = true, skipList: Set<String> = []) async -> Snapshot {
        async let sparkle = SparkleSource(apps: apps, session: session).checkForUpdates()
        async let store = AppStoreSource(apps: apps, session: session).checkForUpdates()
        async let brew = includeHomebrew ? HomebrewSource().checkForUpdates() : UpdateCheckResult()
        let result = await sparkle.merged(with: store).merged(with: brew)
        var updates = Self.deduplicated(result.updates)
        updates.removeAll { skipList.contains($0.identifier) || skipList.contains($0.displayName) }
        let snapshot = Snapshot(checkedAt: .now, updates: updates, failed: result.failed, isOffline: result.isOffline)
        // A check that reached nothing is not worth an hour of "up to date".
        if !result.isOffline, result.succeeded > 0 || result.failed.isEmpty { save(snapshot) }
        return snapshot
    }

    /// Drops an update that has been installed, so the cached snapshot does not bring it back.
    public func remove(updateID: String) {
        guard var snapshot = load() else { return }
        snapshot.updates.removeAll { $0.id == updateID }
        save(snapshot)
    }

    /// One row per app: an App Store row wins over a Sparkle row for the same bundle ID, and either wins over the
    /// Homebrew cask that installs the same app (matched by path, or by name when brew did not report a path).
    static func deduplicated(_ updates: [AvailableUpdate]) -> [AvailableUpdate] {
        func key(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber } }
        let preferred = updates.filter { $0.origin == .appStore || $0.origin == .sparkle }
        let storeIDs = Set(updates.filter { $0.origin == .appStore }.map(\.identifier))
        let paths = Set(preferred.compactMap { $0.appURL?.standardizedFileURL.path })
        let names = Set(preferred.map { key($0.displayName) })
        var seen = Set<String>()
        return updates.filter { update in
            guard seen.insert(update.id).inserted else { return false }
            switch update.origin {
            case .appStore, .homebrewFormula: return true
            case .sparkle: return !storeIDs.contains(update.identifier)
            case .homebrewCask:
                if let path = update.appURL?.standardizedFileURL.path, paths.contains(path) { return false }
                return !names.contains(key(update.displayName)) && !names.contains(key(update.identifier))
            }
        }
    }

    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    func save(_ snapshot: Snapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(snapshot).write(to: cacheFile, options: .atomic)
    }
}
