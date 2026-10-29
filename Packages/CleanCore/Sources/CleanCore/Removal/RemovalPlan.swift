import Foundation

/// Removes root-owned items. The app supplies an XPC-backed implementation; tests use a stub.
public protocol RootRemover: Sendable {
    /// Returns, per path, an empty string (success), the Trash location, or an error description.
    func remove(paths: [String], permanently: Bool) async -> [String: String]
}

/// Selected items partitioned by how they have to be removed.
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
        let files = unique.filter { $0.kind != .registration }
        userItems = files.filter { !$0.needsRoot }
        rootItems = files.filter(\.needsRoot)
        self.permanently = permanently
    }

    public var isEmpty: Bool { userItems.isEmpty && rootItems.isEmpty && registrations.isEmpty }
    public var totalSize: Int64 { (userItems + rootItems).reduce(0) { $0 + $1.size } }
    public var count: Int { userItems.count + rootItems.count + registrations.count }
}

public struct RemovalResult: Sendable {
    public var succeeded: [ScanItem] = []
    public var failed: [(item: ScanItem, error: String)] = []
    public var freedBytes: Int64 = 0
    public var sessionID: UUID?
    public var isDryRun = false

    public init() {}
}

/// Executes a plan: user items through `FileRemover`, root items through the helper, everything journaled.
public actor RemovalExecutor {
    public let journal: RemovalJournal
    public let rootRemover: RootRemover?
    public let registrationRemover: RegistrationRemover

    public init(journal: RemovalJournal, rootRemover: RootRemover? = nil, registrationRemover: RegistrationRemover = RegistrationRemover()) {
        self.journal = journal
        self.rootRemover = rootRemover
        self.registrationRemover = registrationRemover
    }

    /// `progress` receives (done, total, item being processed); the last call carries `nil` once everything finished.
    public func execute(_ plan: RemovalPlan, title: String, appVersion: String,
                        progress: (@Sendable (Int, Int, ScanItem?) -> Void)? = nil) async -> RemovalResult {
        var result = RemovalResult()
        result.isDryRun = FileRemover.isDryRun
        let total = plan.count
        var done = 0
        guard let session = try? await journal.beginSession(title: title, appVersion: appVersion) else {
            for item in plan.userItems + plan.rootItems + plan.registrations { result.failed.append((item, "Could not open the removal journal.")) }
            return result
        }
        result.sessionID = session.id

        for item in plan.userItems {
            guard let url = item.url else { continue }
            progress?(done, total, item)
            if let explanation = FileProtection.classify(url).explanation {
                result.failed.append((item, explanation))   // never park an undeletable item in the Trash
                done += 1
                progress?(done, total, nil)
                continue
            }
            let permanent = plan.permanently || item.payload["permanent"] == "1"
            let outcome = permanent ? FileRemover.deletePermanently(url) : FileRemover.trash(url)
            if let error = outcome.error {
                result.failed.append((item, error))
            } else {
                result.succeeded.append(item)
                result.freedBytes += item.size
                try? await journal.record(JournalEntry(action: permanent ? .deletedPermanently : .movedToTrash,
                                                       originalPath: url.path, trashedPath: outcome.trashedURL?.path, size: item.size,
                                                       detail: item.matchedBy.joined(separator: ", ")), in: session.id)
            }
            done += 1
            progress?(done, total, nil)
        }

        if !plan.rootItems.isEmpty {
            if let rootRemover {
                let paths = plan.rootItems.compactMap { $0.url?.path }
                progress?(done, total, plan.rootItems.first)
                let outcomes = await rootRemover.remove(paths: paths, permanently: plan.permanently)
                for item in plan.rootItems {
                    guard let path = item.url?.path else { continue }
                    let outcome = outcomes[path] ?? "No response from the helper."
                    if outcome.isEmpty || outcome.hasPrefix("/") {
                        result.succeeded.append(item)
                        result.freedBytes += item.size
                        try? await journal.record(JournalEntry(action: plan.permanently ? .deletedPermanently : .movedToTrash,
                                                               originalPath: path, trashedPath: outcome.isEmpty ? nil : outcome, size: item.size,
                                                               detail: "via helper; " + item.matchedBy.joined(separator: ", ")), in: session.id)
                    } else {
                        result.failed.append((item, outcome))
                    }
                    done += 1
                    progress?(done, total, nil)
                }
            } else {
                for item in plan.rootItems {
                    result.failed.append((item, "Administrator privileges are required. Enable the helper in Settings."))
                    done += 1
                    progress?(done, total, nil)
                }
            }
        }

        for item in plan.registrations {
            progress?(done, total, item)
            if let error = await registrationRemover.remove(item) {
                result.failed.append((item, error))
            } else {
                result.succeeded.append(item)
                if item.payload["type"] == "purge", let attempt = PurgeableReclaimer.lastAttempt(mount: item.payload["mount"] ?? "/") {
                    result.freedBytes += max(attempt.purged, attempt.freed)   // what macOS actually gave back, not the estimate
                }
                let payload = (try? JSONEncoder().encode(item.payload)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                try? await journal.record(JournalEntry(action: .registrationRemoved, originalPath: item.id, size: 0,
                                                       detail: "\(item.group): \(item.title) \(payload)"), in: session.id)
            }
            done += 1
            progress?(done, total, nil)
        }
        progress?(total, total, nil)
        return result
    }
}
