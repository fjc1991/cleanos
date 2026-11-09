import Foundation
import HelperProtocol
import Security
import SQLite3

/// Raw registration data. The default reader talks to the system; tests inject a stub.
public protocol RegistrationReader: Sendable {
    func launchServicesHandlers() -> [[String: String]]
    func dockTiles() -> [(index: Int, path: String)]
    func notificationCenterApps() -> [String]
    func tccRows() -> [TCCRow]
    func keychainItems() -> [KeychainItem]
    func launchdJobs() -> [(label: String, pid: Int?)]
    func firewallApps() -> [String]
}

public struct TCCRow: Sendable, Hashable {
    public let service: String
    public let client: String
    public let allowed: Bool
    public let lastModified: Date?
    public let isSystemDatabase: Bool
    public init(service: String, client: String, allowed: Bool, lastModified: Date?, isSystemDatabase: Bool) {
        self.service = service; self.client = client; self.allowed = allowed; self.lastModified = lastModified; self.isSystemDatabase = isSystemDatabase
    }

    /// `kTCCServiceCamera` → `Camera`; known services get friendlier names.
    public var serviceTitle: String {
        let stripped = service.hasPrefix("kTCCService") ? String(service.dropFirst(11)) : service
        return TCCRow.titles[stripped] ?? stripped
    }
    static let titles: [String: String] = [
        "SystemPolicyAllFiles": "Full Disk Access", "Accessibility": "Accessibility", "ScreenCapture": "Screen Recording",
        "ListenEvent": "Input Monitoring", "AppleEvents": "Automation", "SystemPolicyDocumentsFolder": "Documents Folder",
        "SystemPolicyDesktopFolder": "Desktop Folder", "SystemPolicyDownloadsFolder": "Downloads Folder",
        "SystemPolicyNetworkVolumes": "Network Volumes", "SystemPolicyRemovableVolumes": "Removable Volumes",
        "AddressBook": "Contacts", "Calendar": "Calendars", "Reminders": "Reminders", "Photos": "Photos", "Camera": "Camera",
        "Microphone": "Microphone", "MediaLibrary": "Media Library", "SpeechRecognition": "Speech Recognition",
        "BluetoothAlways": "Bluetooth", "DeveloperTool": "Developer Tools", "PostEvent": "Post Events", "Willow": "HomeKit",
        "Ubiquity": "iCloud", "SystemPolicySysAdminFiles": "Administrator Files", "FileProviderDomain": "File Provider",
        "FileProviderPresence": "File Provider Presence", "UserAvailability": "Focus Status", "AudioCapture": "Audio Capture",
        "Motion": "Motion", "FocusStatus": "Focus Status", "Siri": "Siri", "SystemPolicyAppBundles": "App Management",
        "ScreenCaptureAccess": "Screen Recording", "Facebook": "Facebook", "Twitter": "Twitter", "LinkedIn": "LinkedIn",
    ]
    /// Argument for `tccutil reset`.
    public var tccutilService: String { service.hasPrefix("kTCCService") ? String(service.dropFirst(11)) : service }
}

public struct KeychainItem: Sendable, Hashable {
    public let itemClass: String       // genp | inet
    public let service: String?
    public let account: String?
    public let label: String?
    public let accessGroup: String?
    public let server: String?
    public let persistentRef: Data?
    public init(itemClass: String, service: String?, account: String?, label: String?, accessGroup: String?, server: String?, persistentRef: Data?) {
        self.itemClass = itemClass; self.service = service; self.account = account; self.label = label
        self.accessGroup = accessGroup; self.server = server; self.persistentRef = persistentRef
    }
    public var displayName: String { label ?? service ?? server ?? account ?? "Keychain item" }
}

/// Reads the real system state.
public struct SystemRegistrationReader: RegistrationReader {
    public init() {}

    public func launchServicesHandlers() -> [[String: String]] {
        let domain = "com.apple.LaunchServices/com.apple.launchservices.secure" as CFString
        CFPreferencesAppSynchronize(domain)
        let raw = (CFPreferencesCopyAppValue("LSHandlers" as CFString, domain) as? [[String: Any]]) ?? []
        return raw.map { $0.compactMapValues { $0 as? String } }
    }

