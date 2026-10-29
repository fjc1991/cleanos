import Foundation

/// Outcome of removing one item.
public struct RemovalOutcome: Sendable, Hashable {
    public let url: URL
    public let trashedURL: URL?
    public let error: String?
    public var succeeded: Bool { error == nil }
}

/// Removes files the current user owns. Root-owned items go through the privileged helper instead.
/// Honours `CLEANOS_DRY_RUN=1`, in which case nothing is touched and every call reports success.
public enum FileRemover {
    /// Read through libc so a `setenv` after launch (tests, scripts) is honoured; ProcessInfo caches the environment.
    public static var isDryRun: Bool {
        guard let value = getenv("CLEANOS_DRY_RUN") else { return false }
        return String(cString: value) == "1"
    }

    /// Moves the item to the Trash of the volume it lives on.
    public static func trash(_ url: URL) -> RemovalOutcome {
        if isDryRun { return RemovalOutcome(url: url, trashedURL: nil, error: nil) }
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return RemovalOutcome(url: url, trashedURL: resulting as URL?, error: nil)
        } catch {
            return RemovalOutcome(url: url, trashedURL: nil, error: error.localizedDescription)
        }
    }

    /// Deletes the item outright. Only used when the user picked "Delete items permanently"
    /// or the volume has no Trash.
    public static func deletePermanently(_ url: URL) -> RemovalOutcome {
        if isDryRun { return RemovalOutcome(url: url, trashedURL: nil, error: nil) }
        do {
            try FileManager.default.removeItem(at: url)
            return RemovalOutcome(url: url, trashedURL: nil, error: nil)
        } catch {
            return RemovalOutcome(url: url, trashedURL: nil, error: error.localizedDescription)
        }
    }

    /// True when the current user can delete the item without root (owns the parent directory and the item)
    /// and macOS does not protect it with flags or a data vault.
    public static func isUserRemovable(_ url: URL) -> Bool {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent().path
        guard fm.isWritableFile(atPath: parent) && fm.isDeletableFile(atPath: url.path) else { return false }
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
        if access(url.path, R_OK | X_OK) != 0 { return .unreadable }
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
