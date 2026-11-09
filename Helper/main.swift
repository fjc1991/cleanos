import Foundation
import HelperProtocol

// The privileged side of CleanOS. It runs in one of two ways:
//  • launchd daemon (no arguments): registered with SMAppService and serving `CleanOSHelperProtocol` over XPC,
//    only to a CleanOS signed with the same certificate as this helper;
//  • one-shot (`--request <base64 JSON> --output <file>`): started by CleanOS through the macOS administrator
//    password prompt. It performs one `HelperRequest`, writes the JSON `HelperResponse` and exits.
// Both delegate the actual work, and all input validation, to `HelperCore`.

/// One request, started through the administrator prompt.
enum OneShot {
    static func run(_ arguments: [String]) -> Int32 {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let encoded = value(after: "--request"), let data = Data(base64Encoded: encoded),
              let request = try? JSONDecoder().decode(HelperRequest.self, from: data),
              let output = value(after: "--output") else {
            FileHandle.standardError.write(Data("usage: com.cleanos.helper --request <base64 JSON> --output <file>\n".utf8))
            return 64
        }
        guard let response = try? JSONEncoder().encode(HelperCore.handle(request)) else { return 70 }
        return write(response, to: output) ? 0 : 73
    }

    /// Writes the response into the caller's private folder without following symlinks: the folder must belong to an
    /// ordinary user and be closed to everyone else, the file is created exclusively and then renamed into place.
    static func write(_ data: Data, to output: String) -> Bool {
        let url = URL(filePath: output)
        let folder = url.deletingLastPathComponent().path
        var info = stat()
        guard url.pathExtension == "json", lstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid != 0, info.st_mode & 0o077 == 0 else { return false }
        let partial = output + ".partial"
        let fd = open(partial, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
        fchown(fd, info.st_uid, info.st_gid)
        close(fd)
        return written == data.count && rename(partial, output) == 0
    }
}

/// XPC service object for one connection.
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

    func perform(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        let response: HelperResponse
        switch try? JSONDecoder().decode(HelperRequest.self, from: data) {
        case .remove(let items, _, _)?:
            // Removed items go to the Trash of whoever connected, whatever the request says.
            response = HelperCore.handle(.remove(items: items, uid: callerUID, gid: callerGID))
        case let request?:
            response = HelperCore.handle(request)
        case nil:
            response = .failed("The helper could not read the request.")
        }
        reply((try? JSONEncoder().encode(response)) ?? Data())
    }
}

/// Accepts connections only from CleanOS signed with this helper's own certificate (checked by the system against
/// the connection's audit token, see `setConnectionCodeSigningRequirement`). An ad-hoc signed release accepts nobody.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let isAccepting: Bool
    init(isAccepting: Bool) { self.isAccepting = isAccepting }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard isAccepting else {
            NSLog("CleanOS helper: refused pid \(connection.processIdentifier); this helper is not signed with a certificate")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: CleanOSHelperProtocol.self)
        connection.exportedObject = HelperService(callerUID: connection.effectiveUserIdentifier, callerGID: connection.effectiveGroupIdentifier)
        connection.resume()
        return true
    }
}

enum ClientRequirement {
    /// Requirement every connecting process must meet, or nil when no safe requirement exists.
    static var text: String? {
        let leaf = CodeIdentity.leafCertificateHash()
        #if DEBUG
        return CodeIdentity.requirement(identifier: HelperConstants.appBundleIdentifier, pinnedTo: leaf)
        #else
        guard let leaf else { return nil }
        return CodeIdentity.requirement(identifier: HelperConstants.appBundleIdentifier, pinnedTo: leaf)
        #endif
    }
}

if CommandLine.arguments.contains("--request") {
    exit(OneShot.run(CommandLine.arguments))
}

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
let requirement = ClientRequirement.text
if let requirement { listener.setConnectionCodeSigningRequirement(requirement) }
let delegate = ListenerDelegate(isAccepting: requirement != nil)
listener.delegate = delegate
listener.resume()
NSLog("CleanOS helper started (protocol \(HelperConstants.protocolVersion), requirement: \(requirement ?? "none, refusing all"))")
RunLoop.main.run()