    public func dockTiles() -> [(index: Int, path: String)] {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        let apps = (CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) as? [[String: Any]]) ?? []
        return apps.enumerated().compactMap { index, tile in
            guard let data = tile["tile-data"] as? [String: Any], let file = data["file-data"] as? [String: Any],
                  let urlString = file["_CFURLString"] as? String, let url = URL(string: urlString) else { return nil }
            return (index, url.standardizedFileURL.path)
        }
    }

    public func notificationCenterApps() -> [String] {
        let domain = "com.apple.ncprefs" as CFString
        CFPreferencesAppSynchronize(domain)
        let apps = (CFPreferencesCopyAppValue("apps" as CFString, domain) as? [[String: Any]]) ?? []
        return apps.compactMap { $0["bundle-id"] as? String }
    }

    public func tccRows() -> [TCCRow] {
        let user = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/com.apple.TCC/TCC.db").path
        return Self.readTCC(at: user, system: false)
    }

    public static func readTCC(at path: String, system: Bool) -> [TCCRow] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT service, client, auth_value, last_modified FROM access"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [TCCRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let serviceC = sqlite3_column_text(statement, 0), let clientC = sqlite3_column_text(statement, 1) else { continue }
            let auth = sqlite3_column_int(statement, 2)
            let modified = sqlite3_column_double(statement, 3)
            rows.append(TCCRow(service: String(cString: serviceC), client: String(cString: clientC), allowed: auth == 2 || auth == 3,
                               lastModified: modified > 0 ? Date(timeIntervalSince1970: modified) : nil, isSystemDatabase: system))
        }
        return rows
    }

    public func keychainItems() -> [KeychainItem] {
        var items: [KeychainItem] = []
        for (cls, name) in [(kSecClassGenericPassword, "genp"), (kSecClassInternetPassword, "inet")] {
            let query: [String: Any] = [
                kSecClass as String: cls,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
                kSecReturnPersistentRef as String: true,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let array = result as? [[String: Any]] else { continue }
            for attributes in array {
                items.append(KeychainItem(
                    itemClass: name,
                    service: attributes[kSecAttrService as String] as? String,
                    account: attributes[kSecAttrAccount as String] as? String,
                    label: attributes[kSecAttrLabel as String] as? String,
                    accessGroup: attributes[kSecAttrAccessGroup as String] as? String,
                    server: attributes[kSecAttrServer as String] as? String,
                    persistentRef: attributes[kSecValuePersistentRef as String] as? Data
                ))
            }
        }
        return items
    }

    public func launchdJobs() -> [(label: String, pid: Int?)] {
        guard let output = Self.run("/bin/launchctl", ["list"]) else { return [] }
        return output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { return nil }
            return (String(parts[2]), Int(parts[0]))
        }
    }

    public func firewallApps() -> [String] {
        guard let output = Self.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--listapps"]) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":"), trimmed.first?.isNumber == true else { return nil }
            return trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }

    static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Runs a tool and returns its exit status and both outputs (drained concurrently), for callers that must know
    /// whether it worked.
    public static func runChecked(_ executable: String, _ arguments: [String]) -> ToolResult {
        HelperCore.run(executable: executable, arguments: arguments)
    }
}

/// How a Launch Services handler entry is identified: by what it handles and which app it points at, never by its
/// position in the array (positions shift as soon as one entry is removed).
public enum LaunchServicesHandlerPayload {
    static let keys = ["LSHandlerURLScheme", "LSHandlerContentType", "LSHandlerContentTag"]

    /// Payload for the handler entry, or nil when it has no subject.
    public static func payload(for handler: [String: String], role: String) -> [String: String]? {
        guard let key = keys.first(where: { handler[$0] != nil }), let value = handler[key] else { return nil }
        let subject = switch key {
        case "LSHandlerURLScheme": "URL scheme \(value)://"
        case "LSHandlerContentType": "file type \(value)"
        default: "extension .\(value)"
        }
        return ["type": "lsHandler", "subject": subject, "role": role, "matchKey": key, "matchValue": value]
    }

    public static func id(_ payload: [String: String]) -> String {
        "registration:ls:\(payload["matchKey"] ?? ""):\(payload["matchValue"] ?? ""):\(payload["role"] ?? "")"
    }

    /// True when the stored entry is the one the payload describes.
    static func matches(_ handler: [String: Any], _ payload: [String: String]) -> Bool {
        guard let key = payload["matchKey"], let value = payload["matchValue"], let role = payload["role"]?.lowercased(),
              (handler[key] as? String)?.lowercased() == value.lowercased() else { return false }
        return handler.contains { $0.key.hasPrefix("LSHandlerRole") && ($0.value as? String)?.lowercased() == role }
    }
}

