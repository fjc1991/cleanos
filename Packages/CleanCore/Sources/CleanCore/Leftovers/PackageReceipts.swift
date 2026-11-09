import Foundation

/// Reads installer package receipts (`pkgutil`).
public enum PackageReceipts {
    public struct Receipt: Sendable, Hashable {
        public let identifier: String
        public let version: String?
        public let installDate: Date?
        public let volume: String
        public let location: String
        public var base: URL { URL(filePath: volume).appending(path: location) }
    }

    /// All non-Apple receipt identifiers on the startup volume.
    public static func identifiers() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/private/var/db/receipts") else { return [] }
        return entries.filter { $0.hasSuffix(".plist") }.map { String($0.dropLast(6)) }.filter { !$0.lowercased().hasPrefix("com.apple.") }.sorted()
    }

    public static func info(_ identifier: String) -> Receipt? {
        guard let output = run(["--pkg-info", identifier]) else { return nil }
        var version: String?
        var volume = "/"
        var location = ""
        var date: Date?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "version": version = parts[1]
            case "volume": volume = parts[1].isEmpty ? "/" : parts[1]
            case "location": location = parts[1]
            case "install-time": if let seconds = TimeInterval(parts[1]) { date = Date(timeIntervalSince1970: seconds) }
            default: break
            }
        }
        return Receipt(identifier: identifier, version: version, installDate: date, volume: volume, location: location)
    }

    /// Relative manifest paths of the package.
    public static func manifest(_ identifier: String) -> [String] {
        guard let output = run(["--files", identifier]) else { return [] }
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Full paths from a manifest that are specific to the package (ignoring shared parents such as `/Library/LaunchAgents`),
    /// collapsed to their topmost entries. `exists` says whether each still exists on disk.
    public static func payloadPaths(manifest: [String], base: URL, sharedParents: Set<String> = PackageReceipts.sharedParents) -> [(path: String, exists: Bool)] {
        var paths: [String] = []
        let basePath = base.standardizedFileURL.path
        for relative in manifest {
            let full = base.appending(path: relative).standardizedFileURL.path
            // Never the volume root or the install location itself (a manifest line "." would otherwise yield "/").
            if full == "/" || full == basePath || sharedParents.contains(full) { continue }
            let parent = URL(filePath: full).deletingLastPathComponent().path
            // Keep entries whose parent is a shared system folder (or the base) — these are the package's own roots.
            if sharedParents.contains(parent) || parent == basePath || parent == "/" {
                paths.append(full)
            }
        }
        var sorted = Array(Set(paths)).sorted()
        sorted = sorted.filter { path in !sorted.contains { other in other != path && path.hasPrefix(other + "/") } }
        return sorted.map { ($0, FileManager.default.fileExists(atPath: $0)) }
    }

    /// The existing payload paths that belong to the package alone, safe to offer for removal: never a shared parent, never the
    /// install location, and never a folder that also holds files the manifest does not list (another package's, or the user's).
    /// Such a folder is replaced by its own manifest entries, recursively. Bundles (`.app`, `.framework`…) count as one unit, since
    /// an app that updated itself no longer matches its manifest file for file.
    public static func ownedPayloadPaths(manifest: [String], base: URL, sharedParents: Set<String> = PackageReceipts.sharedParents,
                                         entryLimit: Int = 50_000) -> [String] {
        let manifestSet = Set(manifest.map { base.appending(path: $0).standardizedFileURL.path })
        let basePath = base.standardizedFileURL.path
        var out: [String] = []
        for entry in payloadPaths(manifest: manifest, base: base, sharedParents: sharedParents) where entry.exists {
            collectOwned(entry.path, manifest: manifestSet, basePath: basePath, sharedParents: sharedParents, entryLimit: entryLimit, into: &out)
        }
        return out
    }

    private static func collectOwned(_ path: String, manifest: Set<String>, basePath: String, sharedParents: Set<String>,
                                     entryLimit: Int, into out: inout [String]) {
        guard path != "/", path != basePath, !sharedParents.contains(path), manifest.contains(path) else { return }
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        if !isDirectory || NameMatcher.bundleExtensions.contains((path as NSString).pathExtension.lowercased()) {
            out.append(path)
            return
        }
        switch coverage(of: path, manifest: manifest, entryLimit: entryLimit) {
        case .covered:
            out.append(path)
        case .partial:
            let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for child in children.sorted() {
                collectOwned(path + "/" + child, manifest: manifest, basePath: basePath, sharedParents: sharedParents, entryLimit: entryLimit, into: &out)
            }
        case .tooLarge:
            break   // Cannot be verified cheaply: leave it alone.
        }
    }

    private enum Coverage { case covered, partial, tooLarge }

    /// Whether every item below `path` is listed in the manifest (Finder's `.DS_Store` and `.localized` aside).
    private static func coverage(of path: String, manifest: Set<String>, entryLimit: Int) -> Coverage {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return .partial }
        var count = 0
        while let relative = enumerator.nextObject() as? String {
            count += 1
            if count > entryLimit { return .tooLarge }
            let name = (relative as NSString).lastPathComponent
            if name == ".DS_Store" || name == ".localized" { continue }
            if !manifest.contains(path + "/" + relative) { return .partial }
        }
        return .covered
    }

    /// Folders many packages write into; their presence says nothing about one package.
    public static let sharedParents: Set<String> = {
        var set: Set<String> = [
            "/Library", "/Library/Application Support", "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools",
            "/Library/Preferences", "/Library/Caches", "/Library/Logs", "/Library/Frameworks", "/Library/Extensions", "/Library/Internet Plug-Ins",
            "/Library/PreferencePanes", "/Library/QuickLook", "/Library/Spotlight", "/Library/Audio", "/Library/Audio/Plug-Ins", "/Library/Audio/Plug-Ins/HAL",
            "/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/VST", "/Library/Audio/Plug-Ins/VST3", "/Library/Audio/Plug-Ins/CLAP",
            "/Library/Audio/Plug-Ins/MIDI Drivers", "/Library/Audio/MIDI Drivers", "/Library/Fonts", "/Library/Filesystems", "/Library/Printers",
            "/Library/Printers/PPDs", "/Library/Printers/PPDs/Contents", "/Library/Printers/PPDs/Contents/Resources", "/Library/Java",
            "/Library/Java/JavaVirtualMachines", "/Library/Java/Extensions",
            "/Library/Google", "/Library/Google/Chrome", "/Library/Google/Chrome/NativeMessagingHosts", "/Library/Application Support/Mozilla",
            "/Library/Application Support/Mozilla/NativeMessagingHosts", "/Library/Application Support/Mozilla/Extensions", "/Library/Application Support/Google",
            "/Library/Application Support/Microsoft", "/Library/Application Support/Adobe", "/Library/Scripts", "/Library/Services", "/Library/Screen Savers",
            "/Library/Input Methods", "/Library/Keyboard Layouts", "/Library/ColorPickers", "/Library/ColorSync", "/Library/ColorSync/Profiles",
            "/Library/Contextual Menu Items", "/Library/Dictionaries", "/Library/Components", "/Library/Widgets", "/Library/Automator", "/Library/CoreImage",
            "/Library/Compositions", "/Library/ScriptingAdditions", "/Library/CoreMediaIO", "/Library/CoreMediaIO/Plug-Ins", "/Library/CoreMediaIO/Plug-Ins/DAL",
            "/Library/Image Capture", "/Library/Image Capture/Devices", "/Library/Image Capture/TWAIN Data Sources", "/Library/Documentation",
            "/Library/Documentation/Help", "/Library/Receipts", "/Library/Updates", "/Library/StartupItems", "/Library/SystemExtensions",
            "/Library/Security", "/Library/Security/SecurityAgentPlugins", "/Library/Keychains", "/Library/Sandbox", "/Library/DriverExtensions",
            "/Library/Perl", "/Library/Python", "/Library/Ruby", "/Library/WebServer", "/Library/Speech", "/Library/Speech/Voices",
            "/Library/Logs/DiagnosticReports", "/Library/Developer",
            "/Applications", "/Applications/Utilities", "/usr", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share",
            "/usr/local", "/usr/local/bin", "/usr/local/lib", "/usr/local/share", "/usr/local/etc",
            "/usr/local/include", "/usr/local/libexec", "/usr/local/sbin", "/usr/local/opt", "/usr/local/var", "/usr/local/Cellar", "/usr/local/Caskroom",
            "/usr/local/lib/pkgconfig", "/usr/local/share/man", "/usr/local/share/doc", "/usr/local/share/info", "/usr/local/share/locale",
            "/usr/local/share/zsh", "/usr/local/share/zsh/site-functions", "/usr/local/share/bash-completion", "/usr/local/share/bash-completion/completions",
            "/usr/local/share/fish", "/usr/local/share/fish/vendor_completions.d", "/usr/local/etc/bash_completion.d", "/usr/local/var/log",
            "/opt", "/opt/homebrew", "/opt/local", "/Users", "/Users/Shared", "/Volumes", "/private", "/private/tmp", "/private/var/tmp", "/private/var/log",
            "/private/etc", "/private/var", "/private/var/db", "/private/etc/paths.d", "/private/etc/manpaths.d", "/private/etc/newsyslog.d",
            "/private/etc/sudoers.d", "/private/etc/pam.d", "/private/etc/resolver", "/private/etc/profile.d",
            "/System", "/System/Library", "/System/Volumes", "/System/Volumes/Data",
        ]
        for section in 1...9 { set.insert("/usr/local/share/man/man\(section)") }
        // `/etc`, `/var` and `/tmp` are symlinks into `/private`; manifests may use either spelling.
        for path in set where path.hasPrefix("/private/") { set.insert(String(path.dropFirst("/private".count))) }
        return set
    }()

    static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/pkgutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
