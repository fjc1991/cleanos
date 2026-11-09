import Foundation

/// Constants shared by the app, the privileged helper and the Trash watcher.
public enum HelperConstants {
    /// Mach service name of the privileged helper (must match the launchd plist `MachServices` key).
    public static let machServiceName = "com.cleanos.helper"
    public static let helperBundleIdentifier = "com.cleanos.helper"
    public static let appBundleIdentifier = "com.cleanos.app"
    public static let trashWatcherBundleIdentifier = "com.cleanos.trashwatcher"
    /// Bumped whenever the XPC protocol or the request format changes so the app can detect a stale helper.
    public static let protocolVersion = 2
}

/// XPC interface implemented by the privileged helper daemon. Requests and responses are JSON-encoded
/// `HelperRequest` / `HelperResponse` values, the same ones the one-shot administrator mode reads and writes.
/// All replies are delivered on an arbitrary queue.
@objc public protocol CleanOSHelperProtocol {
    /// Returns the helper's version string and protocol version.
    func version(reply: @escaping @Sendable (String, Int) -> Void)

    /// Performs one JSON-encoded `HelperRequest` and replies with a JSON-encoded `HelperResponse`.
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

/// One item to remove with administrator rights.
public struct RootRemovalRequest: Codable, Sendable, Hashable {
    public var path: String
    public var permanently: Bool

    public init(path: String, permanently: Bool) {
        self.path = path
        self.permanently = permanently
    }
}

/// What happened to one `RootRemovalRequest`.
public struct RootRemovalResult: Codable, Sendable, Hashable {
    public var path: String
    /// Where the item went when it was moved to a Trash.
    public var trashedPath: String?
    /// Human-readable failure, nil on success.
    public var error: String?
    /// POSIX errno of the failure when known (EPERM means macOS privacy protection refused even root).
    public var errorCode: Int32?
    /// True when CleanOS' own safety rules refused the path.
    public var refused: Bool

    public var succeeded: Bool { error == nil }

    public init(path: String, trashedPath: String? = nil, error: String? = nil, errorCode: Int32? = nil, refused: Bool = false) {
        self.path = path
        self.trashedPath = trashedPath
        self.error = error
        self.errorCode = errorCode
        self.refused = refused
    }
}

/// Output of an allow-listed tool run as root.
public struct ToolResult: Codable, Sendable, Hashable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// A unit of work for the helper. `uid`/`gid` say whose Trash removed items go to; the XPC daemon replaces them
/// with the identity of the connecting process.
public enum HelperRequest: Codable, Sendable, Hashable {
    case remove(items: [RootRemovalRequest], uid: UInt32, gid: UInt32)
    case run(tool: String, arguments: [String])
}

public enum HelperResponse: Codable, Sendable, Hashable {
    case removed([RootRemovalResult])
    case ran(ToolResult)
    case failed(String)
}
