import SwiftUI
import CleanCore

@MainActor
@Observable
final class StartupModel {
    var items: [StartupItem] = []
    var isLoading = false
    var selectedID: String?
    var searchText = ""
    var busy: Set<String> = []
    var errors: [String: String] = [:]
    let scanner = StartupScanner()
    var appProvider: (@MainActor () async -> [InstalledApp])?

    func load(force: Bool = false) async {
        guard !isLoading, items.isEmpty || force else { return }
        isLoading = true
        let apps = await appProvider?() ?? []
        items = await scanner.scan(installedApps: apps)
        isLoading = false
        if selectedID == nil { selectedID = items.first?.id }
    }

    var filtered: [StartupItem] {
        items.filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) || $0.label.localizedCaseInsensitiveContains(searchText) }
    }

    var enabledCount: Int { items.filter(\.isEnabled).count }
    var selected: StartupItem? { items.first { $0.id == selectedID } }

    func setEnabled(_ item: StartupItem, _ enabled: Bool, helper: HelperClient) async {
        busy.insert(item.id)
        let controller = StartupController(runAsRoot: helper.isAvailable ? helper.rootRunner() : nil)
        if let error = await controller.setEnabled(item, enabled) {
            errors[item.id] = error
        } else {
            errors[item.id] = nil
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].isEnabled = enabled; items[index].isLoaded = enabled }
        }
        busy.remove(item.id)
    }
}

struct StartupView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model = StartupModel()
    @State private var removalFlow: RemovalFlow?

    var body: some View {
        @Bindable var model = model
        SectionLayout(section: .startup) {
            Text("\(model.enabledCount) enabled").font(.callout).foregroundStyle(.secondary)
        } primary: {
            VStack(spacing: 0) {
                TextField("Search startup programs", text: $model.searchText).textFieldStyle(.roundedBorder).padding(10)
                Divider()
                if model.isLoading && model.items.isEmpty {
                    VStack(spacing: 10) { ProgressView(); Text("Reading launch agents and login items…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $model.selectedID) {
                        ForEach(model.filtered) { item in
                            StartupRow(model: model, item: item).tag(item.id)
                        }
                    }
                    .listStyle(.inset).scrollContentBackground(.hidden)
                }
                Divider()
                HStack {
                    Text("\(model.items.count) items").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Rescan") { Task { await model.load(force: true) } }.buttonStyle(.link).font(.caption)
                }
                .padding(8)
            }
        } detail: {
            if let item = model.selected {
                StartupDetailView(model: model, item: item, onRemove: { startRemoval(item) })
            } else {
                ContentUnavailableView("Startup Programs", systemImage: "paperplane.fill", description: Text("Programs and processes that automatically run when you log in to your Mac."))
            }
        } footer: {
            if let item = model.selected, item.canToggle {
                Button(item.isEnabled ? "Disable" : "Enable") { Task { await model.setEnabled(item, !item.isEnabled, helper: appModel.helper) } }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(model.busy.contains(item.id))
            }
        }
        .task { model.appProvider = { await appModel.installedApps() }; await model.load(); appModel.startupEnabledCount = model.enabledCount }
        .onChange(of: model.enabledCount) { _, count in appModel.startupEnabledCount = count }
        .onChange(of: appModel.rescanToken) { _, _ in Task { await model.load(force: true) } }
        .sheet(item: $removalFlow) { flow in
            RemovalSheet(flow: flow) { _ in Task { await model.load(force: true) } }.environment(appModel)
        }
    }

    private func startRemoval(_ item: StartupItem) {
        guard let plist = item.plistURL else { return }
        let scan = ScanItem(url: plist, title: plist.lastPathComponent, subtitle: item.label, kind: .file, group: "Login Items",
                            size: Int64((try? plist.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), tier: .normal,
                            matchedBy: ["startup item"], needsRoot: item.needsRoot)
        removalFlow = RemovalFlow(title: "Remove startup item", apps: [], items: [scan], quit: {
            _ = await StartupController(runAsRoot: appModel.helper.isAvailable ? appModel.helper.rootRunner() : nil).setEnabled(item, false)
            return true
        })
    }
}

struct StartupRow: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var model: StartupModel
    let item: StartupItem

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(url: item.ownerAppURL ?? item.plistURL, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(item.kind.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy.contains(item.id) {
                ProgressView().controlSize(.small)
            } else if item.canToggle {
                Toggle("", isOn: Binding(get: { item.isEnabled }, set: { value in Task { await model.setEnabled(item, value, helper: appModel.helper) } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            } else {
                Image(systemName: item.isEnabled ? "checkmark.circle.fill" : "circle").foregroundStyle(item.isEnabled ? Theme.success : .secondary)
                    .help("Managed in System Settings")
            }
        }
        .padding(.vertical, 2)
    }
}

struct StartupDetailView: View {
    @Bindable var model: StartupModel
    let item: StartupItem
    var onRemove: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    FileIcon(url: item.ownerAppURL ?? item.plistURL, size: 48)
                    VStack(alignment: .leading) {
                        Text(item.title).font(.title3.weight(.semibold))
                        Text(item.kind.rawValue).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(item.isEnabled ? "Enabled" : "Disabled", systemImage: item.isEnabled ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(item.isEnabled ? Theme.success : .secondary)
                }
                if let error = model.errors[item.id] { Text(error).font(.callout).foregroundStyle(Theme.danger) }
                InfoSection(title: "Details") {
                    InfoRow("Label", item.label)
                    if let program = item.programPath { InfoRow("Program", program) }
                    if let plist = item.plistURL { InfoRow("Property list", plist.path) }
                    InfoRow("State", item.isLoaded ? (item.pid.map { "Running (pid \($0))" } ?? "Loaded") : "Not loaded")
                    if let owner = item.ownerName { InfoRow("Owner", owner) }
                    if item.needsRoot { InfoRow("Privileges", "Administrator (helper)") }
                }
                if item.managedBySystemSettings {
                    Label("Login items registered by apps are managed in System Settings → General → Login Items & Extensions.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Login Items Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
                }
                HStack {
                    if let plist = item.plistURL {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([plist]) }
                        Button("Remove…", role: .destructive) { onRemove() }
                    } else if let app = item.ownerAppURL {
                        Button("Reveal App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                    }
                }
            }
            .padding(16)
        }
    }
}
