import Foundation
import Security
import CryptoKit

/// The work the privileged side does, shared by the launchd daemon and the one-shot administrator mode
/// (`com.cleanos.helper --request …`). Everything here validates its input itself: the caller is only trusted
/// to be CleanOS, not to send sensible paths.
public enum HelperCore {
    public static func handle(_ request: HelperRequest) -> HelperResponse {
        switch request {
        case .remove(let items, let uid, let gid):
            return .removed(remove(items, uid: uid_t(uid), gid: gid_t(gid)))
        case .run(let tool, let arguments):
            if let refusal = ToolPolicy.refusal(tool: tool, arguments: arguments) { return .failed(refusal) }
            return .ran(run(executable: ToolPolicy.executables[tool]!, arguments: arguments))
        }
    }

    // MARK: Removal

    public static func remove(_ items: [RootRemovalRequest], uid: uid_t, gid: gid_t) -> [RootRemovalResult] {
        items.map { item in
            let path = ProtectedPaths.canonical(item.path)
            if let reason = ProtectedPaths.refusal(for: path) {
                return RootRemovalResult(path: item.path, error: "Refused: \(reason)", refused: true)
            }
            var info = stat()
            guard lstat(path, &info) == 0 else {
                return errno == ENOENT ? RootRemovalResult(path: item.path)   // already gone
                                       : RootRemovalResult(path: item.path, error: String(cString: strerror(errno)), errorCode: errno)
            }
            do {
                if item.permanently || TrashLocator.isInsideTrash(path) {
                    try FileManager.default.removeItem(atPath: path)
                    return RootRemovalResult(path: item.path)
                }
                let destination = try TrashLocator.trash(path, uid: uid, gid: gid)
                return RootRemovalResult(path: item.path, trashedPath: destination)
            } catch {
                return RootRemovalResult(path: item.path, error: error.localizedDescription, errorCode: posixCode(of: error))
            }
        }
    }

    /// The POSIX errno behind a Foundation error, if there is one.
    public static func posixCode(of error: Error) -> Int32? {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain { return Int32(underlying.code) }
        return nil
    }

    // MARK: Tools

