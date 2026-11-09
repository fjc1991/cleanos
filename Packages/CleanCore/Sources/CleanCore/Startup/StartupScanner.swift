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

    /// Classic login items can only be removed (macOS has no "disabled" state for them), so they get no switch.
    public var canToggle: Bool { !managedBySystemSettings && kind != .userLoginItem }
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
                // `launchctl list` only shows the caller's own domain; system daemons are asked for one by one.
                var pid = loaded[label] ?? nil
                var isLoaded = loaded[label] != nil
                if kind == .systemDaemon {
                    let printed = SystemRegistrationReader.runChecked("/bin/launchctl", ["print", "system/\(label)"])
                    isLoaded = printed.status == 0
                    pid = Self.parsePrintedPID(printed.stdout)
                }
                items.append(StartupItem(
                    id: url.path, label: label, title: app?.name ?? Self.title(for: label, program: program), kind: kind, plistURL: url,
                    programPath: program, ownerAppURL: app?.url, ownerName: app?.name,
                    isEnabled: !(disabledSet.contains(label) || explicitlyDisabled), isLoaded: isLoaded, pid: pid,
                    managedBySystemSettings: false, needsRoot: kind == .systemDaemon || !FileRemover.isUserRemovable(url), detail: program))
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

    /// `pid = 123` from `launchctl print`.
    static func parsePrintedPID(_ output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = ") { return Int(trimmed.dropFirst("pid = ".count)) }
        }
        return nil
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
        // One "name<TAB>path" line per item, so names containing commas survive.
        let script = """
        set out to ""
        tell application "System Events"
            repeat with i in every login item
                set out to out & (name of i) & tab & (path of i) & linefeed
            end repeat
        end tell
        return out
        """
        let result = SystemRegistrationReader.runChecked("/usr/bin/osascript", ["-e", script])
        guard result.status == 0 else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return parts.count == 2 && !parts[0].isEmpty ? ClassicLoginItem(name: parts[0], path: parts[1]) : nil
        }
    }
}

/// Enables or disables startup items.
public struct StartupController: Sendable {
    public var runAsRoot: (@Sendable (String, [String]) async -> (Int32, String, String))?
    public init(runAsRoot: (@Sendable (String, [String]) async -> (Int32, String, String))? = nil) { self.runAsRoot = runAsRoot }

    /// launchctl exit codes that mean "already in that state" (no such process / not loaded / already loaded).
    static let harmless: Set<Int32> = [0, 3, 5, 37, 113]

    private func launchctl(_ arguments: [String], root: Bool) async -> (Int32, String) {
        if root {
            guard let runAsRoot else { return (-1, "Needs administrator rights.") }
            let (status, _, err) = await runAsRoot("launchctl", arguments)
            return (status, err)
        }
        let result = SystemRegistrationReader.runChecked("/bin/launchctl", arguments)
        return (result.status, result.stderr)
    }

    private static func message(_ verb: String, _ status: Int32, _ stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "launchctl \(verb) failed (\(status))." : text
    }

    /// Stops a job before its plist is removed. Unlike disabling, this leaves no override behind, so a reinstalled app's
    /// job with the same label starts normally.
    public func stop(_ item: StartupItem) async -> String? {
        if FileRemover.isDryRun { return nil }
        switch item.kind {
        case .launchAgent, .systemAgent:
            let target = "gui/\(getuid())/\(item.label)"
            let (status, err) = await launchctl(["bootout", target], root: false)
            _ = await launchctl(["enable", target], root: false)
            return Self.harmless.contains(status) ? nil : Self.message("bootout", status, err)
        case .systemDaemon:
            let (status, err) = await launchctl(["bootout", "system/\(item.label)"], root: true)
            _ = await launchctl(["enable", "system/\(item.label)"], root: true)
            return Self.harmless.contains(status) ? nil : Self.message("bootout", status, err)
        case .userLoginItem, .appLoginItem:
            return nil
        }
    }

    /// Returns an error description, or nil on success.
    public func setEnabled(_ item: StartupItem, _ enabled: Bool) async -> String? {
        if FileRemover.isDryRun { return nil }
        switch item.kind {
        case .launchAgent, .systemAgent, .systemDaemon:
            let root = item.kind == .systemDaemon
            let domain = root ? "system" : "gui/\(getuid())"
            let target = "\(domain)/\(item.label)"
            if enabled {
                let (status, err) = await launchctl(["enable", target], root: root)
                guard status == 0 else { return Self.message("enable", status, err) }
                if let plist = item.plistURL {
                    let (status, err) = await launchctl(["bootstrap", domain, plist.path], root: root)
                    guard Self.harmless.contains(status) else { return Self.message("bootstrap", status, err) }
                }
            } else {
                let (status, err) = await launchctl(["disable", target], root: root)
                guard status == 0 else { return Self.message("disable", status, err) }
                let (stopStatus, stopErr) = await launchctl(["bootout", target], root: root)
                guard Self.harmless.contains(stopStatus) else { return Self.message("bootout", stopStatus, stopErr) }
            }
            return nil
        case .userLoginItem:
            guard let path = item.programPath else { return "Unknown login item path." }
            func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            let script = enabled
                ? "tell application \"System Events\" to make login item at end with properties {path:\(quoted(path)), hidden:false}"
                : "tell application \"System Events\" to delete login item \(quoted(item.label))"
            let result = SystemRegistrationReader.runChecked("/usr/bin/osascript", ["-e", script])
            return result.status == 0 ? nil : (result.stderr.isEmpty ? "System Events refused (\(result.status))." : result.stderr)
        case .appLoginItem:
            return "Managed in System Settings → General → Login Items & Extensions."
        }
    }
}
