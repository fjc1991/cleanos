import SwiftUI
import CleanCore
import UpdateSources

@MainActor
@Observable
final class UpdatesModel {
    var updates: [AvailableUpdate] = []
    var isChecking = false
    var checkedAt: Date?
    /// Apps (or "Homebrew") whose last check failed, and whether the Mac was offline.
    var failed: [String] = []
    var isOffline = false
    var selectedID: String?
    var checked: Set<String> = []
    var busy: Set<String> = []
    var log: [String: String] = [:]
    let manager = UpdateManager()
    var appProvider: (@MainActor () async -> [InstalledApp])?

    func check(force: Bool = false) async {
        guard !isChecking else { return }
        if !force, let cached = await manager.cached() { show(cached); return }
        isChecking = true
        let apps = await appProvider?() ?? []
        let updatable = apps.map { app in
            UpdatableApp(bundleID: app.bundleID, name: app.name, appURL: app.url, shortVersion: app.version, buildVersion: app.build,
                         sparkleFeedURL: app.identity.sparkleFeedURL.flatMap(URL.init(string:)), hasMASReceipt: app.identity.hasMASReceipt)
        }
        let skip = Set((try? JSONDecoder().decode([String].self, from: UserDefaults.standard.data(forKey: SettingsKey.skipListUpdates) ?? Data())) ?? [])
        show(await manager.check(apps: updatable, skipList: skip))
        isChecking = false
    }

    private func show(_ snapshot: UpdateManager.Snapshot) {
        updates = snapshot.updates
        checkedAt = snapshot.checkedAt
        failed = snapshot.failed
        isOffline = snapshot.isOffline
    }

    /// Shown instead of "up to date" when some checks did not complete.
    var failureSummary: String? {
        if isOffline { return "No internet connection" }
        guard let first = failed.first else { return nil }
        return failed.count == 1 ? "Could not check \(first)" : "Could not check \(failed.count) apps"
    }

    var failedNames: String {
        let shown = failed.prefix(5).joined(separator: ", ")
        return failed.count > 5 ? "\(shown) and \(failed.count - 5) more" : shown
    }

    /// Sidebar badge: no "Up to date" when nothing was found because checks failed.
    var badgeCount: Int? { updates.isEmpty && failureSummary != nil ? nil : updates.count }

    var sections: [(title: String, updates: [AvailableUpdate])] {
        let apps = updates.filter { $0.origin != .homebrewFormula }
        let tools = updates.filter { $0.origin == .homebrewFormula }
        var out: [(String, [AvailableUpdate])] = []
        if !apps.isEmpty { out.append(("Applications", apps)) }
        if !tools.isEmpty { out.append(("Command-line tools", tools)) }
        return out
    }

    var selected: AvailableUpdate? { updates.first { $0.id == selectedID } }

    /// Only Homebrew installs the update itself; Sparkle apps are opened so their own updater installs the signed
    /// update, and App Store apps are updated by the App Store.
    static func actionTitle(for update: AvailableUpdate) -> String {
        switch update.origin {
        case .sparkle: "Open App"
        case .appStore: "Open App Store"
        case .homebrewCask, .homebrewFormula: "Upgrade"
        }
    }

    var bulkTitle: String {
        let picked = updates.filter { checked.contains($0.id) }
        let upgrades = picked.filter { $0.origin == .homebrewCask || $0.origin == .homebrewFormula }.count
        let opens = picked.count - upgrades
        return switch (upgrades, opens) {
        case (0, 0): "Upgrade Selected"
        case (_, 0): "Upgrade \(upgrades)"
        case (0, _): opens == 1 ? "Open 1 App" : "Open \(opens) Apps"
        default: "Upgrade \(upgrades), Open \(opens)"
        }
    }

    func apply(_ update: AvailableUpdate) async {
        switch update.origin {
        case .homebrewCask, .homebrewFormula:
            busy.insert(update.id)
            defer { busy.remove(update.id) }
            let (ok, output) = await HomebrewSource().upgrade(update)
            log[update.id] = output
            if ok {
                updates.removeAll { $0.id == update.id }
                checked.remove(update.id)
                await manager.remove(updateID: update.id)
            }
        case .appStore:
            NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
            log[update.id] = "Opened the App Store. Install the update from its Updates page."
        case .sparkle:
            guard let app = update.appURL else { return }
            NSWorkspace.shared.open(app)
            log[update.id] = "Opened \(update.displayName). Its built-in updater verifies and installs the update; if no prompt appears, choose Check for Updates… in its app menu."
        }
    }

