import Foundation

/// What a journal entry records.
public enum JournalAction: String, Codable, Sendable {
    case movedToTrash, deletedPermanently, launchdDisabled, launchdEnabled, registrationRemoved, lineRemoved, restored
}

/// One change made by CleanOS, with enough information to undo it.
public struct JournalEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var date: Date
    public var action: JournalAction
    public var originalPath: String
    public var trashedPath: String?
    public var volumeID: String?
    public var size: Int64
    public var detail: String?
    /// Inode of the trashed copy, so a different item later trashed under the same name is never "restored".
    public var trashedInode: UInt64?
    /// Set once the entry was put back; it is then no longer restorable.
    public var restoredAt: Date?

    public init(id: UUID = UUID(), date: Date = .now, action: JournalAction, originalPath: String,
                trashedPath: String? = nil, volumeID: String? = nil, size: Int64 = 0, detail: String? = nil) {
        self.id = id
        self.date = date
        self.action = action
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.volumeID = volumeID
        self.size = size
        self.detail = detail
        if let trashedPath { trashedInode = Self.inode(of: trashedPath) }
    }

    static func inode(of path: String) -> UInt64? {
        var info = stat()
        return lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    /// Entries that moved something to the Trash can be restored once, while that same trashed copy still exists.
    public var isRestorable: Bool {
        guard action == .movedToTrash, restoredAt == nil, let trashedPath, let current = Self.inode(of: trashedPath) else { return false }
        return trashedInode == nil || trashedInode == current
    }
}

/// A group of changes made in one "Remove" operation.
public struct JournalSession: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var startedAt: Date
    public var title: String
    public var appVersion: String
    public var entries: [JournalEntry]

    public init(id: UUID = UUID(), startedAt: Date = .now, title: String, appVersion: String, entries: [JournalEntry] = []) {
        self.id = id
        self.startedAt = startedAt
        self.title = title
        self.appVersion = appVersion
        self.entries = entries
    }

    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }
    public var restorableEntries: [JournalEntry] { entries.filter(\.isRestorable) }
}

public struct RestoreReport: Sendable {
    public var restored: [JournalEntry] = []
    public var failed: [(entry: JournalEntry, error: String)] = []
}

/// Persists every removal so the user can review history and put things back.
/// One JSON file per session under `~/Library/Application Support/com.cleanos/Journal`.
public actor RemovalJournal {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.cleanos/Journal", directoryHint: .isDirectory)
    }

    public let directory: URL
    private var sessions: [UUID: JournalSession] = [:]
    private var loaded = false

    public init(directory: URL = RemovalJournal.defaultDirectory) {
        self.directory = directory
    }

    public func beginSession(title: String, appVersion: String) throws -> JournalSession {
        try loadIfNeeded()
        let session = JournalSession(title: title, appVersion: appVersion)
        sessions[session.id] = session
        try write(session)
        return session
    }

    public func record(_ entry: JournalEntry, in sessionID: UUID) throws {
        try loadIfNeeded()
        guard var session = sessions[sessionID] else { throw JournalError.unknownSession }
        session.entries.append(entry)
        sessions[sessionID] = session
        try write(session)
    }

    /// All sessions, newest first. Also picks up sessions another process (the Trash Watcher) wrote meanwhile.
    public func allSessions() throws -> [JournalSession] {
        try loadIfNeeded()
        loadNewFiles()
        return sessions.values.sorted { $0.startedAt > $1.startedAt }
    }

    public func session(id: UUID) throws -> JournalSession? {
        try loadIfNeeded()
        return sessions[id]
    }

    /// Moves every restorable entry of the session back to its original location.
    public func restore(sessionID: UUID) throws -> RestoreReport {
        try loadIfNeeded()
        guard var session = sessions[sessionID] else { throw JournalError.unknownSession }
        var report = RestoreReport()
        let fm = FileManager.default
        for entry in session.entries where entry.isRestorable {
            guard let trashedPath = entry.trashedPath else { continue }
            do {
                let destination = URL(filePath: entry.originalPath)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: entry.originalPath) { throw JournalError.destinationExists(entry.originalPath) }
                try fm.moveItem(at: URL(filePath: trashedPath), to: destination)
                report.restored.append(entry)
                if let index = session.entries.firstIndex(where: { $0.id == entry.id }) { session.entries[index].restoredAt = .now }
                session.entries.append(JournalEntry(action: .restored, originalPath: entry.originalPath, size: entry.size,
                                                    detail: "Restored from \(trashedPath)"))
            } catch {
                report.failed.append((entry, error.localizedDescription))
            }
        }
        sessions[sessionID] = session
        try write(session)
        return report
    }

    /// Restores one entry of a session.
    public func restore(entryID: UUID, in sessionID: UUID) throws -> RestoreReport {
        try loadIfNeeded()
        guard var session = sessions[sessionID], let entry = session.entries.first(where: { $0.id == entryID }) else { throw JournalError.unknownSession }
        var report = RestoreReport()
        guard entry.isRestorable, let trashedPath = entry.trashedPath else {
            report.failed.append((entry, "This item is no longer in the Trash."))
            return report
        }
        do {
            let destination = URL(filePath: entry.originalPath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: entry.originalPath) { throw JournalError.destinationExists(entry.originalPath) }
            try FileManager.default.moveItem(at: URL(filePath: trashedPath), to: destination)
            report.restored.append(entry)
            if let index = session.entries.firstIndex(where: { $0.id == entry.id }) { session.entries[index].restoredAt = .now }
            session.entries.append(JournalEntry(action: .restored, originalPath: entry.originalPath, size: entry.size, detail: "Restored from \(trashedPath)"))
            sessions[sessionID] = session
            try write(session)
        } catch {
            report.failed.append((entry, error.localizedDescription))
        }
        return report
    }

    public func deleteSession(id: UUID) throws {
        try loadIfNeeded()
        sessions[id] = nil
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    // MARK: - Storage

    public enum JournalError: Error, LocalizedError {
        case unknownSession
        case destinationExists(String)
        public var errorDescription: String? {
            switch self {
            case .unknownSession: "Unknown journal session."
            case .destinationExists(let path): "Something already exists at \(path)."
            }
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func write(_ session: JournalSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(session)
        try data.write(to: fileURL(for: session.id), options: .atomic)
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        loadNewFiles()
    }

    private func loadNewFiles() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), sessions[id] == nil else { continue }
            if let data = try? Data(contentsOf: file), let session = try? Self.decoder.decode(JournalSession.self, from: data) {
                sessions[session.id] = session
            }
        }
    }
}
