import Foundation
import HelperProtocol

/// Removes items with administrator rights: the privileged helper when it is installed, otherwise one macOS
/// administrator password prompt per batch. The app supplies the implementation; tests use a stub.
public protocol RootRemover: Sendable {
    /// One result per request (matched by path). An implementation that could not run at all returns failures.
    func remove(_ requests: [RootRemovalRequest]) async -> [RootRemovalResult]
}

/// The last check before anything is removed, whatever section or scanner produced the item: CleanOS' own
/// protected locations (shared with the helper), the user's protected-path rules, volume roots and anything above
/// the home folder.
public enum RemovalGuard {
    public static func refusal(for url: URL, home: String = NSHomeDirectory(), rules: ProtectedRules = Rules.bundled.protectedRules) -> String? {
        let path = ProtectedPaths.canonical(url.path)
        // The user's own temporary folder lives in /private/var/folders, which only the root side refuses outright.
        let inScratch = userScratch.contains { path.lowercased().hasPrefix($0 + "/") }
        if !inScratch, let reason = ProtectedPaths.refusal(for: path) { return "CleanOS never removes \(reason)." }
        let resolvedHome = ProtectedPaths.canonical(home)
        if resolvedHome.lowercased().hasPrefix(path.lowercased() + "/") { return "CleanOS never removes a folder that contains your home folder." }
        if rules.isProtected(path, home: resolvedHome) || rules.isProtected(url.path, home: home) { return "This location is protected." }
        if (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true { return "CleanOS never removes a whole disk." }
        return nil
    }

    static let userScratch: [String] = [FileManager.default.temporaryDirectory.path, NSTemporaryDirectory()]
        .map { ProtectedPaths.canonical(($0 as NSString).standardizingPath).lowercased() }
}

/// Selected items partitioned by how they are expected to be removed. `needsRoot` is only a hint: every file is
/// first tried with the user's rights and whatever fails for lack of permission is escalated.
public struct RemovalPlan: Sendable {
    public var userItems: [ScanItem]
    public var rootItems: [ScanItem]
    public var registrations: [ScanItem]
    public var permanently: Bool

