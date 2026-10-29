import Foundation
import Testing
@testable import CleanCore

@Suite struct JournalTests {
    @Test func recordAndRestoreRoundTrip() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "JournalTests-\(UUID().uuidString)")
        let journalDir = base.appending(path: "Journal")
        let trash = base.appending(path: "Trash")
        let original = base.appending(path: "Library/Caches/com.example.app")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: original.appending(path: "file.txt"))
        defer { try? FileManager.default.removeItem(at: base) }

        let journal = RemovalJournal(directory: journalDir)
        let session = try await journal.beginSession(title: "Test", appVersion: "0.1")

        // Simulate a move to Trash.
        let trashed = trash.appending(path: "com.example.app")
        try FileManager.default.moveItem(at: original, to: trashed)
        try await journal.record(JournalEntry(action: .movedToTrash, originalPath: original.path,
                                              trashedPath: trashed.path, size: 5), in: session.id)

        let stored = try await journal.session(id: session.id)
        #expect(stored?.entries.count == 1)
        #expect(stored?.restorableEntries.count == 1)
        #expect(stored?.totalBytes == 5)

        // A fresh journal instance must read the file back from disk.
        let reloaded = RemovalJournal(directory: journalDir)
        let report = try await reloaded.restore(sessionID: session.id)
        #expect(report.restored.count == 1 && report.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: original.appending(path: "file.txt").path))
        let after = try await reloaded.session(id: session.id)
        #expect(after?.entries.last?.action == .restored)
        #expect(after?.restorableEntries.isEmpty == true)
    }
}
