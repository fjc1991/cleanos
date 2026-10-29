import AppKit
import UserNotifications
import CleanCore
import HelperProtocol

/// Login item that notices when an app is moved to the Trash and offers to remove its leftovers.
/// Watches `~/.Trash` directly when Full Disk Access allows it, otherwise diffs the application folders.
@MainActor
final class WatcherAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var trashWatcher: DirectoryWatcher?
    private var folderWatchers: [DirectoryWatcher] = []
    private var knownTrashEntries: Set<String> = []
    private var knownApps: [String: InstalledApp] = [:]
    private var pending: [String: (app: InstalledApp, result: LeftoverScanResult)] = [:]
    private let catalog = AppCatalog()
    private let locator = LeftoverLocator()
    private let journal = RemovalJournal()
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "trashedApp", actions: [
                UNNotificationAction(identifier: "remove", title: "Remove Leftovers", options: []),
                UNNotificationAction(identifier: "review", title: "Review in CleanOS", options: [.foreground]),
            ], intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task { await self.start() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refreshSnapshot() } }
        NSLog("CleanOS Trash Watcher started; Full Disk Access: \(FullDiskAccess.status())")
    }

    private func start() async {
        await refreshSnapshot()
        let trash = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: trash.path) {
            knownTrashEntries = Set(entries)
            trashWatcher = DirectoryWatcher(url: trash) { Task { @MainActor [weak self] in await self?.trashChanged() } }
            NSLog("CleanOS Trash Watcher: watching ~/.Trash")
        } else {
            NSLog("CleanOS Trash Watcher: ~/.Trash is not readable; watching application folders instead")
        }
        for path in AppSettingsBridge.scanLocations where !path.hasPrefix("/System") {
            if let watcher = DirectoryWatcher(url: URL(filePath: path), handler: { Task { @MainActor [weak self] in await self?.foldersChanged() } }) {
                folderWatchers.append(watcher)
            }
        }
    }

    private func refreshSnapshot() async {
        let apps = await catalog.scan(locations: AppSettingsBridge.scanLocations.map { URL(filePath: $0) })
        knownApps = Dictionary(uniqueKeysWithValues: apps.map { ($0.url.standardizedFileURL.path, $0) })
        try? await catalog.saveSnapshot(apps)
    }

    private func trashChanged() async {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: trash.path) else { return }
        let added = Set(entries).subtracting(knownTrashEntries)
        knownTrashEntries = Set(entries)
        for name in added where name.hasSuffix(".app") {
            try? await Task.sleep(for: .seconds(1))   // let the move finish
            await handleTrashedApp(at: trash.appending(path: name))
        }
    }

    private func foldersChanged() async {
        try? await Task.sleep(for: .seconds(2))
        let current = Set(AppCatalog.findAppBundles(in: AppSettingsBridge.scanLocations.map { URL(filePath: $0) }, skipList: []).map { $0.standardizedFileURL.path })
        let removed = Set(knownApps.keys).subtracting(current)
        for path in removed {
            guard let app = knownApps[path] else { continue }
            knownApps[path] = nil
            await offer(app: app)
        }
        for path in current.subtracting(knownApps.keys) {
            if let app = AppCatalog.makeApp(url: URL(filePath: path), shared: Rules.bundled.shared, cachedIdentity: nil) { knownApps[path] = app }
        }
    }

    private func handleTrashedApp(at url: URL) async {
        guard let identity = AppInspector.inspect(bundleURL: url, shared: Rules.bundled.shared) else { return }
        let original = knownApps.values.first { $0.bundleID == identity.bundleID }
        let app = original ?? InstalledApp(url: url, name: identity.name, bundleID: identity.bundleID, version: nil, build: nil, isSystem: false,
                                           modificationDate: nil, creationDate: nil, lastOpenedDate: nil, identity: identity)
        if let original { knownApps[original.url.standardizedFileURL.path] = nil }
        await offer(app: app)
    }

    private func offer(app: InstalledApp) async {
        let result = await locator.locate(app: app, otherApps: Array(knownApps.values), includeExecutable: false)
        let items = result.defaultSelection
        guard !items.isEmpty else { return }
        let size = items.reduce(0) { $0 + $1.size }
        let id = UUID().uuidString
        pending[id] = (app, result)
        let content = UNMutableNotificationContent()
        content.title = "\(app.name) was moved to Trash"
        content.body = "\(items.count) leftover file\(items.count == 1 ? "" : "s") (\(size.formattedBytes)) remain on your disk."
        content.categoryIdentifier = "trashedApp"
        content.userInfo = ["bundleID": app.bundleID]
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate (called on an arbitrary queue; hop to the main actor)

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            await self.handleResponse(id: id, action: action)
            done()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func handleResponse(id: String, action: String) async {
        guard let entry = pending[id] else { return }
        switch action {
        case "remove":
            let plan = RemovalPlan(selected: entry.result.defaultSelection.filter { !$0.needsRoot }, permanently: false)
            let outcome = await RemovalExecutor(journal: journal).execute(plan, title: "Leftovers of \(entry.app.name)", appVersion: "watcher")
            let content = UNMutableNotificationContent()
            content.title = "Leftovers of \(entry.app.name) removed"
            content.body = "\(outcome.succeeded.count) item\(outcome.succeeded.count == 1 ? "" : "s") moved to Trash, \(outcome.freedBytes.formattedBytes) freed." + (outcome.failed.isEmpty ? "" : " \(outcome.failed.count) could not be removed.")
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            pending[id] = nil
        default:
            if var components = URLComponents(string: "cleanos://remains") {
                components.queryItems = [URLQueryItem(name: "bundleID", value: entry.app.bundleID)]
                if let url = components.url { NSWorkspace.shared.open(url) }
            }
        }
    }
}

/// Minimal vnode watcher built on `DispatchSource`.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private let descriptor: Int32

    init?(url: URL, handler: @escaping @Sendable () -> Void) {
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: .global(qos: .utility))
        source.setEventHandler(handler: handler)
        let fd = descriptor
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

/// Reads the scan locations the main app stores in its defaults domain.
enum AppSettingsBridge {
    static var scanLocations: [String] {
        let defaults = UserDefaults(suiteName: HelperConstants.appBundleIdentifier)
        if let data = defaults?.data(forKey: "scanLocations"), let list = try? JSONDecoder().decode([String].self, from: data), !list.isEmpty { return list }
        return ["/Applications", NSHomeDirectory() + "/Applications"]
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let delegate = WatcherAppDelegate()
app.delegate = delegate
app.run()