    public init(selected: [ScanItem], permanently: Bool) {
        let leaves = selected.flatMap(\.leaves).filter { $0.tier.isSelectable }
        var seen: Set<String> = []
        var unique: [ScanItem] = []
        for item in leaves where !seen.contains(item.id) {
            seen.insert(item.id)
            unique.append(item)
        }
        registrations = unique.filter { $0.kind == .registration }
        // An item inside another selected item goes with its parent; removing it separately would only fail.
        let files = unique.filter { $0.kind != .registration }
        let paths = Set(files.compactMap { $0.url?.standardizedFileURL.path })
        let outermost = files.filter { item in
            guard let path = item.url?.standardizedFileURL.path else { return true }
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count > 1 {
                if paths.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
        userItems = outermost.filter { !$0.needsRoot }
        rootItems = outermost.filter(\.needsRoot)
        self.permanently = permanently
    }

    public var isEmpty: Bool { userItems.isEmpty && rootItems.isEmpty && registrations.isEmpty }
    public var totalSize: Int64 { (userItems + rootItems + registrations).reduce(0) { $0 + $1.size } }
    public var count: Int { userItems.count + rootItems.count + registrations.count }

    /// Items in a Trash are always deleted for good; so is everything when the user chose permanent deletion.
    public func isPermanent(_ item: ScanItem) -> Bool { permanently || item.payload["permanent"] == "1" }
    /// How many items cannot be put back afterwards (permanent deletions and system changes).
    public var irreversibleCount: Int { (userItems + rootItems).filter(isPermanent).count + registrations.count }
}

/// One item that was not removed.
public struct RemovalFailure: Sendable, Identifiable {
    public var item: ScanItem
    public var problem: RemovalProblem
    /// What went wrong, for display.
    public var error: String
    public var id: String { item.id }

    public init(item: ScanItem, problem: RemovalProblem, error: String) {
        self.item = item
        self.problem = problem
        self.error = error
    }
}

public struct RemovalResult: Sendable {
    public var succeeded: [ScanItem] = []
    public var failed: [RemovalFailure] = []
    /// Bytes actually released (permanent deletions, or what macOS gave back).
    public var freedBytes: Int64 = 0
    /// Bytes moved to a Trash: released once the Trash is emptied.
    public var trashedBytes: Int64 = 0
    /// Where trashed items went, for "Show in Trash".
    public var trashedPaths: [String] = []
    public var sessionID: UUID?
    public var isDryRun = false
    /// The journal could not be written, so History cannot put these items back.
    public var journalFailed = false

    public init() {}

    public var removedBytes: Int64 { freedBytes + trashedBytes }
}

/// Executes a plan: registrations that need the app's files first, then every file with the user's rights, then
/// what failed for lack of permission in one administrator batch, then the remaining registrations. Everything that
/// changed is journaled.
public actor RemovalExecutor {
    public let journal: RemovalJournal
    public let rootRemover: RootRemover?
    public let registrationRemover: RegistrationRemover

    public init(journal: RemovalJournal, rootRemover: RootRemover? = nil, registrationRemover: RegistrationRemover = RegistrationRemover()) {
        self.journal = journal
        self.rootRemover = rootRemover
        self.registrationRemover = registrationRemover
    }

    /// Registrations undone before files are removed, because they resolve the app by its bundle or plist.
    static func runsBeforeFiles(_ item: ScanItem) -> Bool {
        ["tcc", "launchdJob"].contains(item.payload["type"] ?? "")
    }

    public typealias Progress = @Sendable (Int, Int, ScanItem?) -> Void

    /// Mutable state of one run, passed `inout` to the steps below.
    struct Run {
        var result = RemovalResult()
        var done = 0
        let total: Int
        var recorded = 0
        let sessionID: UUID
        let progress: Progress?

        mutating func step(_ item: ScanItem?) { progress?(done, total, item) }
        mutating func finish() { done += 1; progress?(done, total, nil) }
        mutating func fail(_ item: ScanItem, _ problem: RemovalProblem, _ error: String) {
            result.failed.append(RemovalFailure(item: item, problem: problem, error: error))
            finish()
        }
    }

    /// `progress` receives (done, total, item being processed); the last call carries `nil` once everything finished.
    public func execute(_ plan: RemovalPlan, title: String, appVersion: String, progress: Progress? = nil) async -> RemovalResult {
        let all = plan.userItems + plan.rootItems + plan.registrations
        if FileRemover.isDryRun {
            // Simulation: nothing is touched, nothing is journaled, the root side is never asked.
            var result = RemovalResult()
            result.isDryRun = true
            for (index, item) in all.enumerated() {
                progress?(index, all.count, item)
                result.succeeded.append(item)
                if plan.isPermanent(item) || item.kind == .registration { result.freedBytes += item.size } else { result.trashedBytes += item.size }
                progress?(index + 1, all.count, nil)
            }
            return result
        }
        guard let session = try? await journal.beginSession(title: title, appVersion: appVersion) else {
            var result = RemovalResult()
            result.failed = all.map { RemovalFailure(item: $0, problem: .other, error: "Could not open the removal journal, so nothing was removed.") }
            return result
        }
        var run = Run(total: plan.count, sessionID: session.id, progress: progress)
        run.result.sessionID = session.id

        for item in plan.registrations where Self.runsBeforeFiles(item) { await removeRegistration(item, &run) }

        // Files, with the user's own rights first.
        var escalate: [(item: ScanItem, url: URL, permanent: Bool)] = []
        for item in plan.userItems + plan.rootItems {
            guard let url = item.url else { run.finish(); continue }
            run.step(item)
            if let refusal = RemovalGuard.refusal(for: url) { run.fail(item, .protectedLocation, refusal); continue }
            if let explanation = FileProtection.classify(url).explanation { run.fail(item, .locked, explanation); continue }   // never park an undeletable item in the Trash
            let permanent = plan.isPermanent(item)
            let outcome = permanent ? FileRemover.deletePermanently(url) : FileRemover.trash(url)
            switch outcome.problem {
            case nil:
                await succeeded(item, url: url, trashedPath: outcome.trashedURL?.path, permanent: permanent, viaAdministrator: false, &run)
                run.finish()
            case .notFound?:
                run.result.succeeded.append(item)   // already gone
                run.finish()
            case .needsAdministrator?:
                escalate.append((item, url, permanent))   // finished when the batch is done
            case .noTrash?:
                run.fail(item, .noTrash, "This disk has no Trash, so the item can only be deleted permanently.")
            case .privacyProtected?:
                run.fail(item, .privacyProtected, Self.privacyMessage(for: url))
            case let problem?:
                run.fail(item, problem, outcome.error ?? "Could not be removed.")
            }
        }

        // What needs administrator rights, in one batch so macOS asks for the password once.
        if !escalate.isEmpty {
            run.step(escalate[0].item)
            if let rootRemover {
                let results = await rootRemover.remove(escalate.map { RootRemovalRequest(path: $0.url.path, permanently: $0.permanent) })
                let byPath = Dictionary(results.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
                for (item, url, permanent) in escalate {
                    let outcome = byPath[url.path] ?? RootRemovalResult(path: url.path, error: "No answer from the administrator helper.")
                    if outcome.succeeded {
                        await succeeded(item, url: url, trashedPath: outcome.trashedPath, permanent: permanent || outcome.trashedPath == nil, viaAdministrator: true, &run)
                        run.finish()
                    } else {
                        let failure = Self.failure(item: item, url: url, outcome: outcome)
                        run.fail(item, failure.problem, failure.error)
                    }
                }
            } else {
                for (item, _, _) in escalate { run.fail(item, .needsAdministrator, "Needs administrator rights.") }
            }
        }

        for item in plan.registrations where !Self.runsBeforeFiles(item) { await removeRegistration(item, &run) }

        if run.recorded == 0 {
            try? await journal.deleteSession(id: session.id)
            run.result.sessionID = nil
        }
        progress?(run.total, run.total, nil)
        return run.result
    }

    private func record(_ entry: JournalEntry, _ run: inout Run) async {
        do {
            try await journal.record(entry, in: run.sessionID)
            run.recorded += 1
        } catch {
            run.result.journalFailed = true
        }
    }

    private func succeeded(_ item: ScanItem, url: URL, trashedPath: String?, permanent: Bool, viaAdministrator: Bool, _ run: inout Run) async {
        run.result.succeeded.append(item)
        if permanent { run.result.freedBytes += item.size } else { run.result.trashedBytes += item.size }
        if let trashedPath { run.result.trashedPaths.append(trashedPath) }
        let detail = (viaAdministrator ? "with administrator rights; " : "") + item.matchedBy.joined(separator: ", ")
        await record(JournalEntry(action: permanent ? .deletedPermanently : .movedToTrash, originalPath: url.path,
                                  trashedPath: trashedPath, size: item.size, detail: detail), &run)
    }

    private func removeRegistration(_ item: ScanItem, _ run: inout Run) async {
        run.step(item)
        if let error = await registrationRemover.remove(item) {
            run.fail(item, error.hasPrefix("Administrator") || error.hasPrefix("Needs administrator") ? .needsAdministrator : .other, error)
            return
        }
        run.result.succeeded.append(item)
        if item.payload["type"] == "purge", let attempt = PurgeableReclaimer.lastAttempt(mount: item.payload["mount"] ?? "/") {
            run.result.freedBytes += max(attempt.purged, attempt.freed)   // what macOS actually gave back, not the estimate
        }
        let payload = (try? JSONEncoder().encode(item.payload)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        await record(JournalEntry(action: .registrationRemoved, originalPath: item.id, size: 0, detail: "\(item.group): \(item.title) \(payload)"), &run)
        run.finish()
    }

    static func failure(item: ScanItem, url: URL, outcome: RootRemovalResult) -> RemovalFailure {
        if outcome.refused { return RemovalFailure(item: item, problem: .protectedLocation, error: outcome.error ?? "Refused.") }
        if outcome.errorCode == ECANCELED { return RemovalFailure(item: item, problem: .cancelled, error: outcome.error ?? "The password prompt was cancelled.") }
        if outcome.errorCode == EPERM { return RemovalFailure(item: item, problem: .privacyProtected, error: privacyMessage(for: url)) }
        return RemovalFailure(item: item, problem: .other, error: outcome.error ?? "Could not be removed.")
    }

    static func privacyMessage(for url: URL) -> String {
        url.pathExtension == "app"
            ? "macOS blocked removing this app. Allow CleanOS under System Settings → Privacy & Security → App Management, then try again."
            : "macOS privacy protection blocked this. Allow CleanOS under System Settings → Privacy & Security → Full Disk Access, then try again."
    }
}
