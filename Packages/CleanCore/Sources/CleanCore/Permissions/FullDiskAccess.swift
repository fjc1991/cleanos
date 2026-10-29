import Foundation

/// Detects whether the app has Full Disk Access by probing protected locations the way the TCC
/// daemon enforces them: a protected path returns EPERM without the permission.
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable { case granted, denied, unknown }

    /// Deep link to Privacy & Security → Full Disk Access.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static let probes = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari/Bookmarks.plist",
        "Library/Safari",
        "Library/Mail",
        "Library/Messages",
        "Library/HomeKit",
    ]

    public static func status(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Status {
        var sawDenied = false
        for probe in probes {
            let path = home.appending(path: probe).path
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            if errno == EPERM || errno == EACCES { sawDenied = true }
        }
        return sawDenied ? .denied : .unknown
    }

    public static var isGranted: Bool { status() == .granted }
}
