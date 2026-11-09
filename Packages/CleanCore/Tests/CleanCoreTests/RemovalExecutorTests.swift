import Testing
import Foundation
import HelperProtocol
@testable import CleanCore

/// Records what the executor asks for administrator rights and answers as told.
actor StubRootRemover: RootRemover {
    var requests: [RootRemovalRequest] = []
    let answer: @Sendable (RootRemovalRequest) -> RootRemovalResult

    init(answer: @escaping @Sendable (RootRemovalRequest) -> RootRemovalResult = { RootRemovalResult(path: $0.path, trashedPath: $0.permanently ? nil : "/trash/x") }) {
        self.answer = answer
    }

    func remove(_ requests: [RootRemovalRequest]) async -> [RootRemovalResult] {
        self.requests += requests
        return requests.map(answer)
    }
}

@Suite(.serialized) struct RemovalExecutorTests {
    struct Fixture {
        let base: URL
        let journal: RemovalJournal
        /// A file in a folder the user cannot write: moving it needs administrator rights.
        let locked: URL
        let free: URL
    }

    static func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "Executor-\(UUID().uuidString)")
        let readOnly = base.appending(path: "readonly")
        try fm.createDirectory(at: readOnly, withIntermediateDirectories: true)
        let locked = readOnly.appending(path: "owned-by-someone-else.txt")
        try Data("x".utf8).write(to: locked)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        let free = base.appending(path: "free.txt")
        try Data("y".utf8).write(to: free)
        return Fixture(base: base, journal: RemovalJournal(directory: base.appending(path: "Journal")), locked: locked, free: free)
    }

    static func cleanUp(_ fixture: Fixture) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.locked.deletingLastPathComponent().path)
        try? FileManager.default.removeItem(at: fixture.base)
    }

    static func item(_ url: URL, needsRoot: Bool = false, payload: [String: String] = [:]) -> ScanItem {
        ScanItem(url: url, title: url.lastPathComponent, kind: .file, group: "Test", size: 10, needsRoot: needsRoot, payload: payload)
    }

    @Test func permissionFailuresAreEscalatedInOneBatch() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanUp(fixture) }
        let stub = StubRootRemover()
        // Marked as user-removable on purpose: the scan-time hint is wrong and the executor must recover.
        let plan = RemovalPlan(selected: [Self.item(fixture.locked), Self.item(fixture.free)], permanently: false)
        let result = await RemovalExecutor(journal: fixture.journal, rootRemover: stub).execute(plan, title: "t", appVersion: "t")
        #expect(result.failed.isEmpty)
        #expect(result.succeeded.count == 2)
        let requests = await stub.requests
        #expect(requests == [RootRemovalRequest(path: fixture.locked.path, permanently: false)])
        let session = try #require(try await fixture.journal.allSessions().first)
        #expect(session.entries.count == 2)
        #expect(session.entries.contains { $0.detail?.hasPrefix("with administrator rights") == true })
    }

    @Test func withoutAdministratorRightsTheItemFailsClearly() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanUp(fixture) }
        let plan = RemovalPlan(selected: [Self.item(fixture.locked, needsRoot: true)], permanently: false)
        let result = await RemovalExecutor(journal: fixture.journal).execute(plan, title: "t", appVersion: "t")
        #expect(result.failed.map(\.problem) == [.needsAdministrator])
        #expect(FileManager.default.fileExists(atPath: fixture.locked.path))
        // Nothing was removed, so no empty session is left in History.
        #expect(try await fixture.journal.allSessions().isEmpty)
    }

    @Test func trashContentsAreDeletedPermanentlyEvenWithAdministratorRights() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanUp(fixture) }
        let stub = StubRootRemover()
        let plan = RemovalPlan(selected: [Self.item(fixture.locked, needsRoot: true, payload: ["permanent": "1"])], permanently: false)
        _ = await RemovalExecutor(journal: fixture.journal, rootRemover: stub).execute(plan, title: "t", appVersion: "t")
        #expect(await stub.requests.first?.permanently == true)
    }

    @Test func privacyRefusalsAndCancelledPromptsAreTold() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanUp(fixture) }
        for (code, expected) in [(EPERM, RemovalProblem.privacyProtected), (ECANCELED, .cancelled), (EIO, .other)] {
            let stub = StubRootRemover { RootRemovalResult(path: $0.path, error: "no", errorCode: code) }
            let plan = RemovalPlan(selected: [Self.item(fixture.locked)], permanently: false)
            let result = await RemovalExecutor(journal: fixture.journal, rootRemover: stub).execute(plan, title: "t", appVersion: "t")
            #expect(result.failed.map(\.problem) == [expected])
        }
    }

    @Test func dryRunTouchesNothingAndNeverAsksForRights() async throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanUp(fixture) }
        setenv("CLEANOS_DRY_RUN", "1", 1)
        defer { unsetenv("CLEANOS_DRY_RUN") }
        let stub = StubRootRemover()
        let plan = RemovalPlan(selected: [Self.item(fixture.locked, needsRoot: true), Self.item(fixture.free)], permanently: true)
        let result = await RemovalExecutor(journal: fixture.journal, rootRemover: stub).execute(plan, title: "t", appVersion: "t")
        #expect(result.isDryRun && result.succeeded.count == 2)
        #expect(await stub.requests.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.free.path))
        #expect(try await fixture.journal.allSessions().isEmpty)
    }

    @Test func itemsInsideASelectedFolderGoWithIt() throws {
        let folder = URL(filePath: "/tmp/x/App Support")
        let plan = RemovalPlan(selected: [Self.item(folder), Self.item(folder.appending(path: "cache.db")), Self.item(URL(filePath: "/tmp/x/other"))], permanently: false)
        #expect(plan.userItems.map(\.title) == ["App Support", "other"])
    }

    @Test func guardRefusesPersonalAndSystemLocations() {
        let home = NSHomeDirectory()
        for path in [home, home + "/Documents", home + "/Library", home + "/Desktop", home + "/.ssh", "/", "/Users", "/System/Library",
                     "/Applications", "/Library/Application Support", home + "/Library/Mail/V10/x", "/private/var/db/x"] {
            #expect(RemovalGuard.refusal(for: URL(filePath: path)) != nil, "\(path) must be refused")
        }
        for path in [home + "/Library/Caches/com.example.app", home + "/Library/Application Support/Example", "/Applications/Example.app",
                     FileManager.default.temporaryDirectory.appending(path: "scratch.txt").path] {
            #expect(RemovalGuard.refusal(for: URL(filePath: path)) == nil, "\(path) must be allowed")
        }
    }

    @Test func classificationTellsAdministratorFromPrivacy() throws {
        let fixture = try Self.makeFixture()
        defer { Self.cleanUp(fixture) }
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        #expect(FileRemover.classify(denied, url: fixture.locked) == .needsAdministrator)
        let blocked = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        #expect(FileRemover.classify(blocked, url: fixture.free) == .privacyProtected)
        #expect(FileRemover.classify(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError), url: fixture.free) == .noTrash)
        #expect(!FileRemover.isUserRemovable(fixture.locked))
        #expect(FileRemover.isUserRemovable(fixture.free))
    }
}
