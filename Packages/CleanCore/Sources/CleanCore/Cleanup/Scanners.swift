import Foundation

// MARK: - Caches

public struct CachesScanner: CleanupScanner {
    public let info = CleanupCategoryInfo(id: "caches", title: "Caches",
        description: "Temporary hidden files created by applications. Delete cache files if they take up significant disk space.",
        systemImage: "externaldrive", tier: .safe)
    public init() {}

    struct Browser { let name: String; let bundleID: String; let roots: [String] }
    static let browsers: [Browser] = [
        Browser(name: "Safari", bundleID: "com.apple.Safari", roots: ["Library/Containers/com.apple.Safari/Data/Library/Caches", "Library/Caches/com.apple.Safari"]),
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", roots: ["Library/Caches/Google/Chrome", "Library/Application Support/Google/Chrome/*/Cache", "Library/Application Support/Google/Chrome/*/Code Cache", "Library/Application Support/Google/Chrome/*/GPUCache", "Library/Application Support/Google/Chrome/*/Service Worker/CacheStorage"]),
        Browser(name: "Brave Browser", bundleID: "com.brave.Browser", roots: ["Library/Caches/BraveSoftware/Brave-Browser", "Library/Application Support/BraveSoftware/Brave-Browser/*/Cache", "Library/Application Support/BraveSoftware/Brave-Browser/*/Code Cache", "Library/Application Support/BraveSoftware/Brave-Browser/*/GPUCache", "Library/Application Support/BraveSoftware/Brave-Browser/*/Service Worker/CacheStorage"]),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", roots: ["Library/Caches/Microsoft Edge", "Library/Application Support/Microsoft Edge/*/Cache", "Library/Application Support/Microsoft Edge/*/Code Cache", "Library/Application Support/Microsoft Edge/*/GPUCache"]),
        Browser(name: "Firefox", bundleID: "org.mozilla.firefox", roots: ["Library/Caches/Firefox/Profiles/*/cache2", "Library/Caches/Firefox/Profiles/*/startupCache"]),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", roots: ["Library/Caches/company.thebrowser.Browser", "Library/Application Support/Arc/User Data/*/Cache", "Library/Application Support/Arc/User Data/*/Code Cache"]),
    ]

    /// Apple cache folders that are never offered: data vaults, daemons that break when their cache vanishes, shared stores.
    static let systemCacheSkipList = ["cloudkit", "com.apple.helpd", "com.apple.nsurlsessiond", "com.apple.iconservices", "com.apple.quicklook",
                                      "com.apple.spotlight", "com.apple.bird", "com.apple.cloudd", "com.apple.akd", "com.apple.parsecd",
                                      "com.apple.ap.", "com.apple.commerce", "com.apple.passd", "com.apple.touristd", "com.apple.sharingd",
                                      "com.apple.proactive", "com.apple.siri", "com.apple.containermanagerd", "com.apple.homed", "com.apple.icloud",
                                      "com.apple.metadata", "com.apple.tccd", "com.apple.lskdd", "com.apple.coreservices", "com.apple.appstoreagent",
                                      "com.apple.keyboardservicesd", "com.apple.duetexpertd", "com.apple.intelligenceflow", "com.apple.mediaanalysis",
                                      "com.apple.photoanalysisd", "com.apple.wifi", "com.apple.imfoundation", "com.apple.security", "com.apple.trustd"]
    /// Cache folders another Clean Up category lists item by item (Xcode junk lists the contents of com.apple.dt.Xcode).
    static let listedElsewhere: Set<String> = ["com.apple.dt.xcode"]
    /// Apple apps whose caches behave like any app cache and are safe to clear.
    static let safeAppleCaches = ["com.apple.safari", "com.apple.music", "com.apple.tv", "com.apple.podcasts", "com.apple.news",
                                  "com.apple.stocks", "com.apple.weather", "com.apple.appstore", "com.apple.ibooksx", "com.apple.maps", "com.apple.gamecenter",
                                  "com.apple.preview", "com.apple.textedit", "com.apple.finder", "com.apple.photos", "com.apple.imovie", "com.apple.garageband"]

    public func scan(_ context: CleanupContext) async -> [ScanItem] {
        let home = context.home
        var groups: [ScanItem] = []
        var claimed: Set<String> = []

        // Browser caches first so they do not fall into the generic buckets.
        for browser in Self.browsers {
            let urls = browser.roots.flatMap { PathExpander.glob(home + "/" + $0) }.map { URL(filePath: $0) }
            guard !urls.isEmpty else { continue }
            urls.forEach { claimed.insert($0.standardizedFileURL.path) }
            let running = context.runningBundleIDs.contains(browser.bundleID)
            let items = await CleanupSupport.items(for: urls, group: "\(browser.name) cache files", tier: running ? .caution : .safe,
                                                   matchedBy: ["browser cache"], home: home)
            let app = context.installedApps.first { $0.bundleID == browser.bundleID }
            groups.append(CleanupSupport.group(id: "caches:browser:\(browser.bundleID)", title: "\(browser.name) cache files",
                                               subtitle: running ? "Running; caches are in use" : nil, children: items, iconPath: app?.url.path))
        }

        // Per-app caches in ~/Library/Caches, the per-user cache dir and /Library/Caches.
        var perApp: [String: (app: InstalledApp?, urls: [URL])] = [:]
        var other: [URL] = []
        var system: [URL] = []
        let roots = ["~/Library/Caches", "$DARWIN_USER_CACHE_DIR", "/Library/Caches"].map { PathExpander.expand($0, home: home) }
        for root in roots {
            for child in CleanupSupport.children(of: URL(filePath: root), skippingHidden: false) {
                let path = child.standardizedFileURL.path
                let name = child.lastPathComponent
                let lower = name.lowercased()
                if Self.isClaimed(path, by: claimed) || name == ".DS_Store" || Self.listedElsewhere.contains(lower)
                    || Self.systemCacheSkipList.contains(where: { lower.hasPrefix($0) }) { continue }
                if FileProtection.classify(child) != .none { continue }   // data vaults and locked folders are not caches we can touch
                if let app = CleanupSupport.owner(of: name, apps: context.installedApps, shared: context.rules.shared) {
                    perApp[app.id, default: (app, [])].urls.append(child)
                } else if lower.hasPrefix("com.apple.") && !Self.safeAppleCaches.contains(where: { lower.hasPrefix($0) }) {
                    system.append(child)
                } else {
                    other.append(child)
                }
            }
        }
        for (_, entry) in perApp.sorted(by: { ($0.value.app?.name ?? "") < ($1.value.app?.name ?? "") }) {
            guard let app = entry.app else { continue }
            let running = context.runningBundleIDs.contains(app.bundleID)
            let items = await CleanupSupport.items(for: entry.urls, group: "\(app.name) cache files", tier: running ? .caution : .safe, matchedBy: ["cache folder owned by \(app.name)"], home: home)
            groups.append(CleanupSupport.group(id: "caches:app:\(app.bundleID)", title: "\(app.name) cache files",
                                               subtitle: running ? "Running; caches are in use" : nil, children: items, iconPath: app.url.path))
        }
        let otherItems = await CleanupSupport.items(for: other, group: "Other caches", tier: .safe, matchedBy: ["cache folder"], home: home)
        if !otherItems.isEmpty {
            groups.append(CleanupSupport.group(id: "caches:other", title: "Applications' caches", subtitle: "Caches of helpers, frameworks and third-party services", children: otherItems))
        }
        let systemItems = await CleanupSupport.items(for: system, group: "macOS system caches", tier: .caution, matchedBy: ["Apple system cache"], home: home)
        if !systemItems.isEmpty {
            groups.append(CleanupSupport.group(id: "caches:system", title: "macOS system caches", subtitle: "Recreated by macOS as soon as they are needed; clearing them rarely frees space for long. Not selected by default.", children: systemItems))
        }

        // Logs.
        var logs: [URL] = []
        for root in ["~/Library/Logs", "/Library/Logs"].map({ PathExpander.expand($0, home: home) }) {
            for child in CleanupSupport.children(of: URL(filePath: root)) where child.lastPathComponent != "DiagnosticReports" && child.lastPathComponent != "CrashReporter" {
                logs.append(child)
            }
        }
        for root in ["~/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"].map({ PathExpander.expand($0, home: home) }) {
            logs.append(contentsOf: CleanupSupport.children(of: URL(filePath: root)).filter { $0.lastPathComponent != "Retired" })
        }
        let logItems = await CleanupSupport.items(for: logs, group: "Applications' logs", tier: .safe, matchedBy: ["log file"], home: home)
        if !logItems.isEmpty { groups.append(CleanupSupport.group(id: "caches:logs", title: "Applications' logs", children: logItems)) }

        // Xcode caches live under Xcode junk; Spotify and others are already grouped per app.
        return groups.sorted { $0.size > $1.size }
    }

    /// A folder is already listed when it is a claimed folder, contains one (listing it would list the claimed folder
    /// twice) or lies inside one.
    static func isClaimed(_ path: String, by claimed: Set<String>) -> Bool {
        claimed.contains { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }
    }
}

// MARK: - Downloads

public struct DownloadsScanner: CleanupScanner {
    public let info = CleanupCategoryInfo(id: "downloads", title: "Downloads",
        description: "Files in your Downloads folder. Review them before removing; they are your own files.", systemImage: "arrow.down.circle", tier: .caution)
    public init() {}
    public func scan(_ context: CleanupContext) async -> [ScanItem] {
        let urls = CleanupSupport.children(of: context.homeURL.appending(path: "Downloads"))
        return await CleanupSupport.items(for: urls, group: "Downloads", tier: .caution, matchedBy: ["in Downloads"], home: context.home)
    }
}

// MARK: - Installation files

public struct InstallationFilesScanner: CleanupScanner {
    public let info = CleanupCategoryInfo(id: "installers", title: "Installation files",
        description: "Disk images and installer packages. Once you have installed apps you can remove their installation files. Disk images can also hold your own data, so review them; they are not selected by default.",
        systemImage: "shippingbox", tier: .caution)
    public init() {}
    static let extensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso", "sparseimage"]
    /// Images that are as often a backup, a VM disk or an encrypted store as an installer: only offered from ~/Downloads.
    /// (Sparse bundles are never offered: they are folders that only hold user data.)
    static let downloadsOnlyExtensions: Set<String> = ["iso", "sparseimage"]

    public func scan(_ context: CleanupContext) async -> [ScanItem] {
        var found = Self.findInstallers(in: context.homeURL)
        let external = Self.extensions.subtracting(Self.downloadsOnlyExtensions)
        for volume in context.scopedVolumes where !volume.isRoot {
            for child in CleanupSupport.children(of: volume.url) where external.contains(child.pathExtension.lowercased()) { found.append(child) }
        }
        return await CleanupSupport.items(for: found, group: "Installation files", tier: .caution, matchedBy: ["installer image or package"], home: context.home)
    }

    /// Synchronous walk (NSEnumerator cannot be iterated from an async context).
    static func findInstallers(in home: URL) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        let unreadable = CleanupSupport.unreadable
        for folder in ["Downloads", "Desktop", "Documents"] {
            let root = home.appending(path: folder)
            let allowed = folder == "Downloads" ? extensions : extensions.subtracting(downloadsOnlyExtensions)
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                if let code = DirectorySizer.permissionDenial(in: error) { unreadable?.record(url, errno: code) }
                return true
            }) else { continue }
            for case let url as URL in enumerator {
                if enumerator.level > 3 { enumerator.skipDescendants(); continue }
                if allowed.contains(url.pathExtension.lowercased()) { found.append(url) }
            }
        }
        return found
    }
}

// MARK: - Screenshots

public struct ScreenshotsScanner: CleanupScanner {
    public let info = CleanupCategoryInfo(id: "screenshots", title: "Screenshot files",
        description: "Screenshots and screen recordings saved by macOS. They can be the only copy of something you kept on purpose, so they are not selected by default.",
        systemImage: "camera.viewfinder", tier: .caution)
    public init() {}

    public func scan(_ context: CleanupContext) async -> [ScanItem] {
        let configured = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        var folders = [URL(filePath: PathExpander.expand(configured ?? "~/Desktop", home: context.home))]
        for extra in ["~/Desktop", "~/Pictures/Screenshots", "~/Downloads", "~/Documents/Screenshots"] {
            let url = URL(filePath: PathExpander.expand(extra, home: context.home))
            if !folders.contains(url) { folders.append(url) }
        }
        let pattern = try! NSRegularExpression(pattern: #"^(Screenshot|Screen Shot|Screen Recording|CleanShot|Bildschirmfoto|Capture d.écran|Captura de pantalla)\b"#, options: .caseInsensitive)
        var urls: [URL] = []
        var seen: Set<String> = []
        for folder in folders {
            var candidates = CleanupSupport.children(of: folder)
            for child in candidates where CleanupSupport.isDirectory(child) && child.pathExtension.isEmpty {
                candidates.append(contentsOf: CleanupSupport.children(of: child))   // one level of subfolders
            }
            for url in candidates where !seen.contains(url.path) && !CleanupSupport.isDirectory(url) {
                let name = url.lastPathComponent
                let isScreenshot = pattern.firstMatch(in: name, range: NSRange(location: 0, length: name.utf16.count)) != nil || Self.hasScreenCaptureAttribute(url)
                if isScreenshot { urls.append(url); seen.insert(url.path) }
            }
        }
        return await CleanupSupport.items(for: urls, group: "Screenshot files", tier: .caution, matchedBy: ["screenshot"], home: context.home)
    }

    static func hasScreenCaptureAttribute(_ url: URL) -> Bool {
        let length = getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0)
        return length > 0
    }
}

// MARK: - Language files

public struct LanguageFilesScanner: CleanupScanner {
    public let info = CleanupCategoryInfo(id: "languages", title: "Language files",
        description: "Localizations your apps ship for languages you do not use. Removing them changes the app's code signature; apps on Apple silicon may refuse to launch afterwards, so they are listed as Caution.",
        systemImage: "character.book.closed", tier: .caution)
    public init() {}

    public func scan(_ context: CleanupContext) async -> [ScanItem] {
        var keep: Set<String> = ["base", "en", "english", "en_us", "en-us"]
        for language in context.preferredLanguages {
            let code = language.lowercased()
            keep.insert(code)
            keep.insert(String(code.split(separator: "-").first ?? ""))
        }
        var groups: [ScanItem] = []
        for app in context.installedApps where !app.isSystem {
            // App Store apps: removing files invalidates the receipt and breaks updates.
            if FileManager.default.fileExists(atPath: app.url.appending(path: "Contents/_MASReceipt").path) { continue }
            let resources = app.url.appending(path: "Contents/Resources")
            // The development region is the app's fallback language; without it, strings missing elsewhere show as keys.
            let appKeep = keep.union(Self.developmentRegionNames(of: app.url))
            let lprojs = CleanupSupport.children(of: resources).filter { url in
                guard url.pathExtension == "lproj" else { return false }
                let code = url.deletingPathExtension().lastPathComponent.lowercased()
                return !appKeep.contains(code) && !appKeep.contains(String(code.split(separator: "-").first ?? "")) && !appKeep.contains(String(code.split(separator: "_").first ?? ""))
            }
            guard !lprojs.isEmpty else { continue }
            let items = await CleanupSupport.items(for: lprojs, group: app.name, tier: .caution, matchedBy: ["unused localization"], home: context.home)
            groups.append(CleanupSupport.group(id: "languages:\(app.bundleID)", title: app.name,
                                               subtitle: app.identity.isNotarized == true ? "Notarized; removal breaks the signature" : nil,
                                               children: items, iconPath: app.url.path))
        }
        return groups.sorted { $0.size > $1.size }
    }

    /// Old-style localization folder names and the codes they stand for.
    static let legacyLanguageNames = ["english": "en", "german": "de", "french": "fr", "japanese": "ja", "spanish": "es", "italian": "it", "dutch": "nl"]

    /// Lowercased `.lproj` names that hold the app's `CFBundleDevelopmentRegion` (both `English` and `en` for English).
    static func developmentRegionNames(of appURL: URL) -> Set<String> {
        guard let info = NSDictionary(contentsOf: appURL.appending(path: "Contents/Info.plist")),
              let region = (info["CFBundleDevelopmentRegion"] as? String)?.lowercased(), !region.isEmpty else { return [] }
        var names: Set<String> = [region, region.replacingOccurrences(of: "-", with: "_"), region.replacingOccurrences(of: "_", with: "-")]
        if let code = legacyLanguageNames[region] { names.insert(code) }
        for (name, code) in legacyLanguageNames where code == region { names.insert(name) }
        return names
    }
}

// MARK: - Xcode junk

public struct XcodeJunkScanner: CleanupScanner {
    public let info = CleanupCategoryInfo(id: "xcode", title: "Xcode junk",
        description: "Derived data, device support files, simulator caches and old archives Xcode keeps around.", systemImage: "hammer", tier: .safe)
    public init() {}

    public func scan(_ context: CleanupContext) async -> [ScanItem] {
        let home = context.home
        let entries: [(String, String, RiskTier)] = [
            ("Library/Developer/Xcode/DerivedData", "Derived data", .safe),
            ("Library/Developer/Xcode/iOS DeviceSupport", "iOS device support", .safe),
            ("Library/Developer/Xcode/watchOS DeviceSupport", "watchOS device support", .safe),
            ("Library/Developer/Xcode/tvOS DeviceSupport", "tvOS device support", .safe),
            ("Library/Developer/CoreSimulator/Caches", "Simulator caches", .safe),
            ("Library/Caches/com.apple.dt.Xcode", "Xcode cache files", .safe),
            ("Library/Developer/Xcode/UserData/Previews", "SwiftUI previews", .safe),
            ("Library/Developer/Xcode/Archives", "Archives", .caution),
            ("Library/Developer/Xcode/Products", "Products", .caution),
        ]
        var groups: [ScanItem] = []
        for (relative, title, tier) in entries {
            let url = URL(filePath: home).appending(path: relative)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let children = CleanupSupport.children(of: url)
            let items = await CleanupSupport.items(for: children.isEmpty ? [url] : children, group: title, tier: tier, matchedBy: ["Xcode"], home: home)
            groups.append(CleanupSupport.group(id: "xcode:\(relative)", title: title, subtitle: "~/" + relative, children: items))
        }
        return groups.sorted { $0.size > $1.size }
    }
}

// MARK: - Bin (Trash of every volume)

public struct TrashScanner: CleanupScanner {
    public let info = CleanupCategoryInfo(id: "trash", title: "Trash",
        description: "Items in the Trash of the startup disk and of every enabled external disk. Emptying the Trash deletes them permanently.",
        systemImage: "trash", tier: .safe, isPerVolume: true)
    public init() {}

    public func scan(_ context: CleanupContext) async -> [ScanItem] {
        var groups: [ScanItem] = []
        let uid = getuid()
        for volume in context.scopedVolumes {
            var folders: [URL] = volume.isRoot ? [context.homeURL.appending(path: ".Trash")] : [volume.url.appending(path: ".Trashes/\(uid)")]
            if !volume.isRoot { folders.append(volume.url.appending(path: "$RECYCLE.BIN")); folders.append(volume.url.appending(path: ".Trash-\(uid)")) }
            var urls: [URL] = []
            var unreadable = false
            for folder in folders {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
                if let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(CleanupSupport.fileKeys), options: []) {
                    urls.append(contentsOf: children.filter { $0.lastPathComponent != ".DS_Store" && $0.lastPathComponent != "desktop.ini" })
                } else {
                    unreadable = true
                }
            }
            var items = await CleanupSupport.items(for: urls, group: "Trash on \(volume.name)", tier: .safe, matchedBy: ["in Trash"],
                                                   payload: ["permanent": "1"], home: context.home)
            var subtitle: String? = items.isEmpty ? "Empty" : nil
            if unreadable {
                // Without Full Disk Access the Trash folders are not readable; ask Finder instead and offer "Empty Trash".
                if volume.isRoot, let finder = Self.finderTrashSummary() {
                    items = [ScanItem(id: "trash:finder", title: "Empty Trash with Finder", subtitle: "\(finder.count) item\(finder.count == 1 ? "" : "s") · \(finder.bytes.formattedBytes) · all disks",
                                      kind: .registration, group: "Trash on \(volume.name)", size: finder.bytes, tier: .safe,
                                      matchedBy: ["Finder lists the Trash"], payload: ["type": "finderEmptyTrash"])]
                    subtitle = "Listed by Finder; grant Full Disk Access to pick single items"
                } else {
                    subtitle = volume.isRoot ? "Full Disk Access is required to read this Trash" : "Emptied together with the main Trash (Full Disk Access needed to list items)"
                }
            }
            if items.isEmpty && !unreadable && !volume.isRoot { continue }
            groups.append(CleanupSupport.group(id: "trash:\(volume.id)", title: "Trash on \(volume.name)", subtitle: subtitle, children: items))
        }
        return groups
    }

    /// Item count and total size of the Trash as Finder reports them (needs Automation permission once).
    static func finderTrashSummary() -> (count: Int, bytes: Int64)? {
        let script = """
        with timeout of 10 seconds
        tell application "Finder"
            set n to count of items of trash
            set total to 0
            repeat with i in items of trash
                try
                    set total to total + (physical size of i)
                end try
            end repeat
            return (n as string) & "|" & (total as string)
        end tell
        end timeout
        """
        guard let output = SystemRegistrationReader.run("/usr/bin/osascript", ["-e", script]) else { return nil }
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        guard parts.count == 2, let count = Int(parts[0]) else { return nil }
        let bytes = Int64(Double(parts[1].replacingOccurrences(of: ",", with: ".")) ?? 0)
        return (count, bytes)
    }
}

// MARK: - Mail attachments

public struct MailAttachmentsScanner: CleanupScanner {
    public let info = CleanupCategoryInfo(id: "mail", title: "Mail attachments",
        description: "Attachments Mail downloaded to open or preview. They stay in your mailbox and are downloaded again when needed.",
        systemImage: "paperclip", tier: .safe)
    public init() {}
    public func scan(_ context: CleanupContext) async -> [ScanItem] {
        let folder = context.homeURL.appending(path: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        let urls = CleanupSupport.children(of: folder)
        return await CleanupSupport.items(for: urls, group: "Mail attachments", tier: .safe, matchedBy: ["Mail download"], home: context.home)
    }
}

// MARK: - Purgeable space (per volume)

public struct PurgeableSpaceScanner: CleanupScanner {
    public let info = CleanupCategoryInfo(id: "purgeable", title: "Purgeable space",
        description: "Space macOS keeps for itself (snapshots, caches, copies of cloud files) and gives back by itself when an app needs room. When the startup disk is nearly full, CleanOS can make macOS release it now by writing a temporary file until macOS purges, then deleting the file. Local Time Machine snapshots can be deleted with the helper.",
        systemImage: "square.stack.3d.up.slash", tier: .caution, isPerVolume: true)
    public init() {}

    static let minimumPurgeable: Int64 = 50 * 1024 * 1024

    public func scan(_ context: CleanupContext) async -> [ScanItem] {
        var groups: [ScanItem] = []
        for volume in context.scopedVolumes {
            var children: [ScanItem] = []
            var snapshotCount = 0
            if volume.isAPFS {
                for snapshot in Self.localSnapshots(at: volume.url.path) {
                    snapshotCount += 1
                    children.append(ScanItem(id: "snapshot:\(volume.id):\(snapshot.name)", title: snapshot.name,
                                             subtitle: "Local Time Machine snapshot on \(volume.name); a backup Time Machine deletes by itself when space is needed",
                                             kind: .registration, group: "Snapshots on \(volume.name)", size: 0, tier: .caution,
                                             matchedBy: ["tmutil listlocalsnapshots"], needsRoot: true,
                                             payload: ["type": "snapshot", "mount": volume.url.path, "date": snapshot.date]))
                }
            }
            // The reclaim fills the disk it runs on, so it is only offered for the startup disk.
            if volume.isRoot, volume.isAPFS, let row = Self.purgeRow(for: volume) { children.insert(row, at: 0) }
            if !children.isEmpty || volume.isRoot {
                let subtitle = (volume.purgeableCapacity == 0 ? "Nothing purgeable right now" : "\(volume.purgeableCapacity.formattedBytes) purgeable")
                    + (snapshotCount > 0 ? " · \(snapshotCount) snapshot\(snapshotCount == 1 ? "" : "s")" : "")
                // Without children the group is a row of its own; it holds nothing to remove.
                groups.append(ScanItem(id: "purgeable:\(volume.id)", title: volume.name, subtitle: subtitle, kind: .group,
                                       group: "Purgeable space", size: volume.purgeableCapacity, tier: children.isEmpty ? .protected : .caution, children: children))
            }
        }
        return groups
    }

    /// The reclaim action when the write it needs is in proportion to the purgeable space, otherwise a display-only row
    /// explaining that macOS releases the space by itself. Nil when there is too little purgeable space to mention.
    static func purgeRow(for volume: VolumeInfo) -> ScanItem? {
        let purgeable = volume.purgeableCapacity
        guard purgeable >= minimumPurgeable else { return nil }
        let mount = volume.url.path
        let group = "Purgeable on \(volume.name)"
        let matchedBy = ["volumeAvailableCapacityForImportantUsage − volumeAvailableCapacity"]
        guard let write = PurgeableReclaimer.plannedWrite(available: volume.availableCapacity, purgeable: purgeable) else {
            return ScanItem(id: "purge:\(volume.id)", title: "\(purgeable.formattedBytes) of purgeable space",
                            subtitle: "macOS releases this by itself as soon as an app needs the space. Releasing it now would mean writing about \(volume.availableCapacity.formattedBytes) of temporary data, so CleanOS leaves it to macOS.",
                            kind: .registration, group: group, size: purgeable, tier: .protected, matchedBy: matchedBy,
                            payload: ["type": "purgeInfo", "mount": mount])
        }
        let subtitle: String
        if PurgeableReclaimer.looksReserved(mount: mount, purgeable: purgeable) {
            let last = PurgeableReclaimer.lastAttempt(mount: mount)
            subtitle = "A recent attempt released \(last?.purged.formattedBytes ?? "nothing"); macOS keeps the rest reserved. Try again later."
        } else {
            subtitle = "Writes about \(volume.availableCapacity.formattedBytes) of temporary data (at most \(write.formattedBytes)) until macOS purges, stops as soon as it has, then deletes it. The disk is nearly full while this runs."
        }
        return ScanItem(id: "purge:\(volume.id)", title: "Reclaim \(purgeable.formattedBytes) of purgeable space", subtitle: subtitle,
                        kind: .registration, group: group, size: purgeable, tier: .caution, matchedBy: matchedBy,
                        payload: ["type": "purge", "mount": mount, "bytes": String(purgeable)])
    }

    public struct LocalSnapshot: Sendable, Equatable {
        /// Full snapshot name, `com.apple.TimeMachine.2026-11-09-101500.local`.
        public let name: String
        /// The date `tmutil deletelocalsnapshots <date>` takes, `2026-11-09-101500`.
        public let date: String
    }

    static func localSnapshots(at mount: String) -> [LocalSnapshot] {
        guard let output = SystemRegistrationReader.run("/usr/bin/tmutil", ["listlocalsnapshots", mount]) else { return [] }
        return parseLocalSnapshots(output)
    }

    /// Time Machine snapshots in `tmutil listlocalsnapshots` output; lines without a snapshot date are skipped.
    static func parseLocalSnapshots(_ output: String) -> [LocalSnapshot] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("com.apple.TimeMachine."),
                  let range = line.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
            return LocalSnapshot(name: line, date: String(line[range]))
        }
    }
}

// MARK: - External disk junk

public struct ExternalDiskJunkScanner: CleanupScanner {
    public let info = CleanupCategoryInfo(id: "externalJunk", title: "External disk junk",
        description: "Hidden folders macOS leaves on external disks: Spotlight indexes, file-system event logs, temporary items and saved document versions, plus .DS_Store files and AppleDouble (._) files whose file is gone. Windows recycle bins are listed under Bin.",
        systemImage: "externaldrive.badge.xmark", tier: .safe, isPerVolume: true)
    public init() {}

    /// Folders at the root of a disk that are listed as a whole (here or under Bin), so the AppleDouble walk skips them.
    static let listedRootFolders: Set<String> = [".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems", ".Trashes",
                                                 "$RECYCLE.BIN", "System Volume Information", "lost+found"]

    public func scan(_ context: CleanupContext) async -> [ScanItem] {
        var groups: [ScanItem] = []
        let fm = FileManager.default
        for volume in context.scopedVolumes where !volume.isRoot {
            var children: [ScanItem] = []
            func add(_ name: String, title: String, tier: RiskTier, reason: String, note: String? = nil, payload: [String: String] = [:], kind: ItemKind = .directory) async {
                let url = volume.url.appending(path: name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
                let readable = fm.isReadableFile(atPath: url.path) && (try? fm.contentsOfDirectory(atPath: url.path)) != nil
                let size = readable ? DirectorySizer.size(of: url) : .zero
                let measured = readable ? size.itemSummary : "Full Disk Access is required to measure this folder"
                children.append(ScanItem(url: url, title: title, subtitle: [note, measured].compactMap { $0 }.joined(separator: " · "),
                                         kind: payload.isEmpty ? kind : .registration, group: "Junk on \(volume.name)", size: size.bytes, tier: tier,
                                         matchedBy: [reason], needsRoot: !FileRemover.isUserRemovable(url) || !payload.isEmpty, payload: payload))
            }
            await add(".Spotlight-V100", title: "Rebuild the Spotlight index on \(volume.name)", tier: .safe, reason: "Spotlight index on an external disk",
                      note: "Erases the index (mdutil -E) and Spotlight builds a new one; search on this disk is incomplete until it finishes",
                      payload: ["type": "spotlightIndex", "mount": volume.url.path])
            await add(".fseventsd", title: "Clear the file-system event log on \(volume.name)", tier: .safe, reason: "FSEvents log",
                      note: "Deletes the contents of .fseventsd and macOS starts a new log; backup and sync apps may rescan this disk once",
                      payload: ["type": "fseventsd", "mount": volume.url.path])
            await add(".DocumentRevisions-V100", title: "Saved document versions (.DocumentRevisions-V100)", tier: .caution, reason: "versions store",
                      note: "Earlier versions of documents on this disk (File › Revert To › Browse All Versions); removing it deletes them")
            await add(".TemporaryItems", title: "Temporary items (.TemporaryItems)", tier: .safe, reason: "temporary items")
            await add("lost+found", title: "lost+found", tier: .caution, reason: "file system check leftovers")
            await add("System Volume Information", title: "System Volume Information", tier: .protected, reason: "Windows system folder")
            // $RECYCLE.BIN is the Windows Trash: Bin (TrashScanner) lists its contents, so it is not listed twice here.
            // Other users' trashes.
            let trashes = volume.url.appending(path: ".Trashes")
            if let users = try? fm.contentsOfDirectory(atPath: trashes.path) {
                for user in users where user != String(getuid()) && Int(user) != nil {
                    let url = trashes.appending(path: user)
                    let size = DirectorySizer.size(of: url)
                    children.append(ScanItem(url: url, title: "Trash of user \(user)", subtitle: size.itemSummary, kind: .directory, group: "Junk on \(volume.name)",
                                             size: size.bytes, tier: .caution, matchedBy: ["another user's Trash"], needsRoot: true))
                }
            }
            // .DS_Store and orphaned AppleDouble files on non-Apple file systems (depth-limited walk).
            if !volume.isAPFS, !volume.format.localizedCaseInsensitiveContains("hfs") {
                let found = Self.findAppleDoubles(on: volume.url)
                let suffix = found.partial ? " (partial scan of a large disk)" : ""
                if !found.dsStores.isEmpty {
                    let items = await CleanupSupport.items(for: found.dsStores, group: ".DS_Store files on \(volume.name)", tier: .safe,
                                                           matchedBy: [".DS_Store on a non-Apple disk"], home: context.home)
                    children.append(CleanupSupport.group(id: "externalJunk:\(volume.id):dsstore", title: ".DS_Store files" + suffix,
                                                         subtitle: "Finder window settings; Finder recreates them", children: items))
                }
                if !found.orphans.isEmpty {
                    let items = await CleanupSupport.items(for: found.orphans, group: "AppleDouble files on \(volume.name)", tier: .caution,
                                                           matchedBy: ["AppleDouble file without its file on a non-Apple disk"], home: context.home)
                        .map { item -> ScanItem in
                            guard item.tier != .protected, let url = item.url else { return item }
                            var copy = item
                            copy.subtitle = "“\(Self.companionName(of: url.lastPathComponent))” is no longer beside it; removing this deletes the Finder tags, extended attributes and resource fork it kept for that file"
                            return copy
                        }
                    children.append(CleanupSupport.group(id: "externalJunk:\(volume.id):appledouble", title: "Orphaned AppleDouble (._) files" + suffix,
                                                         subtitle: "Metadata of files that are no longer on this disk", children: items))
                }
            }
            if !children.isEmpty {
                groups.append(ScanItem(id: "externalJunk:\(volume.id)", title: volume.name, subtitle: volume.format, kind: .group, group: "External disk junk", children: children).rollingUpSizes())
            }
        }
        return groups
    }
}

extension ExternalDiskJunkScanner {
    /// Depth-, count- and time-limited synchronous walk for `.DS_Store` files and AppleDouble files whose file is gone (large
    /// NTFS disks are slow). On exFAT, FAT and NTFS `._x` holds the metadata and resource fork of `x`, so it is only offered
    /// once `x` no longer exists beside it.
    static func findAppleDoubles(on volume: URL, maxEntries: Int = 25_000, maxSeconds: TimeInterval = 6) -> (dsStores: [URL], orphans: [URL], partial: Bool) {
        var dsStores: [URL] = []
        var orphans: [URL] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(maxSeconds)
        // Breadth-first over three levels. readdir, not FileManager: Foundation leaves `._` files out of its listings.
        var pending: [(folder: URL, level: Int)] = [(volume, 1)]
        var next = 0
        while next < pending.count {
            let (folder, level) = pending[next]
            next += 1
            for entry in directoryEntries(of: folder.path) {
                visited += 1
                if visited > maxEntries || Date() > deadline { return (dsStores, orphans, true) }
                let url = folder.appending(path: entry.name)
                if entry.isDirectory {
                    if level == 1, listedRootFolders.contains(entry.name) || entry.name.hasPrefix(".Trash-") { continue }
                    if level < 3, (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true { pending.append((url, level + 1)) }
                    continue
                }
                if entry.name == ".DS_Store" { dsStores.append(url) }
                else if isOrphanAppleDouble(url) { orphans.append(url) }
                if dsStores.count + orphans.count >= 2000 { return (dsStores, orphans, true) }
            }
        }
        return (dsStores, orphans, false)
    }

    /// Names in a folder and whether each is a folder (symbolic links are not), as the file system lists them.
    static func directoryEntries(of path: String) -> [(name: String, isDirectory: Bool)] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var entries: [(name: String, isDirectory: Bool)] = []
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            if name == "." || name == ".." { continue }
            var isDirectory = Int32(entry.pointee.d_type) == DT_DIR
            if Int32(entry.pointee.d_type) == DT_UNKNOWN {
                var st = stat()
                isDirectory = lstat(path + "/" + name, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
            }
            entries.append((name, isDirectory))
        }
        return entries
    }

    /// `x` for an AppleDouble file named `._x`.
    static func companionName(of name: String) -> String { String(name.dropFirst(2)) }

    /// True for `._x` when nothing named `x` (file, folder or link) exists beside it.
    static func isOrphanAppleDouble(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix("._"), name.count > 2 else { return false }
        var st = stat()
        return lstat(url.deletingLastPathComponent().appending(path: companionName(of: name)).path, &st) != 0 && errno == ENOENT
    }
}

// MARK: - Engine

/// Runs every Clean Up scanner and keeps the results.
public actor CleanupEngine {
    public static let scanners: [any CleanupScanner] = [
        CachesScanner(), DownloadsScanner(), InstallationFilesScanner(), ScreenshotsScanner(), LanguageFilesScanner(),
        XcodeJunkScanner(), TrashScanner(), MailAttachmentsScanner(), PurgeableSpaceScanner(), ExternalDiskJunkScanner(),
    ]
    public static var categories: [CleanupCategoryInfo] { scanners.map(\.info) }

    public init() {}

    public func scan(categoryID: String, context: CleanupContext) async -> CleanupResult? {
        guard let scanner = Self.scanners.first(where: { $0.info.id == categoryID }) else { return nil }
        let start = Date()
        let unreadable = UnreadableFolders()
        var items = await CleanupSupport.$unreadable.withValue(unreadable) { await scanner.scan(context) }
        // A folder the scan could not list would otherwise look clean: say so with a display-only row.
        if let note = CleanupSupport.unreadableNote(unreadable.all, category: scanner.info, home: context.home) { items.append(note) }
        return CleanupResult(category: scanner.info, items: items, duration: Date().timeIntervalSince(start))
    }
}
