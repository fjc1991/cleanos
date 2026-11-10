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

    /// The per-user folders under /private/var/folders hold app caches the uninstaller and Clean Up offer.
    @Test func guardAllowsItemsInThePerUserFolders() {
        for token in ["$DARWIN_USER_CACHE_DIR", "$DARWIN_USER_TEMP_DIR", "$DARWIN_USER_DIR"] {
            let folder = PathExpander.expand(token)
            #expect(folder.contains("/var/folders/"), "\(token) should be a per-user folder, got \(folder)")
            #expect(RemovalGuard.refusal(for: URL(filePath: folder + "/com.example.app")) == nil, "an item in \(token) must be allowed")
            #expect(RemovalGuard.refusal(for: URL(filePath: folder + "/com.example.app/Cache.db")) == nil)
            #expect(RemovalGuard.refusal(for: URL(filePath: folder)) != nil, "\(token) itself must be refused")
        }
        // Another user's per-user folder is not this user's scratch space.
        #expect(RemovalGuard.refusal(for: URL(filePath: "/private/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/C/com.example.app")) != nil)
        #expect(RemovalGuard.refusal(for: URL(filePath: "/private/var/folders")) != nil)
    }

    /// An app's item in a folder the leftover catalogue lists must pass the last check, or the review sheet offers
    /// something the removal then refuses. The folders below are refused on purpose: the uninstaller shows what it
    /// finds there as protected. A new entry here must be a decision, not an accident.
    @Test func guardAgreesWithTheCatalogue() {
        let knownProtected: Set<String> = [
            "~/Library/CloudStorage", "~/Library/Mail/Bundles", "/private/etc/cups/ppd", "/Library/Security/SecurityAgentPlugins",
            "/private/var/db/receipts", "/etc/paths.d", "/etc/manpaths.d", "/etc/resolver", "/etc/sudoers.d", "/etc/pam.d",
            "/etc/newsyslog.d", "/etc/profile.d", "/private/var/root/Library/Caches", "/private/var/root/Library/Application Support",
            "/private/var/root/Library/Preferences", "/private/var/root/Library/Logs",
        ]
        var refused: Set<String> = []
        for rule in Rules.bundled.catalogue.roots {
            for root in rule.allRoots where !root.contains("*") {
                let name = rule.nameStyle == .dotfile ? ".cleanos-fixture" : "com.example.cleanos-fixture"
                if RemovalGuard.refusal(for: URL(filePath: PathExpander.expand(root) + "/" + name)) != nil { refused.insert(root) }
            }
        }
        #expect(refused.subtracting(knownProtected).isEmpty, "offered by the catalogue but refused: \(refused.subtracting(knownProtected).sorted())")
        #expect(knownProtected.subtracting(refused).isEmpty, "no longer refused: \(knownProtected.subtracting(refused).sorted())")
    }

    /// Lists mark what the last check would refuse as protected instead of offering it.
    @Test func refusedLocationsAreShownAsProtected() {
        let home = NSHomeDirectory()
        func item(_ path: String, kind: ItemKind = .file) -> ScanItem { ScanItem(url: URL(filePath: path), title: "x", kind: kind, group: "g", tier: .safe) }
        #expect(item("/private/var/db/receipts/com.example.pkg.bom").markedProtectedIfRefused().tier == .protected)
        #expect(item(home + "/Library/Mail/V10/big.emlx").markedProtectedIfRefused().tier == .protected)
        #expect(item(home + "/Library/CloudStorage/Dropbox", kind: .directory).markedProtectedIfRefused().tier == .protected)
        #expect(item(home + "/Library/CloudStorage/Dropbox/Scans/big.pdf").markedProtectedIfRefused().tier == .safe)
        #expect(item(home + "/Library/Caches/com.example.app", kind: .directory).markedProtectedIfRefused().tier == .safe)
        #expect(item(PathExpander.expand("$DARWIN_USER_CACHE_DIR") + "/com.example.app", kind: .directory).markedProtectedIfRefused().tier == .safe)
        #expect(item("/Users/Shared/Example", kind: .directory).markedProtectedIfRefused().tier == .safe)
        // A registration's path names what it refers to; nothing at that path is removed.
        #expect(item("/private/var/db/receipts/com.example.pkg.bom", kind: .registration).markedProtectedIfRefused().tier == .safe)
    }

    /// The window reads progress a few times a second: nothing reported in between may be lost or shown twice.
    @Test func progressRelayCoalescesWithoutLosingItems() {
        let relay = RemovalProgressRelay(keeping: 3)
        #expect(relay.take().changed == false)
        let items = (0..<10).map { ScanItem(url: URL(filePath: "/tmp/x/\($0)"), title: "item \($0)", kind: .file, group: "Caches", size: 100) }
        for (index, item) in items.enumerated() {
            relay.report(done: index, total: items.count, current: item)       // started
            relay.report(done: index + 1, total: items.count, current: nil)    // finished
        }
        let first = relay.take()
        #expect(first.changed && first.done == 10 && first.total == 10)
        #expect(first.freed == 1000)                                           // every item counts, not only the ones kept
        #expect(first.finished.map(\.title) == ["item 7", "item 8", "item 9"])
        #expect(first.current?.title == "item 9")
        let second = relay.take()
        #expect(!second.changed && second.finished.isEmpty && second.freed == 1000 && second.done == 10)
    }

    @Test func progressRelayIsSafeAcrossThreads() async {
        let relay = RemovalProgressRelay()
        let item = ScanItem(url: URL(filePath: "/tmp/x/a"), title: "a", kind: .file, group: "Caches", size: 1)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask { relay.report(done: index, total: 200, current: index.isMultiple(of: 2) ? item : nil); _ = relay.take() }
            }
        }
        #expect(relay.take().total == 200)
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