/// Finds non-file traces of an app. Each result is a `.registration` item whose payload tells the remover what to undo.
public struct RegistrationScanner: Sendable {
    public let reader: RegistrationReader
    public init(reader: RegistrationReader = SystemRegistrationReader()) { self.reader = reader }

    public static let groupPermissions = "Permissions"
    public static let groupKeychain = "Keychain"
    public static let groupLaunchServices = "Launch Services"
    public static let groupDock = "Dock"
    public static let groupNotifications = "Notifications"
    public static let groupRunningJobs = "Running Jobs"
    public static let groupFirewall = "Firewall"

    public func scan(identity: AppIdentity, appPath: String, shared: SharedIdentifiers) -> [ScanItem] {
        var items: [ScanItem] = []
        let ids = Set(([identity.bundleID] + Array(identity.subBundleIDs) + Array(identity.extensionIDs)).map { $0.lowercased() })
        func owns(_ bundleID: String) -> Bool {
            let lower = bundleID.lowercased()
            return ids.contains(lower) || lower.hasPrefix(identity.bundleID.lowercased() + ".")
        }

        // Launch Services handlers (URL schemes, content types).
        var seenHandlers: Set<String> = []
        for handler in reader.launchServicesHandlers() {
            let roles = handler.filter { $0.key.hasPrefix("LSHandlerRole") }
            guard let role = roles.values.first(where: owns), let payload = LaunchServicesHandlerPayload.payload(for: handler, role: role) else { continue }
            let id = LaunchServicesHandlerPayload.id(payload)
            guard seenHandlers.insert(id).inserted else { continue }
            items.append(ScanItem(id: id, title: "Default handler for \(payload["subject"] ?? "a file type")",
                                  subtitle: "Launch Services → \(role)", kind: .registration, group: Self.groupLaunchServices,
                                  tier: .safe, matchedBy: ["Launch Services handler"], payload: payload))
        }

        // Dock tiles.
        for tile in reader.dockTiles() where tile.path == appPath || tile.path.hasPrefix(appPath + "/") {
            items.append(ScanItem(id: "registration:dock:\(tile.index)", title: "Dock tile", subtitle: tile.path, kind: .registration,
                                  group: Self.groupDock, tier: .safe, matchedBy: ["Dock tile points at the app"],
                                  payload: ["type": "dockTile", "path": tile.path]))
        }

        // Notification Center registration.
        for bundleID in reader.notificationCenterApps() where owns(bundleID) {
            items.append(ScanItem(id: "registration:nc:\(bundleID)", title: "Notification settings for \(bundleID)", subtitle: "Notification Center",
                                  kind: .registration, group: Self.groupNotifications, tier: .safe, matchedBy: ["Notification Center registration"],
                                  payload: ["type": "notificationCenter", "bundleID": bundleID]))
        }

        // TCC permissions.
        for row in reader.tccRows() where owns(row.client) {
            items.append(ScanItem(id: "registration:tcc:\(row.service):\(row.client)", title: row.serviceTitle,
                                  subtitle: (row.allowed ? "Allowed" : "Denied") + " · \(row.client)" + (row.isSystemDatabase ? " · system" : ""),
                                  kind: .registration, group: Self.groupPermissions, tier: .normal, matchedBy: ["TCC permission"],
                                  needsRoot: row.isSystemDatabase, modificationDate: row.lastModified,
                                  payload: ["type": "tcc", "service": row.tccutilService, "bundleID": row.client, "allowed": row.allowed ? "1" : "0"]))
        }

        // Keychain items.
        let names = identity.normalizedNames.filter { $0.count >= 5 && !shared.isGenericName($0) }
        let team = identity.teamID?.lowercased()
        for item in reader.keychainItems() {
            let haystacks = [item.service, item.label, item.accessGroup, item.server].compactMap { $0?.lowercased() }
            var reason: String?
            if haystacks.contains(where: { h in ids.contains(where: { h == $0 || h.hasPrefix($0 + ".") || h.hasSuffix("." + $0) }) }) { reason = "keychain item references the bundle ID" }
            else if let team, haystacks.contains(where: { $0.hasPrefix(team + ".") }) { reason = "keychain access group of the team" }
            else if haystacks.contains(where: { h in
                guard h.hasSuffix(" safe storage") else { return false }
                let product = NameMatcher.normalize(h.replacingOccurrences(of: " safe storage", with: ""))
                return product.count >= 4 && names.contains { $0 == product || $0.hasPrefix(product) || product.hasPrefix($0) }
            }) { reason = "Electron/Chromium \"Safe Storage\" entry" }
            else if haystacks.contains(where: { h in names.contains(NameMatcher.normalize(h)) }) { reason = "keychain item named after the app" }
            guard let reason else { continue }
            var payload = ["type": "keychain", "class": item.itemClass]
            if let ref = item.persistentRef { payload["ref"] = ref.base64EncodedString() }
            items.append(ScanItem(id: "registration:keychain:\(item.itemClass):\(item.service ?? "")\(item.server ?? ""):\(item.account ?? "")",
                                  title: item.displayName, subtitle: [item.account, item.service, item.accessGroup].compactMap { $0 }.joined(separator: " · "),
                                  kind: .registration, group: Self.groupKeychain, tier: .caution, matchedBy: [reason], payload: payload))
        }

        // Loaded launchd jobs for the app's labels.
        let labels = Set(identity.launchdLabels.map { $0.lowercased() })
        for job in reader.launchdJobs() {
            let lower = job.label.lowercased()
            guard labels.contains(lower) || owns(job.label) else { continue }
            items.append(ScanItem(id: "registration:launchd:\(job.label)", title: job.label,
                                  subtitle: job.pid.map { "Running, pid \($0)" } ?? "Loaded", kind: .registration, group: Self.groupRunningJobs,
                                  tier: .normal, matchedBy: ["launchd job label"], payload: ["type": "launchdJob", "label": job.label]))
        }

        // Application Firewall allow-list.
        for path in reader.firewallApps() where path == appPath || path.hasPrefix(appPath + "/") {
            items.append(ScanItem(id: "registration:firewall:\(path)", title: "Firewall rule", subtitle: path, kind: .registration,
                                  group: Self.groupFirewall, tier: .safe, matchedBy: ["firewall allow-list entry"], needsRoot: true,
                                  payload: ["type": "firewall", "path": path]))
        }
        return items
    }
}

