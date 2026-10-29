import SwiftUI
import CleanCore

/// Runs the Clean Up scanners and keeps their results; shared by the Clean Up section and the Overview.
@MainActor
@Observable
final class CleanUpModel {
    var results: [String: CleanupResult] = [:]
    var scanning: Set<String> = []
    var selectedCategoryID: String? = CleanupEngine.categories.first?.id
    var expanded: Set<String> = []
    var lastScan: Date?
    let selection = SelectionStore()
    let engine = CleanupEngine()
    var installedApps: [InstalledApp] = []

    /// Which disks the per-volume categories (Bin, Purgeable space, External disk junk, installers) look at.
    enum Scope: Hashable { case allDisks, volume(String) }
    var scope: Scope = {
        if let id = UserDefaults.standard.string(forKey: "cleanUpScope"), id != "all" { return .volume(id) }
        return .allDisks
    }() {
        didSet {
            switch scope {
            case .allDisks: UserDefaults.standard.set("all", forKey: "cleanUpScope")
            case .volume(let id): UserDefaults.standard.set(id, forKey: "cleanUpScope")
            }
        }
    }

    func scopeTitle(volumes: [VolumeInfo]) -> String {
        switch scope {
        case .allDisks: return "All disks"
        case .volume(let id): return volumes.first { $0.id == id }?.name ?? "All disks"
        }
    }

    var categories: [CleanupCategoryInfo] { CleanupEngine.categories }
    var isScanning: Bool { !scanning.isEmpty }

    /// Supplied by the section views from `AppModel.installedApps()`.
    var appProvider: (@MainActor () async -> [InstalledApp])?

    func makeContext(volumes: [VolumeInfo]) async -> CleanupContext {
        if let appProvider { installedApps = await appProvider() }
        let enabled: Set<String>
        let includeRoot: Bool
        switch scope {
        case .allDisks:
            enabled = Set(volumes.filter { !$0.isRoot }.map(\.id))
            includeRoot = true
        case .volume(let id):
            if let volume = volumes.first(where: { $0.id == id }), !volume.isRoot { enabled = [id]; includeRoot = false } else { enabled = []; includeRoot = true }
        }
        return CleanupContext(volumes: volumes, enabledVolumeIDs: enabled, installedApps: installedApps,
                              runningBundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)), includeRootVolume: includeRoot)
    }

    /// Scans every category (three at a time) and selects the default items as results arrive.
    func scanAll(volumes: [VolumeInfo], force: Bool = false) async {
        guard force || results.isEmpty, scanning.isEmpty else { return }
        if force { for result in results.values { selection.deselect(in: result.items) }; results.removeAll() }
        let context = await makeContext(volumes: volumes)
        let ids = categories.map(\.id)
        scanning = Set(ids)
        await withTaskGroup(of: (String, CleanupResult?).self) { group in
            var iterator = ids.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard let id = iterator.next() else { return false }
                let engine = engine
                group.addTask { (id, await engine.scan(categoryID: id, context: context)) }
                return true
            }
            while running < 3, addNext() { running += 1 }
            for await (id, result) in group {
                if let result {
                    results[id] = result
                    selection.selectDefaults(in: result.items, allowRoot: false)
                }
                scanning.remove(id)
                if !addNext() { running -= 1 }
            }
        }
        lastScan = .now
    }

    func rescan(categoryID: String, volumes: [VolumeInfo]) async {
        guard !scanning.contains(categoryID) else { return }
        if let old = results[categoryID] { selection.deselect(in: old.items) }
        scanning.insert(categoryID)
        let context = await makeContext(volumes: volumes)
        if let result = await engine.scan(categoryID: categoryID, context: context) {
            results[categoryID] = result
            selection.selectDefaults(in: result.items, allowRoot: false)
        }
        scanning.remove(categoryID)
    }

    func sizeText(for category: CleanupCategoryInfo) -> String {
        if scanning.contains(category.id) { return "…" }
        guard let result = results[category.id] else { return "–" }
        return result.totalSize == 0 ? "–" : result.totalSize.formattedBytes
    }

    func state(for category: CleanupCategoryInfo) -> SelectionState {
        guard let result = results[category.id] else { return .none }
        let states = result.items.map { selection.state(of: $0) }
        if states.isEmpty || states.allSatisfy({ $0 == .none }) { return .none }
        if states.allSatisfy({ $0 == .all }) { return .all }
        return .partial
    }

    func toggle(category: CleanupCategoryInfo) {
        guard let result = results[category.id] else { return }
        if state(for: category) == .all { selection.deselect(in: result.items) } else { for item in result.items { selection.set(item, selected: true) } }
    }

    var allItems: [ScanItem] { results.values.flatMap(\.items) }
    var selectedItems: [ScanItem] { selection.selectedLeaves(in: allItems) }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    /// Junk total shown on the Overview: everything selectable by default (caches, logs, trash, installers…).
    var junkTotal: Int64 {
        results.values.flatMap { $0.items.flatMap(\.leaves) }.filter { $0.tier.isSelectableByDefault }.reduce(0) { $0 + $1.size }
    }

    func finishedRemoval(_ result: RemovalResult, volumes: [VolumeInfo]) {
        selection.clear()
        Task { await scanAll(volumes: volumes, force: true) }
    }
}
