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
        for relative in manifest {
            let full = base.appending(path: relative).standardizedFileURL.path
            if sharedParents.contains(full) { continue }
            let parent = URL(filePath: full).deletingLastPathComponent().path
            // Keep entries whose parent is a shared system folder (or the base) — these are the package's own roots.
            if sharedParents.contains(parent) || parent == base.standardizedFileURL.path || parent == "/" {
                paths.append(full)
            }
        }
        var sorted = Array(Set(paths)).sorted()
        sorted = sorted.filter { path in !sorted.contains { other in other != path && path.hasPrefix(other + "/") } }
        return sorted.map { ($0, FileManager.default.fileExists(atPath: $0)) }
    }

    /// Folders many packages write into; their presence says nothing about one package.
    public static let sharedParents: Set<String> = [
        "/Library", "/Library/Application Support", "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools",
        "/Library/Preferences", "/Library/Caches", "/Library/Logs", "/Library/Frameworks", "/Library/Extensions", "/Library/Internet Plug-Ins",
        "/Library/PreferencePanes", "/Library/QuickLook", "/Library/Spotlight", "/Library/Audio", "/Library/Audio/Plug-Ins", "/Library/Audio/Plug-Ins/HAL",
        "/Library/Audio/Plug-Ins/Components", "/Library/Fonts", "/Library/Filesystems", "/Library/Printers", "/Library/Java", "/Library/Java/JavaVirtualMachines",
        "/Library/Google", "/Library/Google/Chrome", "/Library/Google/Chrome/NativeMessagingHosts", "/Library/Application Support/Mozilla",
        "/Library/Application Support/Mozilla/NativeMessagingHosts", "/Library/Application Support/Google", "/Library/Application Support/Microsoft",
        "/Library/Application Support/Adobe", "/Library/Scripts", "/Library/Services", "/Library/Screen Savers", "/Library/Input Methods",
        "/Applications", "/Applications/Utilities", "/usr", "/usr/local", "/usr/local/bin", "/usr/local/lib", "/usr/local/share", "/usr/local/etc",
        "/usr/local/include", "/usr/local/libexec", "/usr/local/sbin", "/usr/local/opt", "/usr/local/var", "/opt", "/Users", "/Users/Shared", "/private",
        "/private/etc", "/private/var", "/private/var/db", "/private/etc/paths.d", "/private/etc/manpaths.d", "/System", "/System/Library",
    ]

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
