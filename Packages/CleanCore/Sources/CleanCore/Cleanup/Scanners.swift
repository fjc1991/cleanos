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
    /// Apple apps whose caches behave like any app cache and are safe to clear.
    static let safeAppleCaches = ["com.apple.safari", "com.apple.dt.xcode", "com.apple.music", "com.apple.tv", "com.apple.podcasts", "com.apple.news",
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
                if claimed.contains(path) || name == ".DS_Store" || Self.systemCacheSkipList.contains(where: { lower.hasPrefix($0) }) { continue }
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
        description: "Disk images and installer packages. Once you have installed apps you can remove their installation files.", systemImage: "shippingbox", tier: .normal)
    public init() {}
    static let extensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso", "sparseimage"]

    public func scan(_ context: CleanupContext) async -> [ScanItem] {
        var found = Self.findInstallers(in: context.homeURL)
        for volume in context.scopedVolumes where !volume.isRoot {
            for child in CleanupSupport.children(of: volume.url) where Self.extensions.contains(child.pathExtension.lowercased()) { found.append(child) }
        }
        return await CleanupSupport.items(for: found, group: "Installation files", tier: .normal, matchedBy: ["installer image or package"], home: context.home)
    }

    /// Synchronous walk (NSEnumerator cannot be iterated from an async context).
    static func findInstallers(in home: URL) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        for folder in ["Downloads", "Desktop", "Documents"] {
            let root = home.appending(path: folder)
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                if enumerator.level > 3 { enumerator.skipDescendants(); continue }
                if extensions.contains(url.pathExtension.lowercased()) { found.append(url) }
            }
        }
        return found
    }
}

// MARK: - Screenshots

public struct ScreenshotsScanner: CleanupScanner {
    public let info = CleanupCategoryInfo(id: "screenshots", title: "Screenshot files",
        description: "Screenshots and screen recordings saved by macOS.", systemImage: "camera.viewfinder", tier: .normal)
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
        return await CleanupSupport.items(for: urls, group: "Screenshot files", tier: .normal, matchedBy: ["screenshot"], home: context.home)
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
            let resources = app.url.appending(path: "Contents/Resources")
            let lprojs = CleanupSupport.children(of: resources).filter { url in
                guard url.pathExtension == "lproj" else { return false }
                let code = url.deletingPathExtension().lastPathComponent.lowercased()
                return !keep.contains(code) && !keep.contains(String(code.split(separator: "-").first ?? "")) && !keep.contains(String(code.split(separator: "_").first ?? ""))
            }
            guard !lprojs.isEmpty else { continue }
            let items = await CleanupSupport.items(for: lprojs, group: app.name, tier: .caution, matchedBy: ["unused localization"], home: context.home)
            groups.append(CleanupSupport.group(id: "languages:\(app.bundleID)", title: app.name,
                                               subtitle: app.identity.isNotarized == true ? "Notarized; removal breaks the signature" : nil,
                                               children: items, iconPath: app.url.path))
        }
        return groups.sorted { $0.size > $1.size }
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
    public let info = CleanupCategoryInfo(id: "trash", title: "Bin",
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
        description: "Space macOS keeps for itself (snapshots, caches, copies of cloud files) and only gives back under pressure. CleanOS reclaims it by writing a temporary file until the disk is briefly full, which makes macOS purge, then deleting the file. Local snapshots can be deleted directly with the helper.",
        systemImage: "square.stack.3d.up.slash", tier: .normal, isPerVolume: true)
    public init() {}

    public func scan(_ context: CleanupContext) async -> [ScanItem] {
        var groups: [ScanItem] = []
        for volume in context.scopedVolumes {
            var children: [ScanItem] = []
            if volume.isAPFS {
                for snapshot in Self.localSnapshots(at: volume.url.path) {
                    children.append(ScanItem(id: "snapshot:\(volume.id):\(snapshot)", title: snapshot, subtitle: "Local Time Machine snapshot on \(volume.name)",
                                             kind: .registration, group: "Snapshots on \(volume.name)", size: 0, tier: .normal,
                                             matchedBy: ["tmutil listlocalsnapshots"], needsRoot: true,
                                             payload: ["type": "snapshot", "mount": volume.url.path, "date": String(snapshot.split(separator: ".").last ?? "")]))
                }
            }
            if volume.purgeableCapacity >= 50 * 1024 * 1024 {
                let reserved = PurgeableReclaimer.looksReserved(mount: volume.url.path, purgeable: volume.purgeableCapacity)
                let last = PurgeableReclaimer.lastAttempt(mount: volume.url.path)
                children.insert(ScanItem(id: "purge:\(volume.id)", title: "Reclaim \(volume.purgeableCapacity.formattedBytes) of purgeable space",
                                         subtitle: reserved
                                            ? "A recent attempt released \(last?.purged.formattedBytes ?? "nothing"); macOS keeps the rest reserved. Try again later."
                                            : "Writes a temporary file until macOS purges, then deletes it; the disk is full for a few seconds",
                                         kind: .registration, group: "Purgeable on \(volume.name)", size: volume.purgeableCapacity, tier: reserved ? .caution : .normal,
                                         matchedBy: ["volumeAvailableCapacityForImportantUsage − volumeAvailableCapacity"],
                                         payload: ["type": "purge", "mount": volume.url.path, "bytes": String(volume.purgeableCapacity)]), at: 0)
            }
            if !children.isEmpty || volume.isRoot {
                let subtitle = volume.purgeableCapacity == 0 ? "Nothing purgeable right now" : "\(volume.purgeableCapacity.formattedBytes) purgeable" + (children.count > 1 ? " · \(children.count - 1) snapshot\(children.count == 2 ? "" : "s")" : "")
                groups.append(ScanItem(id: "purgeable:\(volume.id)", title: volume.name, subtitle: subtitle, kind: .group,
                                       group: "Purgeable space", size: volume.purgeableCapacity, children: children))
            }
        }
        return groups
    }

    static func localSnapshots(at mount: String) -> [String] {
        guard let output = SystemRegistrationReader.run("/usr/bin/tmutil", ["listlocalsnapshots", mount]) else { return [] }
        return output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("com.apple.TimeMachine") }
    }
}