/// Undoes registrations found by `RegistrationScanner`. Returns an error description, or nil on success.
public struct RegistrationRemover: Sendable {
    public var runAsRoot: (@Sendable (String, [String]) async -> (Int32, String, String))?
    public init(runAsRoot: (@Sendable (String, [String]) async -> (Int32, String, String))? = nil) { self.runAsRoot = runAsRoot }

    public func remove(_ item: ScanItem) async -> String? {
        if FileRemover.isDryRun { return nil }
        switch item.payload["type"] {
        case "lsHandler":
            let domain = "com.apple.LaunchServices/com.apple.launchservices.secure" as CFString
            guard var handlers = CFPreferencesCopyAppValue("LSHandlers" as CFString, domain) as? [[String: Any]] else { return nil }
            guard item.payload["matchKey"] != nil else { return "Rescan before removing this handler." }   // payload from an older scan
            let before = handlers.count
            handlers.removeAll { LaunchServicesHandlerPayload.matches($0, item.payload) }
            guard handlers.count != before else { return nil }   // already gone
            CFPreferencesSetAppValue("LSHandlers" as CFString, handlers as CFArray, domain)
            return CFPreferencesAppSynchronize(domain) ? nil : "Could not write Launch Services preferences."
        case "dockTile":
            let domain = "com.apple.dock" as CFString
            guard var apps = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) as? [[String: Any]] else { return "Dock preferences unreadable." }
            let target = item.payload["path"] ?? ""
            apps.removeAll { tile in
                guard let data = tile["tile-data"] as? [String: Any], let file = data["file-data"] as? [String: Any],
                      let urlString = file["_CFURLString"] as? String, let url = URL(string: urlString) else { return false }
                return url.standardizedFileURL.path == target
            }
            CFPreferencesSetAppValue("persistent-apps" as CFString, apps as CFArray, domain)
            guard CFPreferencesAppSynchronize(domain) else { return "Could not write Dock preferences." }
            _ = SystemRegistrationReader.run("/usr/bin/killall", ["Dock"])
            return nil
        case "notificationCenter":
            let domain = "com.apple.ncprefs" as CFString
            guard var apps = CFPreferencesCopyAppValue("apps" as CFString, domain) as? [[String: Any]] else { return "Notification preferences unreadable." }
            apps.removeAll { ($0["bundle-id"] as? String) == item.payload["bundleID"] }
            CFPreferencesSetAppValue("apps" as CFString, apps as CFArray, domain)
            return CFPreferencesAppSynchronize(domain) ? nil : "Could not write Notification Center preferences."
        case "tcc":
            let service = item.payload["service"] ?? "All"
            let bundleID = item.payload["bundleID"] ?? ""
            if item.needsRoot {
                guard let runAsRoot else { return "Administrator privileges are required to reset this permission." }
                let (status, _, err) = await runAsRoot("tccutil", ["reset", service, bundleID])
                return status == 0 ? nil : (err.isEmpty ? "tccutil failed (\(status))" : err)
            }
            let result = SystemRegistrationReader.runChecked("/usr/bin/tccutil", ["reset", service, bundleID])
            return result.status == 0 ? nil : (result.stderr.isEmpty ? "tccutil failed (\(result.status))" : result.stderr)
        case "keychain":
            guard let refString = item.payload["ref"], let ref = Data(base64Encoded: refString) else { return "Keychain reference missing." }
            let status = SecItemDelete([kSecValuePersistentRef as String: ref] as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound ? nil : (SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
        case "launchdJob":
            // Stops the job; the plist itself is removed with the app's files. No `disable`, which would outlive a reinstall.
            let label = item.payload["label"] ?? ""
            let result = SystemRegistrationReader.runChecked("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            // 3 = no such process, 113 = not loaded: already stopped.
            return [0, 3, 113].contains(result.status) ? nil : (result.stderr.isEmpty ? "launchctl bootout failed (\(result.status))" : result.stderr)
        case "purge":
            do {
                let report = try PurgeableReclaimer.reclaim(mount: item.payload["mount"] ?? "/")
                NSLog("CleanOS purge: wrote \(report.written.formattedBytes) in \(Int(report.duration))s; purgeable \(report.purgeableBefore.formattedBytes) → \(report.purgeableAfter.formattedBytes); available \(report.availableBefore.formattedBytes) → \(report.availableAfter.formattedBytes)")
                return nil
            } catch {
                return error.localizedDescription
            }
        case "snapshot":
            guard let runAsRoot else { return "Administrator privileges are required to delete snapshots." }
            let (status, _, err) = await runAsRoot("tmutil", ["deletelocalsnapshots", item.payload["date"] ?? ""])
            return status == 0 ? nil : (err.isEmpty ? "tmutil failed (\(status))" : err)
        case "spotlightIndex":
            guard let runAsRoot else { return "Administrator privileges are required to rebuild the Spotlight index." }
            // Erase and rebuild: indexing stays on, so search on that disk keeps working once it finishes.
            let (status, _, err) = await runAsRoot("mdutil", ["-E", item.payload["mount"] ?? ""])
            return status == 0 ? nil : (err.isEmpty ? "mdutil failed (\(status))" : err)
        case "pkgReceipt":
            guard let runAsRoot else { return "Administrator privileges are required to forget a package receipt." }
            let (status, _, err) = await runAsRoot("pkgutil", ["--forget", item.payload["identifier"] ?? ""])
            return status == 0 ? nil : (err.isEmpty ? "pkgutil failed (\(status))" : err)
        case "pluginkit":
            guard let path = item.payload["path"], !path.isEmpty else { return nil }
            let result = SystemRegistrationReader.runChecked("/usr/bin/pluginkit", ["-r", path])
            return result.status == 0 ? nil : (result.stderr.isEmpty ? "pluginkit could not unregister it (\(result.status))" : result.stderr)
        case "finderEmptyTrash":
            let result = SystemRegistrationReader.runChecked("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])
            return result.status == 0 ? nil : (result.stderr.isEmpty ? "Finder could not empty the Trash (\(result.status))." : result.stderr)
        case "fseventsd":
            let dir = URL(filePath: item.payload["mount"] ?? "").appending(path: ".fseventsd")
            do {
                // Only the event log is deleted; macOS starts a new one. (Writing `no_log` would switch logging off for good.)
                for child in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                    where !["no_log", "fseventsd-uuid"].contains(child.lastPathComponent) {
                    try FileManager.default.removeItem(at: child)
                }
                return nil
            } catch { return error.localizedDescription }
        case "firewall":
            guard let runAsRoot else { return "Administrator privileges are required to change the firewall." }
            let (status, _, err) = await runAsRoot("socketfilterfw", ["--remove", item.payload["path"] ?? ""])
            return status == 0 ? nil : (err.isEmpty ? "socketfilterfw failed (\(status))" : err)
        default:
            return "Not removed automatically; review it manually."
        }
    }
}
