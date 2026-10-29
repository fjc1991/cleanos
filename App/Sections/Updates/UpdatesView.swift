import SwiftUI
import CleanCore
import UpdateSources

@MainActor
@Observable
final class UpdatesModel {
    var updates: [AvailableUpdate] = []
    var isChecking = false
    var checkedAt: Date?
    var selectedID: String?
    var checked: Set<String> = []
    var busy: Set<String> = []
    var log: [String: String] = [:]
    let manager = UpdateManager()
    var appProvider: (@MainActor () async -> [InstalledApp])?

    func check(force: Bool = false) async {
        guard !isChecking else { return }
        if !force, let cached = await manager.cached() { updates = cached.updates; checkedAt = cached.checkedAt; return }
        isChecking = true
        let apps = await appProvider?() ?? []
        let updatable = apps.map { app in
            UpdatableApp(bundleID: app.bundleID, name: app.name, appURL: app.url, shortVersion: app.version, buildVersion: app.build,
                         sparkleFeedURL: app.identity.sparkleFeedURL.flatMap(URL.init(string:)), hasMASReceipt: app.identity.hasMASReceipt)
        }
        let skip = Set((try? JSONDecoder().decode([String].self, from: UserDefaults.standard.data(forKey: SettingsKey.skipListUpdates) ?? Data())) ?? [])
        let snapshot = await manager.check(apps: updatable, skipList: skip)
        updates = snapshot.updates
        checkedAt = snapshot.checkedAt
        isChecking = false
    }

    var sections: [(title: String, updates: [AvailableUpdate])] {
        let apps = updates.filter { $0.origin != .homebrewFormula }
        let tools = updates.filter { $0.origin == .homebrewFormula }
        var out: [(String, [AvailableUpdate])] = []
        if !apps.isEmpty { out.append(("Applications", apps)) }
        if !tools.isEmpty { out.append(("Command-line tools", tools)) }
        return out
    }

    var selected: AvailableUpdate? { updates.first { $0.id == selectedID } }

    func apply(_ update: AvailableUpdate) async {
        busy.insert(update.id)
        defer { busy.remove(update.id) }
        switch update.origin {
        case .homebrewCask, .homebrewFormula:
            let (ok, output) = await HomebrewSource().upgrade(update)
            log[update.id] = output
            if ok { updates.removeAll { $0.id == update.id } }
        case .appStore:
            NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
            log[update.id] = "Opened the App Store updates page."
        case .sparkle:
            if let download = update.downloadURL {
                NSWorkspace.shared.open(download)
                log[update.id] = "Download started in your browser; open the file to install."
            } else if let app = update.appURL {
                NSWorkspace.shared.open(app)
                log[update.id] = "Opened the app; use its Check for Updates command."
            }
        }
    }

    func applyChecked() async {
        for update in updates where checked.contains(update.id) { await apply(update) }
        checked.removeAll()
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
                if let date = model.checkedAt { Text("Checked \(date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                Button { Task { await model.check(force: true) } } label: { Label("Check Now", systemImage: "arrow.clockwise") }
            }
        } primary: {
            if model.updates.isEmpty && !model.isChecking {
                ContentUnavailableView("Everything is up to date", systemImage: "checkmark.seal", description: Text("No updates were found for Sparkle apps, App Store apps or Homebrew."))
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
                    Button(update.origin == .appStore ? "Open App Store" : "Update") { Task { await model.apply(update) } }
                        .buttonStyle(PrimaryActionButtonStyle()).disabled(model.busy.contains(update.id))
                    Spacer()
                }
                .padding(16)
            } else {
                ContentUnavailableView("Updates", systemImage: "arrow.triangle.2.circlepath", description: Text("Update your applications to keep them running smoothly and avoid any issues."))
            }
        } footer: {
            Button(model.checked.isEmpty ? "Update" : "Update \(model.checked.count)") { Task { await model.applyChecked() } }
                .buttonStyle(PrimaryActionButtonStyle()).disabled(model.checked.isEmpty)
        }
        .task { model.appProvider = { await appModel.installedApps() }; await model.check(); appModel.updateCount = model.updates.count }
        .onChange(of: model.updates.count) { _, count in appModel.updateCount = count }
        .onChange(of: appModel.rescanToken) { _, _ in Task { await model.check(force: true) } }
    }
}