    /// Secondary action for Sparkle rows: the enclosure (https only) in the browser, outside the app's signature check.
    func download(_ update: AvailableUpdate) {
        guard let url = update.downloadURL, url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
        log[update.id] = "Download opened in your browser. Unlike the app's own updater, CleanOS does not verify this file."
    }

    func applyChecked() async {
        let picked = updates.filter { checked.contains($0.id) }
        checked.removeAll()
        for update in picked { await apply(update) }
    }
}

struct UpdatesView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model = UpdatesModel()

    var body: some View {
        @Bindable var model = model
        SectionLayout(section: .updates) {
            if model.isChecking { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…").font(.callout).foregroundStyle(.secondary) } }
            else {
                if let warning = model.failureSummary, !model.updates.isEmpty {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).help(model.failed.joined(separator: ", "))
                }
                if let date = model.checkedAt { Text("Checked \(date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                Button { Task { await model.check(force: true) } } label: { Label("Check Now", systemImage: "arrow.clockwise") }
            }
        } primary: {
            if model.updates.isEmpty && !model.isChecking {
                if model.isOffline {
                    ContentUnavailableView("No internet connection", systemImage: "wifi.slash", description: Text("Connect to the internet, then choose Check Now."))
                } else if let summary = model.failureSummary {
                    ContentUnavailableView(summary, systemImage: "exclamationmark.triangle",
                                           description: Text("No updates were found for the other apps. Not checked: \(model.failedNames)."))
                } else {
                    ContentUnavailableView("Everything is up to date", systemImage: "checkmark.seal", description: Text("No updates were found for Sparkle apps, App Store apps or Homebrew."))
                }
            } else {
                List(selection: $model.selectedID) {
                    ForEach(model.sections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.updates) { update in
                                HStack(spacing: 8) {
                                    TriStateCheckbox(state: model.checked.contains(update.id) ? .all : .none) {
                                        if model.checked.contains(update.id) { model.checked.remove(update.id) } else { model.checked.insert(update.id) }
                                    }
                                    FileIcon(url: update.appURL, size: 24)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 6) {
                                            Text(update.displayName)
                                            Text(update.origin.title).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.primary.opacity(0.1)))
                                        }
                                        Text("\(update.installedVersion) → \(update.latestVersion)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.busy.contains(update.id) { ProgressView().controlSize(.small) }
                                }
                                .tag(update.id)
                                .contextMenu {
                                    Button(UpdatesModel.actionTitle(for: update)) { Task { await model.apply(update) } }.disabled(model.busy.contains(update.id))
                                    if update.origin == .sparkle, update.downloadURL != nil { Button("Download in Browser") { model.download(update) } }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
            }
        } detail: {
            if let update = model.selected {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        FileIcon(url: update.appURL, size: 48)
                        VStack(alignment: .leading) { Text(update.displayName).font(.title3.weight(.semibold)); Text(update.origin.title).foregroundStyle(.secondary) }
                    }
                    InfoSection(title: "Update") {
                        InfoRow("Installed", update.installedVersion)
                        InfoRow("Available", update.latestVersion)
                        if let app = update.appURL { InfoRow("Location", app.path) }
                        if let notes = update.releaseNotesURL { Link("Release notes", destination: notes).font(.callout) }
                    }
                    if let log = model.log[update.id] { ScrollView { Text(log).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 200).card() }
                    if update.origin == .sparkle {
                        Text("Opens \(update.displayName) so its own updater can download, verify and install the update.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button(UpdatesModel.actionTitle(for: update)) { Task { await model.apply(update) } }
                            .buttonStyle(PrimaryActionButtonStyle()).disabled(model.busy.contains(update.id))
                        if update.origin == .sparkle, update.downloadURL != nil {
                            Button("Download") { model.download(update) }.buttonStyle(.link).font(.callout)
                                .help("Downloads the update in your browser without the app's own signature check.")
                        }
                    }
                    Spacer()
                }
                .padding(16)
            } else {
                ContentUnavailableView("Updates", systemImage: "arrow.triangle.2.circlepath", description: Text("Update your applications to keep them running smoothly and avoid any issues."))
            }
        } footer: {
            Button(model.bulkTitle) { Task { await model.applyChecked() } }
                .buttonStyle(PrimaryActionButtonStyle()).disabled(model.checked.isEmpty)
        }
        .task { model.appProvider = { await appModel.installedApps() }; await model.check(); appModel.updateCount = model.badgeCount }
        .onChange(of: model.badgeCount) { _, count in appModel.updateCount = count }
        .onChange(of: appModel.rescanToken) { _, _ in Task { await model.check(force: true) } }
    }
}
