import Foundation

public struct ExtensionGroupInfo: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let description: String
    public let systemImage: String
    public init(id: String, title: String, description: String, systemImage: String) {
        self.id = id; self.title = title; self.description = description; self.systemImage = systemImage
    }
}

/// Browser extensions and the system plug-in kinds CleanOS manages (system extensions and kexts are not covered).
public actor ExtensionsScanner {
    public static let groups: [ExtensionGroupInfo] = [
        ExtensionGroupInfo(id: "installers", title: "Installation Files", description: "Disk images and packages on your startup disk.", systemImage: "shippingbox"),
        ExtensionGroupInfo(id: "browser", title: "Web Browser Extensions", description: "Extensions installed in Safari, Chrome, Brave, Edge, Arc, Vivaldi and Firefox.", systemImage: "safari"),
        ExtensionGroupInfo(id: "screensavers", title: "Screen Savers", description: "Third-party screen savers.", systemImage: "display"),
        ExtensionGroupInfo(id: "prefpanes", title: "Settings Panes", description: "Plug-ins that add custom sections to System Settings.", systemImage: "slider.horizontal.3"),
        ExtensionGroupInfo(id: "internetplugins", title: "Internet Plugins", description: "Legacy browser plug-ins.", systemImage: "network"),
        ExtensionGroupInfo(id: "widgets", title: "Widgets", description: "Notification Center and desktop widgets provided by apps.", systemImage: "square.grid.2x2"),
        ExtensionGroupInfo(id: "audiovideo", title: "Audio & Video Plug-ins", description: "Audio units, VST/CLAP plug-ins, virtual audio devices and virtual cameras.", systemImage: "waveform"),
        ExtensionGroupInfo(id: "systemplugins", title: "Quick Look & Spotlight Plug-ins", description: "Quick Look generators and Spotlight importers.", systemImage: "magnifyingglass"),
    ]

    private let home: String
    public init(home: String = NSHomeDirectory()) { self.home = home }

    public func scan(groupID: String, context: CleanupContext) async -> [ScanItem] {
        switch groupID {
        case "installers": return await InstallationFilesScanner().scan(context)
        case "browser": return await browserExtensions(context: context)
        case "screensavers": return await bundles(in: ["~/Library/Screen Savers", "/Library/Screen Savers"], group: "Screen Savers", context: context)
        case "prefpanes": return await bundles(in: ["~/Library/PreferencePanes", "/Library/PreferencePanes"], group: "Settings Panes", context: context)
        case "internetplugins": return await bundles(in: ["~/Library/Internet Plug-Ins", "/Library/Internet Plug-Ins"], group: "Internet Plugins", context: context)
        case "widgets": return widgets(context: context)
        case "audiovideo": return await bundles(in: ["~/Library/Audio/Plug-Ins/Components", "~/Library/Audio/Plug-Ins/VST", "~/Library/Audio/Plug-Ins/VST3", "~/Library/Audio/Plug-Ins/CLAP", "~/Library/Audio/Plug-Ins/HAL",
                                                      "/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/VST", "/Library/Audio/Plug-Ins/VST3", "/Library/Audio/Plug-Ins/CLAP", "/Library/Audio/Plug-Ins/HAL",
                                                      "/Library/Audio/Plug-Ins/MIDI Drivers", "/Library/CoreMediaIO/Plug-Ins/DAL"], group: "Audio & Video Plug-ins", context: context)
        case "systemplugins": return await bundles(in: ["~/Library/QuickLook", "/Library/QuickLook", "~/Library/Spotlight", "/Library/Spotlight"], group: "Quick Look & Spotlight Plug-ins", context: context)
        default: return []
        }
    }

    // MARK: Bundles in plug-in folders

    private func bundles(in roots: [String], group: String, context: CleanupContext) async -> [ScanItem] {
        var urls: [(URL, String)] = []
        for root in roots {
            let dir = URL(filePath: PathExpander.expand(root, home: home))
            for child in CleanupSupport.children(of: dir) where child.lastPathComponent != "Icons" {
                urls.append((child, root))
            }
        }
        let sizes = await DirectorySizer.sizes(of: urls.map(\.0), maxConcurrency: 6)
        return urls.map { url, root in
            let info = AppInspector.infoPlist(at: url)
            let bundleID = info?["CFBundleIdentifier"] as? String
            let owner = bundleID.flatMap { id in context.installedApps.first { $0.bundleID == id || $0.identity.subBundleIDs.contains(id) } }
                ?? context.installedApps.first { app in url.path.hasPrefix(app.url.path + "/") }
            let apple = bundleID?.hasPrefix("com.apple.") == true
            return ScanItem(url: url, title: (info?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent,
                            subtitle: [bundleID, owner.map { "part of \($0.name)" }, root.hasPrefix("~") ? "User" : "All users"].compactMap { $0 }.joined(separator: " · "),
                            kind: .bundle, group: group, size: sizes[url]?.bytes ?? 0, tier: apple ? .protected : .normal,
                            matchedBy: ["plug-in folder \(root)"], needsRoot: !FileRemover.isUserRemovable(url),
                            modificationDate: CleanupSupport.modificationDate(url),
                            payload: owner.map { ["ownerPath": $0.url.path] } ?? [:])
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: Widgets (pluginkit)

    private func widgets(context: CleanupContext) -> [ScanItem] {
        let output = SystemRegistrationReader.run("/usr/bin/pluginkit", ["-m", "-A", "-v", "-p", "com.apple.widgetkit-extension"]) ?? ""
        return Self.parsePluginkit(output).map { entry in
            let owner = context.installedApps.first { entry.path.hasPrefix($0.url.path + "/") }
            let apple = entry.identifier.hasPrefix("com.apple.")
            return ScanItem(id: "widget:\(entry.identifier)", url: URL(filePath: entry.path), title: owner?.name ?? URL(filePath: entry.path).deletingPathExtension().lastPathComponent,
                            subtitle: "\(entry.identifier) · \(entry.enabled ? "enabled" : "disabled")", kind: .bundle, group: "Widgets", size: 0,
                            tier: apple ? .protected : .caution, matchedBy: ["pluginkit"], needsRoot: false,
                            payload: ["type": "pluginkit", "identifier": entry.identifier, "enabled": entry.enabled ? "1" : "0", "partOfApp": "1"])
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    struct PluginkitEntry { let enabled: Bool; let identifier: String; let version: String; let path: String }

    /// Parses `pluginkit -m -A -v` lines: `+    com.example.widget(1.0)    UUID    2024-01-01 00:00:00 +0000    /path`.
    /// The first character is the user election: `+` enabled, `-` disabled, `!` elected, blank = default (enabled).
    static func parsePluginkit(_ output: String) -> [PluginkitEntry] {
        output.split(separator: "\n").compactMap { line in
            let text = String(line)
            guard let marker = text.first, "+-! ".contains(marker), text.contains("(") else { return nil }
            let columns = text.dropFirst().split(separator: "\t", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 2 else { return nil }
            let idVersion = columns[0]
            let identifier = idVersion.split(separator: "(").first.map(String.init) ?? idVersion
            let version = idVersion.split(separator: "(").dropFirst().first.map { String($0).replacingOccurrences(of: ")", with: "") } ?? ""
            let path = columns.last ?? ""
            return PluginkitEntry(enabled: marker != "-", identifier: identifier, version: version, path: path)
        }
    }

    // MARK: Browser extensions

    struct ChromiumBrowser { let name: String; let bundleID: String; let dataDir: String }
    static let chromiumBrowsers: [ChromiumBrowser] = [
        ChromiumBrowser(name: "Google Chrome", bundleID: "com.google.Chrome", dataDir: "Library/Application Support/Google/Chrome"),
        ChromiumBrowser(name: "Brave Browser", bundleID: "com.brave.Browser", dataDir: "Library/Application Support/BraveSoftware/Brave-Browser"),
        ChromiumBrowser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", dataDir: "Library/Application Support/Microsoft Edge"),
        ChromiumBrowser(name: "Arc", bundleID: "company.thebrowser.Browser", dataDir: "Library/Application Support/Arc/User Data"),
        ChromiumBrowser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", dataDir: "Library/Application Support/Vivaldi"),
        ChromiumBrowser(name: "Chromium", bundleID: "org.chromium.Chromium", dataDir: "Library/Application Support/Chromium"),
    ]

    private func browserExtensions(context: CleanupContext) async -> [ScanItem] {
        var groups: [ScanItem] = []
        for browser in Self.chromiumBrowsers {
            let dataDir = URL(filePath: home).appending(path: browser.dataDir)
            guard FileManager.default.fileExists(atPath: dataDir.path) else { continue }
            var items: [ScanItem] = []
            for profile in CleanupSupport.children(of: dataDir) where CleanupSupport.isDirectory(profile) && (profile.lastPathComponent == "Default" || profile.lastPathComponent.hasPrefix("Profile ")) {
                let states = Self.chromiumExtensionStates(profile: profile)
                let extensionsDir = profile.appending(path: "Extensions")
                for extDir in CleanupSupport.children(of: extensionsDir) where CleanupSupport.isDirectory(extDir) {
                    guard let versionDir = CleanupSupport.children(of: extDir).filter(CleanupSupport.isDirectory).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first,
                          let manifest = Self.readJSON(versionDir.appending(path: "manifest.json")) else { continue }
                    let id = extDir.lastPathComponent
                    let name = Self.chromiumName(manifest: manifest, versionDir: versionDir)
                    let size = DirectorySizer.size(of: extDir)
                    let enabled = states[id] ?? true
                    items.append(ScanItem(url: extDir, title: name, subtitle: "\(enabled ? "Enabled" : "Disabled") · \(manifest["version"] as? String ?? "") · \(profile.lastPathComponent)",
                                          kind: .directory, group: browser.name, size: size.bytes, tier: .caution,
                                          matchedBy: ["Chromium extension in \(browser.name)"], modificationDate: CleanupSupport.modificationDate(extDir),
                                          payload: ["type": "chromiumExtension", "browser": browser.bundleID, "extensionID": id, "enabled": enabled ? "1" : "0"]))
                }
            }
            guard !items.isEmpty else { continue }
            let app = context.installedApps.first { $0.bundleID == browser.bundleID }
            groups.append(CleanupSupport.group(id: "browserext:\(browser.bundleID)", title: browser.name,
                                               subtitle: "\(items.count) extensions · \(items.filter { $0.payload["enabled"] == "1" }.count) enabled. The browser may reinstall synced extensions.",
                                               children: items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, iconPath: app?.url.path))
        }

        // Firefox
        let firefoxProfiles = URL(filePath: home).appending(path: "Library/Application Support/Firefox/Profiles")
        var firefoxItems: [ScanItem] = []
        for profile in CleanupSupport.children(of: firefoxProfiles) {
            guard let json = Self.readJSON(profile.appending(path: "extensions.json")), let addons = json["addons"] as? [[String: Any]] else { continue }
            for addon in addons where (addon["location"] as? String) == "app-profile" {
                let locale = addon["defaultLocale"] as? [String: Any]
                let path = addon["path"] as? String ?? ""
                let url = URL(filePath: path)
                firefoxItems.append(ScanItem(url: url, title: locale?["name"] as? String ?? addon["id"] as? String ?? "Extension",
                                             subtitle: "\((addon["active"] as? Bool ?? false) ? "Enabled" : "Disabled") · \(addon["version"] as? String ?? "") · \(profile.lastPathComponent)",
                                             kind: .file, group: "Firefox", size: DirectorySizer.size(of: url).bytes, tier: .caution,
                                             matchedBy: ["Firefox extensions.json"], payload: ["type": "firefoxExtension", "extensionID": addon["id"] as? String ?? ""]))
            }
        }
        if !firefoxItems.isEmpty {
            let app = context.installedApps.first { $0.bundleID == "org.mozilla.firefox" }
            groups.append(CleanupSupport.group(id: "browserext:firefox", title: "Firefox", subtitle: "\(firefoxItems.count) extensions", children: firefoxItems, iconPath: app?.url.path))
        }

        // Safari (app extensions registered with pluginkit; they live inside their host apps).
        var safariItems: [ScanItem] = []
        for type in ["com.apple.Safari.web-extension", "com.apple.Safari.extension", "com.apple.Safari.content-blocker"] {
            let output = SystemRegistrationReader.run("/usr/bin/pluginkit", ["-m", "-A", "-v", "-p", type]) ?? ""
            for entry in Self.parsePluginkit(output) {
                let owner = context.installedApps.first { entry.path.hasPrefix($0.url.path + "/") }
                safariItems.append(ScanItem(id: "safariext:\(entry.identifier)", url: URL(filePath: entry.path),
                                            title: owner?.name ?? URL(filePath: entry.path).deletingPathExtension().lastPathComponent,
                                            subtitle: "\(entry.enabled ? "Enabled" : "Disabled") · \(entry.identifier)", kind: .bundle, group: "Safari", size: 0,
                                            tier: .caution, matchedBy: ["pluginkit \(type)"],
                                            payload: ["type": "pluginkit", "identifier": entry.identifier, "enabled": entry.enabled ? "1" : "0", "partOfApp": "1"]))
            }
        }
        if !safariItems.isEmpty {
            groups.append(CleanupSupport.group(id: "browserext:safari", title: "Safari", subtitle: "Extensions are part of their apps; disable them here or uninstall the app.",
                                               children: safariItems.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, iconPath: "/Applications/Safari.app"))
        }
        return groups
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// `extensions.settings.<id>.state` from the profile's Preferences (1 = enabled).
    static func chromiumExtensionStates(profile: URL) -> [String: Bool] {
        var states: [String: Bool] = [:]
        for file in ["Preferences", "Secure Preferences"] {
            guard let json = readJSON(profile.appending(path: file)), let extensions = json["extensions"] as? [String: Any],
                  let settings = extensions["settings"] as? [String: Any] else { continue }
            for (id, value) in settings {
                if let dict = value as? [String: Any], let state = dict["state"] as? Int { states[id] = state == 1 }
            }
        }
        return states
    }

    /// Resolves `__MSG_name__` placeholders through `_locales`.
    static func chromiumName(manifest: [String: Any], versionDir: URL) -> String {
        let raw = manifest["name"] as? String ?? "Extension"
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }
        let key = String(raw.dropFirst(6).dropLast(2))
        let locales = versionDir.appending(path: "_locales")
        var candidates = [manifest["default_locale"] as? String ?? "en", "en", "en_US"]
        candidates.append(contentsOf: (try? FileManager.default.contentsOfDirectory(atPath: locales.path)) ?? [])
        for locale in candidates {
            if let messages = readJSON(locales.appending(path: locale).appending(path: "messages.json")),
               let entry = (messages[key] ?? messages[key.lowercased()]) as? [String: Any], let message = entry["message"] as? String { return message }
        }
        return raw
    }
}

/// Enables or disables pluginkit-registered extensions (Safari extensions, widgets).
public enum PluginkitController {
    public static func setEnabled(identifier: String, _ enabled: Bool) -> String? {
        if FileRemover.isDryRun { return nil }
        let output = SystemRegistrationReader.run("/usr/bin/pluginkit", ["-e", enabled ? "use" : "ignore", "-i", identifier]) ?? ""
        return output.isEmpty ? nil : output
    }
}