// MARK: - External disk junk

public struct ExternalDiskJunkScanner: CleanupScanner {
    public let info = CleanupCategoryInfo(id: "externalJunk", title: "External disk junk",
        description: "Hidden folders macOS and Windows leave on external disks: Spotlight indexes, file-system event logs, temporary items, Windows recycle bins and AppleDouble (._) files.",
        systemImage: "externaldrive.badge.xmark", tier: .safe, isPerVolume: true)
    public init() {}

    public func scan(_ context: CleanupContext) async -> [ScanItem] {
        var groups: [ScanItem] = []
        let fm = FileManager.default
        for volume in context.scopedVolumes where !volume.isRoot {
            var children: [ScanItem] = []
            func add(_ name: String, title: String, tier: RiskTier, reason: String, payload: [String: String] = [:], kind: ItemKind = .directory) async {
                let url = volume.url.appending(path: name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
                let readable = fm.isReadableFile(atPath: url.path) && (try? fm.contentsOfDirectory(atPath: url.path)) != nil
                let size = readable ? DirectorySizer.size(of: url) : .zero
                children.append(ScanItem(url: url, title: title, subtitle: readable ? "\(size.itemSummary)" : "Full Disk Access is required to measure this folder",
                                         kind: payload.isEmpty ? kind : .registration, group: "Junk on \(volume.name)", size: size.bytes, tier: tier,
                                         matchedBy: [reason], needsRoot: !FileRemover.isUserRemovable(url) || !payload.isEmpty, payload: payload))
            }
            await add(".Spotlight-V100", title: "Spotlight index (.Spotlight-V100)", tier: .safe, reason: "Spotlight index on an external disk",
                      payload: ["type": "spotlightIndex", "mount": volume.url.path])
            await add(".fseventsd", title: "File system events log (.fseventsd)", tier: .safe, reason: "FSEvents log", payload: ["type": "fseventsd", "mount": volume.url.path])
            await add(".DocumentRevisions-V100", title: "Document revisions (.DocumentRevisions-V100)", tier: .safe, reason: "versions store")
            await add(".TemporaryItems", title: "Temporary items (.TemporaryItems)", tier: .safe, reason: "temporary items")
            await add("lost+found", title: "lost+found", tier: .caution, reason: "file system check leftovers")
            await add("System Volume Information", title: "System Volume Information", tier: .protected, reason: "Windows system folder")
            await add("$RECYCLE.BIN", title: "Windows Recycle Bin", tier: .safe, reason: "Windows recycle bin")
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
            // AppleDouble and .DS_Store files on non-Apple file systems (depth-limited walk).
            if !volume.isAPFS, !volume.format.localizedCaseInsensitiveContains("hfs") {
                let (doubles, partial) = Self.findAppleDoubles(on: volume.url)
                if !doubles.isEmpty {
                    let items = await CleanupSupport.items(for: doubles, group: "AppleDouble files on \(volume.name)", tier: .safe, matchedBy: ["AppleDouble/.DS_Store on a non-Apple disk"], home: context.home)
                    children.append(CleanupSupport.group(id: "externalJunk:\(volume.id):appledouble", title: "AppleDouble and .DS_Store files" + (partial ? " (partial scan of a large disk)" : ""), children: items))
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
    /// Depth-, count- and time-limited synchronous walk for `._*` and `.DS_Store` files (large NTFS disks are slow).
    static func findAppleDoubles(on volume: URL, maxEntries: Int = 25_000, maxSeconds: TimeInterval = 6) -> (files: [URL], partial: Bool) {
        var doubles: [URL] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(maxSeconds)
        guard let enumerator = FileManager.default.enumerator(at: volume, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return ([], false) }
        for case let url as URL in enumerator {
            visited += 1
            if visited > maxEntries || Date() > deadline { return (doubles, true) }
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            let name = url.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") { doubles.append(url) }
            if doubles.count >= 2000 { return (doubles, true) }
        }
        return (doubles, false)
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
        let items = await scanner.scan(context)
        return CleanupResult(category: scanner.info, items: items, duration: Date().timeIntervalSince(start))
    }
}
