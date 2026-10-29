import Foundation
import HelperProtocol

/// Privileged helper daemon registered with `SMAppService.daemon`. Runs as root, exposes
/// `CleanOSHelperProtocol` over XPC and refuses connections from anything that is not CleanOS.
final class HelperService: NSObject, CleanOSHelperProtocol {
    let callerUID: uid_t
    let callerGID: gid_t

    init(callerUID: uid_t, callerGID: gid_t) {
        self.callerUID = callerUID
        self.callerGID = callerGID
    }

    func version(reply: @escaping @Sendable (String, Int) -> Void) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        reply(version, HelperConstants.protocolVersion)
    }

    func remove(paths: [String], permanently: Bool, reply: @escaping @Sendable ([String: String]) -> Void) {
        var results: [String: String] = [:]
        for path in paths {
            guard ProtectedPaths.isAllowed(path) else {
                results[path] = "Refused: protected location"
                continue
            }
            if ProcessInfo.processInfo.environment["CLEANOS_DRY_RUN"] == "1" {
                results[path] = ""
                continue
            }
            do {
                if permanently {
                    try FileManager.default.removeItem(atPath: path)
                    results[path] = ""
                } else {
                    let destination = try TrashLocator.trash(path, uid: callerUID, gid: callerGID)
                    results[path] = destination
                }
            } catch {
                results[path] = error.localizedDescription
            }
        }
        reply(results)
    }

    func run(tool: String, arguments: [String], reply: @escaping @Sendable (Int32, String, String) -> Void) {
        guard let executable = HelperConstants.allowedTools[tool] else {
            reply(-1, "", "Refused: \(tool) is not a whitelisted tool")
            return
        }
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            reply(-1, "", error.localizedDescription)
            return
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        reply(process.terminationStatus, stdout, stderr)
    }

    func readFile(atPath path: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard ReadablePaths.isAllowed(path) else {
            reply(nil, "Refused: \(path) is not readable through the helper")
            return
        }
        do {
            reply(try Data(contentsOf: URL(filePath: path)), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }
}

/// Paths the helper will never remove, whatever the app asks.
enum ProtectedPaths {
    static let prefixes = ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/lib/", "/usr/libexec/", "/usr/share/", "/bin/", "/sbin/",
                           "/private/etc/", "/etc/", "/Library/Apple/", "/private/var/db/", "/dev/", "/Volumes/Recovery/"]
    static let exact: Set<String> = ["/", "/Applications", "/Library", "/Users", "/Volumes", "/private", "/private/var", "/opt", "/usr/local"]

    static func isAllowed(_ path: String) -> Bool {
        let standardized = URL(filePath: path).standardizedFileURL.path
        if exact.contains(standardized) { return false }
        if standardized.contains("/../") || !standardized.hasPrefix("/") { return false }
        for prefix in prefixes where standardized.hasPrefix(prefix) { return false }
        if standardized.hasPrefix("/private/etc/") || standardized.hasPrefix("/etc/") { return false }
        if standardized.contains("com.apple.") && standardized.hasPrefix("/Library/") && !standardized.contains("/Caches/") && !standardized.contains("/Logs/") {
            return false
        }
        return true
    }
}

/// Root-only files the app may read through the helper.
enum ReadablePaths {
    static let allowed: Set<String> = [
        "/Library/Application Support/com.apple.TCC/TCC.db",
        "/private/var/db/com.apple.xpc.launchd/disabled.plist",
    ]
    static let allowedPrefixes = ["/private/var/db/receipts/", "/Library/Preferences/", "/private/var/db/com.apple.xpc.launchd/",
                                  "/Library/LaunchDaemons/", "/Library/LaunchAgents/"]

    static func isAllowed(_ path: String) -> Bool {
        let standardized = URL(filePath: path).standardizedFileURL.path
        if allowed.contains(standardized) { return true }
        return allowedPrefixes.contains { standardized.hasPrefix($0) }
    }
}

/// Moves root-owned items into the calling user's Trash on the same volume and hands ownership back.
enum TrashLocator {
    static func trash(_ path: String, uid: uid_t, gid: gid_t) throws -> String {
        let source = URL(filePath: path)
        let fm = FileManager.default
        let volumeRoot = try source.resourceValues(forKeys: [.volumeURLKey]).volume ?? URL(filePath: "/")
        let trashDirectory: URL
        if volumeRoot.path == "/" {
            guard let home = NSHomeDirectoryForUser(userName(for: uid)) else { throw HelperError.noHome }
            trashDirectory = URL(filePath: home).appending(path: ".Trash")
        } else {
            trashDirectory = volumeRoot.appending(path: ".Trashes/\(uid)")
        }
        try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: true, attributes: [.ownerAccountID: uid, .groupOwnerAccountID: gid, .posixPermissions: 0o700])
        var destination = trashDirectory.appending(path: source.lastPathComponent)
        var counter = 1
        while fm.fileExists(atPath: destination.path) {
            counter += 1
            let name = source.deletingPathExtension().lastPathComponent + " \(counter)"
            destination = trashDirectory.appending(path: name).appendingPathExtension(source.pathExtension)
        }
        try fm.moveItem(at: source, to: destination)
        try chownRecursively(destination, uid: uid, gid: gid)
        return destination.path
    }

    static func userName(for uid: uid_t) -> String {
        guard let pw = getpwuid(uid) else { return "" }
        return String(cString: pw.pointee.pw_name)
    }

    static func chownRecursively(_ url: URL, uid: uid_t, gid: gid_t) throws {
        lchown(url.path, uid, gid)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let child as URL in enumerator { lchown(child.path, uid, gid) }
    }

    enum HelperError: Error { case noHome }
}

/// Accepts connections only from a process whose code signature matches CleanOS.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard CodeSignatureValidator.isTrusted(pid: connection.processIdentifier) else {
            NSLog("CleanOS helper: refused connection from pid \(connection.processIdentifier)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: CleanOSHelperProtocol.self)
        connection.exportedObject = HelperService(callerUID: connection.effectiveUserIdentifier,
                                                  callerGID: connection.effectiveGroupIdentifier)
        connection.resume()
        return true
    }
}

enum CodeSignatureValidator {
    /// Release builds require a Developer ID signature for `com.cleanos.app` from the same team as the helper.
    /// Debug builds accept any process whose signing identifier is `com.cleanos.app`, so ad-hoc signed
    /// development builds can talk to the helper.
    static func isTrusted(pid: pid_t) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        #if DEBUG
        let requirementText = "identifier \"\(HelperConstants.appBundleIdentifier)\""
        #else
        let requirementText = "identifier \"\(HelperConstants.appBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier())\""
        #endif
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func teamIdentifier() -> String {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return "" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else { return "" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return "" }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
    }
}

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
NSLog("CleanOS helper started (protocol \(HelperConstants.protocolVersion))")
RunLoop.main.run()
