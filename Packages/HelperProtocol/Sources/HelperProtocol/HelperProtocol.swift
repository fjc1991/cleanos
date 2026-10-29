import Foundation

/// Constants shared by the app, the privileged helper and the Trash watcher.
public enum HelperConstants {
    /// Mach service name of the privileged helper (must match the launchd plist `MachServices` key).
    public static let machServiceName = "com.cleanos.helper"
    public static let helperBundleIdentifier = "com.cleanos.helper"
    public static let appBundleIdentifier = "com.cleanos.app"
    public static let trashWatcherBundleIdentifier = "com.cleanos.trashwatcher"
    /// Bumped whenever the XPC protocol changes so the app can detect a stale helper.
    public static let protocolVersion = 1

    /// Command-line tools the helper is allowed to run as root, by absolute path.
    /// Anything else is refused. Keep this list short and audited.
    public static let allowedTools: [String: String] = [
        "tmutil": "/usr/bin/tmutil",
        "mdutil": "/usr/bin/mdutil",
        "purge": "/usr/sbin/purge",
        "sfltool": "/usr/bin/sfltool",
        "tccutil": "/usr/bin/tccutil",
        "pkgutil": "/usr/sbin/pkgutil",
        "kmutil": "/usr/bin/kmutil",
        "systemextensionsctl": "/usr/bin/systemextensionsctl",
        "socketfilterfw": "/usr/libexec/ApplicationFirewall/socketfilterfw",
        "fileproviderctl": "/usr/bin/fileproviderctl",
        "launchctl": "/bin/launchctl",
        "diskutil": "/usr/sbin/diskutil",
        "dot_clean": "/usr/sbin/dot_clean",
    ]
}

/// XPC interface implemented by the privileged helper daemon.
/// All replies are delivered on an arbitrary queue.
@objc public protocol CleanOSHelperProtocol {
    /// Returns the helper's version string and protocol version.
    func version(reply: @escaping @Sendable (String, Int) -> Void)

    /// Removes the given absolute paths as root. When `permanently` is false the items are moved to the
    /// Trash of the volume they live on; when true they are deleted. The reply maps each path to an
    /// error description, or to an empty string on success (and, for trashed items, the Trash location).
    func remove(paths: [String], permanently: Bool, reply: @escaping @Sendable ([String: String]) -> Void)

    /// Runs one of the whitelisted tools (see `HelperConstants.allowedTools`) with the given arguments.
    func run(tool: String, arguments: [String], reply: @escaping @Sendable (Int32, String, String) -> Void)

    /// Reads a root-only file (for example the system TCC database) and returns its contents.
    func readFile(atPath path: String, reply: @escaping @Sendable (Data?, String?) -> Void)
}