    /// Runs a tool and collects its output. stdout and stderr are drained concurrently, so a tool that fills one
    /// pipe while we wait on the other cannot deadlock.
    public static func run(executable: String, arguments: [String]) -> ToolResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return ToolResult(status: -1, stdout: "", stderr: error.localizedDescription) }
        let group = DispatchGroup()
        nonisolated(unsafe) var stdout = Data(), stderr = Data()
        group.enter()
        DispatchQueue.global().async { stdout = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { stderr = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.wait()
        process.waitUntilExit()
        return ToolResult(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }
}

/// Which root tools may run, and with which arguments. Every verb CleanOS uses is listed explicitly; anything else
/// is refused, so a compromised caller cannot turn the helper into a general root shell.
public enum ToolPolicy {
    public static let executables: [String: String] = [
        "tmutil": "/usr/bin/tmutil",
        "mdutil": "/usr/bin/mdutil",
        "tccutil": "/usr/bin/tccutil",
        "pkgutil": "/usr/sbin/pkgutil",
        "socketfilterfw": "/usr/libexec/ApplicationFirewall/socketfilterfw",
        "launchctl": "/bin/launchctl",
    ]

    static let identifier = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$")
    static let snapshotDate = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}-\\d{6}$")
    static let tccService = try! NSRegularExpression(pattern: "^[A-Za-z]{1,64}$")

    static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    static func isLabel(_ label: String) -> Bool { matches(identifier, label) && !label.lowercased().hasPrefix("com.apple.") }

    /// nil when the call is allowed, otherwise why it is refused.
    public static func refusal(tool: String, arguments a: [String]) -> String? {
        guard executables[tool] != nil else { return "\(tool) is not an allowed tool" }
        guard !a.contains(where: { $0.contains("\0") || $0.contains("\n") }) else { return "invalid argument" }
        let allowed: Bool
        switch tool {
        case "tccutil":
            allowed = a.count == 3 && a[0] == "reset" && matches(tccService, a[1]) && matches(identifier, a[2])
        case "tmutil":
            allowed = a.count == 2 && a[0] == "deletelocalsnapshots" && matches(snapshotDate, a[1])
        case "mdutil":
            allowed = a.count == 2 && a[0] == "-E" && isVolumeRoot(a[1])
        case "pkgutil":
            allowed = a.count == 2 && a[0] == "--forget" && isLabel(a[1])
        case "socketfilterfw":
            allowed = a.count == 2 && a[0] == "--remove" && a[1].hasPrefix("/")
        case "launchctl":
            switch a.first {
            case "bootout", "enable", "disable", "print":
                allowed = a.count == 2 && a[1].hasPrefix("system/") && isLabel(String(a[1].dropFirst("system/".count)))
            case "bootstrap":
                allowed = a.count == 3 && a[1] == "system" && a[2].hasPrefix("/Library/LaunchDaemons/") && a[2].hasSuffix(".plist") && !a[2].contains("/../")
            default:
                allowed = false
            }
        default:
            allowed = false
        }
        return allowed ? nil : "\(tool) \(a.first ?? "") with these arguments is not allowed"
    }

    static func isVolumeRoot(_ path: String) -> Bool {
        guard path == "/" || path.hasPrefix("/Volumes/") else { return false }
        return (try? URL(filePath: path).resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }
}

/// Paths CleanOS never removes, whatever asks for it. Shared by the app (as a last check before any removal) and
/// the helper (which must not trust the app).
public enum ProtectedPaths {
    /// Any path below these is refused (lowercased, ending in "/").
    static let deniedPrefixes = [
        "/system/", "/bin/", "/sbin/", "/dev/", "/private/etc/", "/private/var/db/", "/private/var/root/", "/private/var/vm/",
        "/private/var/protected/", "/private/var/folders/", "/library/apple/", "/library/keychains/", "/library/security/",
        "/library/preferences/systemconfiguration/", "/library/developer/commandlinetools/", "/volumes/recovery/",
        "/usr/bin/", "/usr/sbin/", "/usr/lib/", "/usr/libexec/", "/usr/share/", "/usr/standalone/",
    ]
    /// These exact folders are refused (they hold other software's files), but items inside them are not.
    static let deniedExact: Set<String> = [
        "/applications/utilities", "/users/shared", "/private/var", "/private/tmp", "/private/var/log", "/private/var/tmp",
        "/opt/homebrew", "/usr/local", "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/include",
        "/usr/local/share", "/usr/local/etc", "/usr/local/opt", "/usr/local/cellar", "/usr/local/caskroom", "/usr/local/homebrew",
        "/usr/local/var", "/library/audio/plug-ins", "/library/audio/plug-ins/hal", "/library/audio/plug-ins/components",
        "/library/audio/plug-ins/vst", "/library/audio/plug-ins/vst3", "/library/application support/microsoft",
        "/library/application support/adobe", "/library/application support/google", "/library/google",
    ]
    /// Standard folders of /Library and ~/Library: other software keeps files in them, so they are never removed whole.
    static let libraryFolders: Set<String> = [
        "accounts", "application scripts", "application support", "apple", "assistant", "assistants", "audio", "autosave information",
        "biome", "bundles", "caches", "calendars", "cloudstorage", "colorpickers", "colorsync", "components", "compositions",
        "contacts", "containers", "contextual menu items", "cookies", "coreanalytics", "coremediaio", "daemon containers",
        "developer", "dictionaries", "directoryservices", "documentation", "driverextensions", "extensions", "favorites",
        "filesystems", "fonts", "frameworks", "gpubundles", "graphics", "group containers", "httpstorages", "identityservices",
        "image capture", "input methods", "internet plug-ins", "java", "keyboard layouts", "keychains", "launchagents",
        "launchdaemons", "logs", "mail", "messages", "metadata", "mobile documents", "modem scripts", "opendirectory",
        "pdf services", "perl", "photos", "preferencepanes", "preferences", "printers", "privilegedhelpertools", "python",
        "quicklook", "receipts", "reminders", "ruby", "safari", "sandbox", "saved application state", "screen savers",
        "scriptingadditions", "scripts", "security", "services", "sharing", "shortcuts", "sounds", "speech", "spelling",
        "spotlight", "stagedextensions", "startupitems", "suggestions", "systemextensions", "systemmigration",
        "systemprofiler", "trial", "updates", "user pictures", "video", "webkit", "webserver", "widgets",
    ]
    /// Folders directly inside a home folder that hold someone's data even though they are hidden.
    static let homeKeep: Set<String> = [".ssh", ".gnupg", ".trash", ".config", ".local", ".cache", ".aws", ".kube"]

    /// The path with its parent directory resolved (symlinks, `..`, `/var` → `/private/var`); the last component is
    /// kept as is, so removing a symlink removes the link and never its target.
    public static func canonical(_ path: String) -> String {
        let url = URL(filePath: path)
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().path
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedParent = realpath(parent, &buffer) != nil ? String(cString: buffer) : URL(filePath: parent).standardizedFileURL.path
        return resolvedParent == "/" ? "/" + name : resolvedParent + "/" + name
    }

    /// nil when the path may be removed, otherwise a short reason. `path` should be `canonical(_:)`.
    public static func refusal(for path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n") else { return "not an absolute path" }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains("."), !components.contains("..") else { return "a protected location" }
        let lower = path.lowercased()
        for prefix in deniedPrefixes where lower.hasPrefix(prefix) || lower + "/" == prefix { return "a system location" }
        // A symlink into the system (such as /Applications/Safari.app) is part of macOS.
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            let resolved = (target.hasPrefix("/") ? target : (path as NSString).deletingLastPathComponent + "/" + target).lowercased()
            if resolved.hasPrefix("/system/") { return "part of macOS" }
        }
        // Everything on another disk is judged as if that disk were the startup disk.
        if components[0].lowercased() == "volumes" {
            guard components.count >= 3 else { return "a disk or its top level" }
            let rest = Array(components.dropFirst(2))
            if rest.count == 1 && rest[0].lowercased() == ".trashes" { return "the disk's Trash folder" }
            if [".trashes", ".spotlight-v100", ".fseventsd", ".documentrevisions-v100", ".temporaryitems"].contains(rest[0].lowercased()) { return nil }
            return judge(rest, lower: "/" + rest.joined(separator: "/").lowercased(), onDisk: path)
        }
        return judge(components, lower: lower, onDisk: path)
    }

    /// True for something that holds no other items (a plain file or a symbolic link) and for an app bundle.
    private static func isFileOrApp(_ path: String) -> Bool {
        if path.lowercased().hasSuffix(".app") { return true }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        let type = info.st_mode & S_IFMT
        return type == S_IFREG || type == S_IFLNK
    }

    /// `c` and `lower` are relative to the item's disk; `onDisk` is where the item really is.
    private static func judge(_ c: [String], lower: String, onDisk: String) -> String? {
        if c.count == 1 { return "a top-level folder of the disk" }
        if deniedExact.contains(lower) { return "a folder shared by other software" }
        switch c[0].lowercased() {
        case "library":
            if c.count == 2 && libraryFolders.contains(c[1].lowercased()) { return "a shared system folder" }
            if lower.contains("com.apple.") && !lower.contains("/caches/") && !lower.contains("/logs/") { return "an Apple component" }
        case "system":
            return "a system location"
        case "users":
            if c.count == 2 { return "a user's home folder" }
            let name = c[2]
            if c.count == 3 {
                if c[1].lowercased() == "shared" {
                    // Installers keep files for every user in /Users/Shared: a vendor's folder there is a leftover.
                    if name.lowercased() == "library" { return "a shared system folder" }
                } else if homeKeep.contains(name.lowercased()) || (!name.hasPrefix(".") && !isFileOrApp(onDisk)) {
                    // Folders directly in a home folder are the user's own; a single file or an app there may go.
                    return "a folder in a home folder"
                }
            }
            if c.count == 4 && name == "Library" && libraryFolders.contains(c[3].lowercased()) { return "a shared folder in a user's Library" }
            if c.count >= 5 && name == "Library" && ["mail", "messages", "keychains"].contains(c[3].lowercased()) { return "personal data" }
            // A cloud provider's folder holds the user's documents: it is never removed whole, single items in it may go.
            if c.count == 5 && name == "Library" && c[3].lowercased() == "cloudstorage" { return "a cloud storage folder" }
            if c.count >= 4 && name == "Library" && c[3] == "Mobile Documents" && c.count <= 5 && (c.count == 4 || c[4] == "com~apple~CloudDocs") { return "iCloud Drive" }
        case "private":
            if c.count == 2 { return "a system folder" }
        case "usr":
            if c.count < 3 || c[1].lowercased() != "local" { return "a system location" }
        default:
            break
        }
        if c.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) && !lower.hasSuffix(".photoslibrary") { return "inside a Photos library" }
        return nil
    }
}

