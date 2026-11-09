import Foundation

/// Why an item could not be removed, in terms the user can act on.
public enum RemovalProblem: String, Sendable, Hashable, Codable {
    /// The account lacks permission (owned by root or another user): administrator rights will remove it.
    case needsAdministrator
    /// macOS privacy protection refused (App Management for apps, Full Disk Access for other apps' data). Root is
    /// refused too, so only the permission helps.
    case privacyProtected
    /// Locked, protected by System Integrity Protection, or a data vault.
    case locked
    case stillRunning
    /// The volume has no Trash; the item can only be deleted permanently.
    case noTrash
    case readOnlyVolume
    /// Refused by CleanOS' own safety rules.
    case protectedLocation
    /// The password prompt was cancelled.
    case cancelled
    case notFound
    case other
}

/// Outcome of removing one item.
public struct RemovalOutcome: Sendable, Hashable {
    public let url: URL
    public let trashedURL: URL?
    public let error: String?
    public let problem: RemovalProblem?
    public var succeeded: Bool { error == nil }

    init(url: URL, trashedURL: URL? = nil, error: String? = nil, problem: RemovalProblem? = nil) {
        self.url = url
        self.trashedURL = trashedURL
        self.error = error
        self.problem = problem
    }
}

/// Removes files with the current user's rights; what that cannot remove is escalated by `RemovalExecutor`.
/// Honours `CLEANOS_DRY_RUN=1`, in which case nothing is touched and every call reports success.
public enum FileRemover {
    /// Read through libc so a `setenv` after launch (tests, scripts) is honoured; ProcessInfo caches the environment.
    public static var isDryRun: Bool {
        guard let value = getenv("CLEANOS_DRY_RUN") else { return false }
        return String(cString: value) == "1"
    }

    /// Moves the item to the Trash of the volume it lives on.
    public static func trash(_ url: URL) -> RemovalOutcome {
        if isDryRun { return RemovalOutcome(url: url) }
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return RemovalOutcome(url: url, trashedURL: resulting as URL?)
        } catch {
            return RemovalOutcome(url: url, error: error.localizedDescription, problem: classify(error, url: url))
        }
    }

    /// Deletes the item outright (the user chose "Delete permanently", or it already is in a Trash).
    public static func deletePermanently(_ url: URL) -> RemovalOutcome {
        if isDryRun { return RemovalOutcome(url: url) }
        do {
            try FileManager.default.removeItem(at: url)
            return RemovalOutcome(url: url)
        } catch {
            return RemovalOutcome(url: url, error: error.localizedDescription, problem: classify(error, url: url))
        }
    }

    /// Turns a Foundation error into something the user can act on.
    public static func classify(_ error: Error, url: URL) -> RemovalProblem {
        let ns = error as NSError
        var posix: Int32?
        if ns.domain == NSPOSIXErrorDomain { posix = Int32(ns.code) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain { posix = Int32(underlying.code) }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notFound
            case NSFileWriteVolumeReadOnlyError: return .readOnlyVolume
            case NSFeatureUnsupportedError: return .noTrash
            default: break
            }
        }
        switch posix {
        case EACCES?: return .needsAdministrator
        case EPERM?: return lacksPOSIXPermission(url) ? .needsAdministrator : .privacyProtected
        case EROFS?: return .readOnlyVolume
        case ENOENT?: return .notFound
        case EBUSY?: return .stillRunning
        default:
            if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError) {
                return lacksPOSIXPermission(url) ? .needsAdministrator : .privacyProtected
            }
            return .other
        }
    }

    /// True when ordinary file permissions (not privacy protection) stop the current user: the parent is not
    /// writable, a directory itself is not writable (moving it rewrites its `..`), or a sticky parent belongs to
    /// someone else.
    static func lacksPOSIXPermission(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().path
        if access(parent, W_OK) != 0 { return true }
        var item = stat(), dir = stat()
        guard lstat(url.path, &item) == 0, stat(parent, &dir) == 0 else { return false }
        if (item.st_mode & S_IFMT) == S_IFDIR && access(url.path, W_OK) != 0 { return true }
        if dir.st_mode & S_ISVTX != 0 && item.st_uid != getuid() && dir.st_uid != getuid() { return true }
        return false
    }

    /// True when the current user can most likely remove the item without administrator rights. Only a hint for the
    /// lock icon and the default selection: the removal itself tries and escalates what fails.
    public static func isUserRemovable(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: url.deletingLastPathComponent().path), fm.isDeletableFile(atPath: url.path),
              !lacksPOSIXPermission(url) else { return false }
        return FileProtection.classify(url) == .none
    }
}

/// System protections that make an item impossible (or pointless) to remove.
public enum FileProtection: Sendable, Equatable {
    case none
    /// `UF_DATAVAULT`: only entitled system processes may read or delete the contents (QuickLook thumbnails, Mail, Messages…).
    case dataVault
    /// `SF_RESTRICTED`: protected by System Integrity Protection.
    case restricted
    /// `UF_IMMUTABLE` / `SF_IMMUTABLE` (chflags uchg/schg).
    case immutable
    /// A directory whose contents cannot be listed; moving it to the Trash would leave an undeletable item there.
    case unreadable
    /// A readable folder with a protected item directly inside it (a QuickLook thumbnail vault, a locked file…), so it cannot be emptied.
    case containsProtected

    static let dataVaultFlag: UInt32 = 0x0000_0080   // UF_DATAVAULT

    /// Classifies one item. Folders are also checked one level down, because a vault inside a plain folder makes the folder undeletable.
    public static func classify(_ url: URL, checkChildren: Bool = true) -> FileProtection {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            // A data vault denies even stat; EPERM/EACCES on an existing path means the system is guarding it.
            return errno == EPERM || errno == EACCES ? .dataVault : .none
        }
        let flags = info.st_flags
        if flags & dataVaultFlag != 0 { return .dataVault }
        if flags & UInt32(SF_RESTRICTED) != 0 { return .restricted }
        if flags & (UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE)) != 0 { return .immutable }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return .none }
        // Unreadable only matters when administrator rights will not be used: root can read it.
        if access(url.path, R_OK | X_OK) != 0 && info.st_uid == getuid() { return .unreadable }
        if checkChildren, let children = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            for child in children.prefix(64) where classify(url.appending(path: child), checkChildren: false) != .none { return .containsProtected }
        }
        return .none
    }

    public var explanation: String? {
        switch self {
        case .none: nil
        case .dataVault: "macOS data vault: only the system process that owns it can read or delete it. It is recreated automatically; leave it alone."
        case .restricted: "Protected by System Integrity Protection."
        case .immutable: "Locked with the immutable flag (chflags). Unlock it in Finder → Get Info before removing."
        case .unreadable: "Not readable with the current permissions, so it could not be deleted from the Trash either."
        case .containsProtected: "Contains a system-protected item (such as a QuickLook thumbnail vault), so the Trash could never empty it."
        }
    }
}
