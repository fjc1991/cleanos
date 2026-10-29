import SwiftUI
import CleanCore

/// State for the Applications section: installed apps, deep-dive results and the selection.
@MainActor
@Observable
final class ApplicationsModel {
    enum Tab: String, CaseIterable { case apps = "Apps", remains = "Remains" }
    enum Sort: String, CaseIterable, Identifiable {
        case name = "Name", size = "Size", lastOpened = "Last Opened"
        var id: String { rawValue }
    }

    var tab: Tab = .apps
    var apps: [InstalledApp] = []
    var isLoadingApps = false
    var loadedCount = 0
    var searchText = ""
    var sort: Sort = .name
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All apps", unused = "Not opened recently", large = "Over 1 GB", unsigned = "Not notarized", notAppStore = "Outside the App Store"
        var id: String { rawValue }
    }
    var filter: Filter = .all
    var selectedAppID: String?
    var checkedAppIDs: Set<String> = []
    var scans: [String: LeftoverScanResult] = [:]
    var scanning: Set<String> = []
    private var scanTasks: [String: Task<Void, Never>] = [:]
    var appSizes: [String: Int64] = [:]
    var expertMode = UserDefaults.standard.bool(forKey: "expertMode") { didSet { UserDefaults.standard.set(expertMode, forKey: "expertMode") } }
    var showLowConfidenceRemains = UserDefaults.standard.bool(forKey: "showLowConfidenceRemains") { didSet { UserDefaults.standard.set(showLowConfidenceRemains, forKey: "showLowConfidenceRemains") } }
    var expandedGroups: Set<String> = []
    let selection = SelectionStore()

    let locator = LeftoverLocator(registrations: RegistrationScanner())
    let remainsLocator = RemainsLocator(registrations: SystemRegistrationReader())
    let sizeCache = SizeCache()

    var remains: RemainsScanResult?
    var isScanningRemains = false
    var selectedRemainsID: String?
    var checkedRemainsIDs: Set<String> = []

    static var unusedThreshold: TimeInterval {
        let months = UserDefaults.standard.integer(forKey: SettingsKey.outdatedMonths)
        return Double(months > 0 ? months : 3) * 30 * 24 * 3600
    }

    // MARK: - Loading

    /// `provider` is the shared catalog on `AppModel`.
    func loadApps(force: Bool = false, provider: @MainActor (Bool) async -> [InstalledApp]) async {
        guard !isLoadingApps, apps.isEmpty || force else { return }
        isLoadingApps = true
        let found = await provider(force)
        apps = found
        isLoadingApps = false
        if selectedAppID == nil || !found.contains(where: { $0.id == selectedAppID }) { selectedAppID = sortedApps.first?.id }
        await computeSizes(for: found)
    }

    private func computeSizes(for apps: [InstalledApp]) async {
        await withTaskGroup(of: (String, Int64).self) { group in
            var iterator = apps.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard let app = iterator.next() else { return false }
                let cache = sizeCache
                group.addTask { (app.id, await cache.size(of: app.url).bytes) }
                return true
            }
            while running < 4, addNext() { running += 1 }
            for await (id, size) in group {
                appSizes[id] = size
                if !addNext() { running -= 1 }
            }
        }
    }

    func ensureScan(for app: InstalledApp, includeExecutable: Bool = true) async {
        if let running = scanTasks[app.id] { await running.value; return }
        guard scans[app.id] == nil else { return }
        scanning.insert(app.id)
        let others = apps
        let locator = locator
        let task = Task { [weak self] in
            let result = await locator.locate(app: app, otherApps: others, includeExecutable: includeExecutable, skipList: AppSettings.skipList)
            guard let self else { return }
            self.scans[app.id] = result
            self.scanning.remove(app.id)
            self.scanTasks[app.id] = nil
            self.selection.selectDefaults(in: result.groups, allowRoot: false)
            if self.expandedGroups.isEmpty { self.expandedGroups = Set(result.groups.prefix(4).map(\.id)) }
        }
        scanTasks[app.id] = task
        await task.value
    }

    /// Cancels a running deep dive; the locator returns what it found so far, marked partial.
    func stopScan(for app: InstalledApp) async {
        guard let task = scanTasks[app.id] else { return }
        task.cancel()
        await task.value
    }

    var scanningEffectiveApps: [InstalledApp] { apps.filter { effectiveAppIDs.contains($0.id) && scanning.contains($0.id) } }

    func stopAllEffectiveScans() async {
        for app in scanningEffectiveApps { await stopScan(for: app) }
    }

    func loadRemains(force: Bool = false) async {
        guard !isScanningRemains, remains == nil || force else { return }
        isScanningRemains = true
        if let old = remains { for group in old.groups { selection.deselect(in: [group]) } }
        let previous = await AppCatalog().loadSnapshot()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let result = await remainsLocator.locate(installed: apps, previouslyInstalled: previous, runningBundleIDs: running, skipList: AppSettings.skipList)
        remains = result
        isScanningRemains = false
        if selectedRemainsID == nil { selectedRemainsID = visibleRemains.first?.id }
    }

    /// Remains groups after the low-confidence filter.
    var visibleRemains: [ScanItem] {
        guard let remains else { return [] }
        return remains.groups.filter { showLowConfidenceRemains || $0.payload["confidence"] != "low" }
    }
    var hiddenRemainsCount: Int { (remains?.groups.count ?? 0) - visibleRemains.count }

    func setRemainsChecked(_ group: ScanItem, _ checked: Bool) {
        if checked {
            checkedRemainsIDs.insert(group.id)
            selection.selectDefaults(in: [group], allowRoot: false)
        } else {
            checkedRemainsIDs.remove(group.id)
            selection.deselect(in: [group])
        }
    }

    var selectedRemains: ScanItem? { remains?.groups.first { $0.id == selectedRemainsID } }

    var selectedRemainsItems: [ScanItem] {
        guard let remains else { return [] }
        return selection.selectedLeaves(in: remains.groups.filter { checkedRemainsIDs.contains($0.id) })
    }

    func rescan(app: InstalledApp) async {
        await stopScan(for: app)
        if let old = scans[app.id] { selection.deselect(in: old.groups) }
        scans[app.id] = nil
        await ensureScan(for: app)
    }

    func setChecked(_ app: InstalledApp, _ checked: Bool) {
        if checked {
            checkedAppIDs.insert(app.id)
            Task { await ensureScan(for: app) }
        } else {
            checkedAppIDs.remove(app.id)
            if let result = scans[app.id] { selection.deselect(in: result.groups) }
        }
    }

    // MARK: - Derived

    var sortedApps: [InstalledApp] {
        let filtered = apps.filter { app in
            guard searchText.isEmpty || app.name.localizedCaseInsensitiveContains(searchText) || app.bundleID.localizedCaseInsensitiveContains(searchText) else { return false }
            switch filter {
            case .all: return true
            case .unused: return isUnused(app)
            case .large: return (appSizes[app.id] ?? 0) >= 1_000_000_000
            case .unsigned: return app.identity.isNotarized != true
            case .notAppStore: return !app.identity.hasMASReceipt
            }
        }
        switch sort {
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: return filtered.sorted { (appSizes[$0.id] ?? 0) > (appSizes[$1.id] ?? 0) }
        case .lastOpened: return filtered.sorted { ($0.lastOpenedDate ?? .distantPast) > ($1.lastOpenedDate ?? .distantPast) }
        }
    }

    /// Rows for the list: developer groups with two or more apps become a header followed by their apps.
    var rows: [AppRow] {
        let groups = AppCatalog.developerGroups(sortedApps)
        var grouped: Set<String> = []
        var rows: [AppRow] = []
        for app in sortedApps {
            if let team = app.teamID, let members = groups[team], members.count >= 2 {
                if grouped.contains(team) { continue }
                grouped.insert(team)
                let name = (app.developerName ?? members[0].name) + " Group"
                rows.append(.group(id: team, name: name, apps: members))
                for member in members { rows.append(.app(member, indented: true)) }
            } else {
                rows.append(.app(app, indented: false))
            }
        }
        return rows
    }

    enum AppRow: Identifiable {
        case group(id: String, name: String, apps: [InstalledApp])
        case app(InstalledApp, indented: Bool)
        var id: String {
            switch self {
            case .group(let id, _, _): "group:\(id)"
            case .app(let app, _): app.id
            }
        }
    }

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedAppID } }
    func isUnused(_ app: InstalledApp) -> Bool {
        guard let last = app.lastOpenedDate else { return false }
        return Date().timeIntervalSince(last) > Self.unusedThreshold
    }

    /// Apps the Uninstall button acts on: the checked ones, or the highlighted one when nothing is checked.
    var effectiveAppIDs: Set<String> {
        if !checkedAppIDs.isEmpty { return checkedAppIDs }
        return selectedAppID.map { [$0] } ?? []
    }

    /// Everything currently selected across the effective apps, grouped per app.
    var selectedPerApp: [(app: InstalledApp, items: [ScanItem])] {
        effectiveAppIDs.compactMap { id -> (InstalledApp, [ScanItem])? in
            guard let app = apps.first(where: { $0.id == id }), let result = scans[id] else { return nil }
            let items = selection.selectedLeaves(in: result.groups)
            return items.isEmpty ? nil : (app, items)
        }
        .sorted { $0.0.name < $1.0.name }
    }

    var selectedItems: [ScanItem] { selectedPerApp.flatMap(\.items) }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func isRunning(_ app: InstalledApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    /// Quits the app politely, force-quits it if it does not react, then kills every helper, agent and XPC service
    /// that still runs from inside the bundle. Returns false only when a process of another user survives.
    func quit(_ app: InstalledApp) async -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        for process in running { process.terminate() }
        for _ in 0..<12 where !running.allSatisfy(\.isTerminated) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        for process in running where !process.isTerminated { process.forceTerminate() }
        let survivors = await ProcessMonitor.forceStop(bundlePath: app.url.standardizedFileURL.path)
        return survivors.isEmpty
    }

    /// Processes currently running from inside the bundle, for the review sheet.
    func backgroundProcesses(of app: InstalledApp) -> [RunningProcess] {
        ProcessMonitor.processes(inBundle: app.url.standardizedFileURL.path)
    }

    func finishedRemoval(of result: RemovalResult) {
        let removedAppPaths = Set(result.succeeded.filter { $0.kind == .bundle }.compactMap { $0.url?.path })
        for app in apps where removedAppPaths.contains(app.url.path) {
            scans[app.id] = nil
            checkedAppIDs.remove(app.id)
            appSizes[app.id] = nil
        }
        apps.removeAll { removedAppPaths.contains($0.url.path) }
        for id in checkedAppIDs { scans[id] = nil }
        selection.clear()
        checkedRemainsIDs.removeAll()
        remains = nil
        if let selectedAppID, !apps.contains(where: { $0.id == selectedAppID }) { self.selectedAppID = sortedApps.first?.id }
        Task { for app in apps where checkedAppIDs.contains(app.id) { await ensureScan(for: app) } }
    }
}

/// Typed access to the settings the engine needs.
enum AppSettings {
    static var scanLocations: [String] {
        if let data = UserDefaults.standard.data(forKey: SettingsKey.scanLocations),
           let list = try? JSONDecoder().decode([String].self, from: data), !list.isEmpty { return list }
        if let list = UserDefaults.standard.stringArray(forKey: SettingsKey.scanLocations), !list.isEmpty { return list }
        return SettingsKey.defaultScanLocations
    }
    static var skipList: [String] {
        if let data = UserDefaults.standard.data(forKey: SettingsKey.skipList),
           let list = try? JSONDecoder().decode([String].self, from: data) { return list }
        return UserDefaults.standard.stringArray(forKey: SettingsKey.skipList) ?? []
    }
    static func addToSkipList(_ path: String) {
        var list = skipList
        guard !list.contains(path) else { return }
        list.append(path)
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: SettingsKey.skipList)
    }
    static var removesPermanently: Bool {
        UserDefaults.standard.string(forKey: SettingsKey.removalMethod) == "permanent"
    }
}
