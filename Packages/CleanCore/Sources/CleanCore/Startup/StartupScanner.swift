import Foundation

/// Where a startup item comes from.
public enum StartupKind: String, Codable, Sendable, CaseIterable {
    case userLoginItem = "User Login Item"
    case appLoginItem = "Application Login Item"
    case launchAgent = "Launch Agent"
    case systemAgent = "System Launch Agent"
    case systemDaemon = "System Daemon"

    public var isSystemDomain: Bool { self == .systemDaemon }
}

/// One program that runs at login or boot.
public struct StartupItem: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var label: String
    public var title: String
    public var kind: StartupKind
    public var plistURL: URL?
    public var programPath: String?
    public var ownerAppURL: URL?
    public var ownerName: String?
    public var isEnabled: Bool
    public var isLoaded: Bool
    public var pid: Int?
    /// Items registered through `SMAppService`/BTM can only be toggled in System Settings.
    public var managedBySystemSettings: Bool
    public var needsRoot: Bool
    public var detail: String?

    public var canToggle: Bool { !managedBySystemSettings }
}

/// Enumerates launchd agents/daemons, app-bundled login items and classic login items.
public actor StartupScanner {
    private let home: String
    public init(home: String = NSHomeDirectory()) { self.home = home }

    public func scan(installedApps: [InstalledApp]) async -> [StartupItem] {
        let loaded = Self.parseLaunchctlList(SystemRegistrationReader.run("/bin/launchctl", ["list"]) ?? "")
        let disabledUser = Self.parseDisabled(SystemRegistrationReader.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"]) ?? "")
        let disabledSystem = Self.parseDisabled(SystemRegistrationReader.run("/bin/launchctl", ["print-disabled", "system"]) ?? "")
        var items: [StartupItem] = []

        func owner(of program: String?, label: String) -> InstalledApp? {
            if let program, let app = installedApps.first(where: { program.hasPrefix($0.url.path + "/") }) { return app }
            return installedApps.first { app in
                let id = app.bundleID.lowercased()
                return label.lowercased() == id || label.lowercased().hasPrefix(id + ".") || app.identity.launchdLabels.contains(label)
                    || app.identity.subBundleIDs.contains { label.lowercased().hasPrefix($0.lowercased()) }
            }
        }

        for (dir, kind) in [(home + "/Library/LaunchAgents", StartupKind.launchAgent), ("/Library/LaunchAgents", .systemAgent), ("/Library/LaunchDaemons", .systemDaemon)] {
            for url in (try? FileManager.default.contentsOfDirectory(at: URL(filePath: dir), includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: url),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                let label = plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
                let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
                let disabledSet = kind == .systemDaemon ? disabledSystem : disabledUser
                let explicitlyDisabled = plist["Disabled"] as? Bool ?? false
                let app = owner(of: program, label: label)
                items.append(StartupItem(
                    id: url.path, label: label, title: app?.name ?? Self.title(for: label, program: program), kind: kind, plistURL: url,
                    programPath: program, ownerAppURL: app?.url, ownerName: app?.name,
                    isEnabled: !(disabledSet.contains(label) || explicitlyDisabled), isLoaded: loaded[label] != nil, pid: loaded[label] ?? nil,
                    managedBySystemSettings: false, needsRoot: kind == .systemDaemon, detail: program))
            }
        }

        // Login items bundled in apps (SMAppService / legacy LoginItems).
        for app in installedApps {
            let dir = app.url.appending(path: "Contents/Library/LoginItems")
            for bundle in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where bundle.pathExtension == "app" {
                guard let info = AppInspector.infoPlist(at: bundle), let id = info["CFBundleIdentifier"] as? String else { continue }
                items.append(StartupItem(id: bundle.path, label: id, title: app.name, kind: .appLoginItem, plistURL: nil, programPath: bundle.path,
                                         ownerAppURL: app.url, ownerName: app.name, isEnabled: loaded[id] != nil, isLoaded: loaded[id] != nil,
                                         pid: loaded[id] ?? nil, managedBySystemSettings: true, needsRoot: false,
                                         detail: info["CFBundleName"] as? String ?? bundle.lastPathComponent))
            }
        }

        // Classic login items (System Settings → General → Login Items → Open at Login).
        for entry in Self.classicLoginItems() {
            let app = installedApps.first { $0.url.standardizedFileURL.path == entry.path }
            items.append(StartupItem(id: "loginitem:\(entry.name)", label: entry.name, title: entry.name, kind: .userLoginItem, plistURL: nil,
                                     programPath: entry.path, ownerAppURL: app?.url ?? URL(filePath: entry.path), ownerName: app?.name,
                                     isEnabled: true, isLoaded: true, pid: nil, managedBySystemSettings: false, needsRoot: false, detail: entry.path))
        }

        return items.sorted { ($0.title.lowercased(), $0.kind.rawValue) < ($1.title.lowercased(), $1.kind.rawValue) }
    }

    // MARK: Parsing

    /// `launchctl list` → label → pid (nil when not running).
    static func parseLaunchctlList(_ output: String) -> [String: Int?] {
        var result: [String: Int?] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            result[String(parts[2])] = Int(parts[0])
        }
        return result
    }

    /// `launchctl print-disabled` → labels marked disabled.
    static func parseDisabled(_ output: String) -> Set<String> {
        var disabled: Set<String> = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix("=> disabled") || trimmed.hasSuffix("=> true"), let quoteStart = trimmed.firstIndex(of: "\""),
                  let quoteEnd = trimmed[trimmed.index(after: quoteStart)...].firstIndex(of: "\"") else { continue }
            disabled.insert(String(trimmed[trimmed.index(after: quoteStart)..<quoteEnd]))
        }
        return disabled
    }

    static func title(for label: String, program: String?) -> String {
        if let program {
            let url = URL(filePath: program)
            if let appRange = program.range(of: ".app/") {
                return URL(filePath: String(program[..<appRange.lowerBound])).lastPathComponent
            }
            return url.lastPathComponent
        }
        return label
    }

    struct ClassicLoginItem { let name: String; let path: String }

    static func classicLoginItems() -> [ClassicLoginItem] {
        let script = "tell application \"System Events\" to get {name, path} of every login item"
        guard let output = SystemRegistrationReader.run("/usr/bin/osascript", ["-e", script]), !output.isEmpty, !output.contains("error") else { return [] }
        // Output: name1, name2, /path1, /path2  (two lists flattened)
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ", ").map(String.init)
        let count = parts.count / 2
        guard count > 0, parts.count == count * 2 else { return [] }
        return (0..<count).map { ClassicLoginItem(name: parts[$0], path: parts[count + $0]) }
    }
}