/// Moves root-owned items into the calling user's Trash on the same volume and hands ownership back.
public enum TrashLocator {
    public static func isInsideTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }

    public static func trash(_ path: String, uid: uid_t, gid: gid_t) throws -> String {
        let source = URL(filePath: path)
        let fm = FileManager.default
        guard let pw = getpwuid(uid), let homePath = String(validatingCString: pw.pointee.pw_dir) else { throw TrashError.noHome }
        var sourceInfo = stat(), homeInfo = stat()
        guard lstat(path, &sourceInfo) == 0, stat(homePath, &homeInfo) == 0 else { throw TrashError.noHome }
        let trashDirectory: URL
        if sourceInfo.st_dev == homeInfo.st_dev {
            trashDirectory = URL(filePath: homePath).appending(path: ".Trash")
            if !fm.fileExists(atPath: trashDirectory.path) {
                try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: false, attributes: [.ownerAccountID: uid, .groupOwnerAccountID: gid, .posixPermissions: 0o700])
            }
        } else {
            let volume = try source.resourceValues(forKeys: [.volumeURLKey]).volume ?? URL(filePath: "/")
            let trashes = volume.appending(path: ".Trashes")
            if !fm.fileExists(atPath: trashes.path) {
                try fm.createDirectory(at: trashes, withIntermediateDirectories: false, attributes: [.ownerAccountID: 0, .groupOwnerAccountID: 80, .posixPermissions: 0o1333])
            }
            trashDirectory = trashes.appending(path: String(uid))
            if !fm.fileExists(atPath: trashDirectory.path) {
                try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: false, attributes: [.ownerAccountID: uid, .groupOwnerAccountID: gid, .posixPermissions: 0o700])
            }
        }
        var destination = trashDirectory.appending(path: source.lastPathComponent)
        var counter = 1
        while fm.fileExists(atPath: destination.path) || (try? destination.checkResourceIsReachable()) == true {
            counter += 1
            let base = source.deletingPathExtension().lastPathComponent + " \(counter)"
            destination = source.pathExtension.isEmpty ? trashDirectory.appending(path: base) : trashDirectory.appending(path: base).appendingPathExtension(source.pathExtension)
        }
        try fm.moveItem(at: source, to: destination)
        chownRecursively(destination, uid: uid, gid: gid)
        return destination.path
    }

    /// Gives the trashed item to the user so the Trash can be emptied without a password.
    static func chownRecursively(_ url: URL, uid: uid_t, gid: gid_t) {
        lchown(url.path, uid, gid)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: []) else { return }
        for case let child as URL in enumerator { lchown(child.path, uid, gid) }
    }

    enum TrashError: LocalizedError {
        case noHome
        var errorDescription: String? { "Could not find the Trash for this user." }
    }
}

/// Signing identity of the running code, used to pin the app and the helper to each other.
public enum CodeIdentity {
    /// SHA-1 of the leaf signing certificate of the code at `url` (or of the running process when nil), as the
    /// upper-case hex string code requirements use (`certificate leaf = H"…"`). nil for ad-hoc signed code.
    public static func leafCertificateHash(at url: URL? = nil) -> String? {
        var staticCode: SecStaticCode?
        if let url {
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess else { return nil }
        } else {
            var me: SecCode?
            guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess else { return nil }
        }
        guard let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        return Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    /// Code requirement text matching `identifier`, pinned to the same certificate as the running code when it has one.
    public static func requirement(identifier: String, pinnedTo leafHash: String?) -> String {
        if let leafHash { return "identifier \"\(identifier)\" and certificate leaf = H\"\(leafHash)\"" }
        return "identifier \"\(identifier)\""
    }
}