/// Enables or disables startup items.
public struct StartupController: Sendable {
    public var runAsRoot: (@Sendable (String, [String]) async -> (Int32, String, String))?
    public init(runAsRoot: (@Sendable (String, [String]) async -> (Int32, String, String))? = nil) { self.runAsRoot = runAsRoot }

    /// Returns an error description, or nil on success.
    public func setEnabled(_ item: StartupItem, _ enabled: Bool) async -> String? {
        if FileRemover.isDryRun { return nil }
        switch item.kind {
        case .launchAgent, .systemAgent:
            let domain = "gui/\(getuid())"
            if enabled {
                _ = SystemRegistrationReader.run("/bin/launchctl", ["enable", "\(domain)/\(item.label)"])
                if let plist = item.plistURL { _ = SystemRegistrationReader.run("/bin/launchctl", ["bootstrap", domain, plist.path]) }
            } else {
                _ = SystemRegistrationReader.run("/bin/launchctl", ["bootout", "\(domain)/\(item.label)"])
                _ = SystemRegistrationReader.run("/bin/launchctl", ["disable", "\(domain)/\(item.label)"])
            }
            return nil
        case .systemDaemon:
            guard let runAsRoot else { return "Administrator privileges are required to change system daemons." }
            if enabled {
                _ = await runAsRoot("launchctl", ["enable", "system/\(item.label)"])
                if let plist = item.plistURL { _ = await runAsRoot("launchctl", ["bootstrap", "system", plist.path]) }
            } else {
                _ = await runAsRoot("launchctl", ["bootout", "system/\(item.label)"])
                let (status, _, err) = await runAsRoot("launchctl", ["disable", "system/\(item.label)"])
                if status != 0 { return err.isEmpty ? "launchctl failed (\(status))" : err }
            }
            return nil
        case .userLoginItem:
            guard let path = item.programPath else { return "Unknown login item path." }
            let script = enabled
                ? "tell application \"System Events\" to make login item at end with properties {path:\"\(path)\", hidden:false}"
                : "tell application \"System Events\" to delete login item \"\(item.label)\""
            let output = SystemRegistrationReader.run("/usr/bin/osascript", ["-e", script]) ?? ""
            return output.contains("error") ? output : nil
        case .appLoginItem:
            return "Managed in System Settings → General → Login Items & Extensions."
        }
    }
}
