import SwiftUI
import CleanCore
import UniformTypeIdentifiers

struct ApplicationsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model = ApplicationsModel()
    @State private var removalFlow: RemovalFlow?
    @State private var dropTargeted = false
    @State private var askStopSearch = false

    var body: some View {
        @Bindable var model = model
        SectionLayout(section: .applications) {
            Toggle("Expert Mode", isOn: $model.expertMode).toggleStyle(.switch).controlSize(.small)
        } primary: {
            AppListPane(model: model)
        } detail: {
            detailPane
        } footer: {
            if model.tab == .apps {
                let stillScanning = model.scanningEffectiveApps
                if !stillScanning.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching files of \(stillScanning.map(\.name).joined(separator: ", "))…").font(.callout).foregroundStyle(.secondary)
                        Button("Stop Search") { Task { await model.stopAllEffectiveScans() } }.controlSize(.small)
                    }
                    .padding(.trailing, 8)
                } else if !model.selectedItems.isEmpty {
                    Text("\(model.selectedItems.count) items · \(model.selectedSize.formattedBytes)")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                }
                Button(model.checkedAppIDs.count > 1 ? "Uninstall \(model.checkedAppIDs.count)" : "Uninstall") {
                    if stillScanning.isEmpty { startRemoval(title: "Uninstall") } else { askStopSearch = true }
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(model.selectedItems.isEmpty && stillScanning.isEmpty)
                .confirmationDialog("CleanOS is still searching for files of \(stillScanning.map(\.name).joined(separator: ", ")).", isPresented: $askStopSearch, titleVisibility: .visible) {
                    Button("Stop Search and Uninstall") { Task { await model.stopAllEffectiveScans(); startRemoval(title: "Uninstall") } }
                    Button("Keep Searching", role: .cancel) { }
                } message: {
                    Text("You can stop the search and uninstall with what has been found so far (the app itself is always included), or wait for the full list.")
                }
            } else {
                let items = model.selectedRemainsItems
                if !items.isEmpty {
                    Text("\(items.count) items · \(items.reduce(0) { $0 + $1.size }.formattedBytes)")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                }
                Button("Remove") {
                    removalFlow = RemovalFlow(title: "Remove remains", apps: [], items: items, quit: { true })
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(items.isEmpty)
            }
        }
        .task { await model.loadApps(provider: { force in await appModel.installedApps(force: force) }) }
        .onChange(of: appModel.rescanToken) { _, _ in Task { await model.loadApps(force: true, provider: { force in await appModel.installedApps(force: force) }); if model.tab == .remains { await model.loadRemains(force: true) } } }
        .onChange(of: model.remains?.groups.count) { _, _ in appModel.remainsHighConfidenceCount = model.remains?.groups.filter { $0.payload["confidence"] == "high" }.count }
        .task(id: appModel.pendingRemainsBundleID) {
            guard let bundleID = appModel.pendingRemainsBundleID else { return }
            appModel.pendingRemainsBundleID = nil
            model.tab = .remains
            await model.loadRemains(force: true)
            let key = bundleID.lowercased().split(separator: ".").dropFirst().prefix(2).joined(separator: ".")
            if let group = model.remains?.groups.first(where: { $0.title.lowercased() == key || $0.id.lowercased().contains(bundleID.lowercased()) }) {
                model.selectedRemainsID = group.id
                model.setRemainsChecked(group, true)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .overlay { Label("Drop an application to uninstall it", systemImage: "arrow.down.app").font(.title3) }
                    .padding(20)
                    .background(Color.black.opacity(0.15))
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $removalFlow) { flow in
            RemovalSheet(flow: flow) { result in
                model.finishedRemoval(of: result)
            }
            .environment(appModel)
        }
    }

    @ViewBuilder private var detailPane: some View {
        switch model.tab {
        case .apps:
            if let app = model.selectedApp {
                AppDetailView(model: model, app: app, onReset: { startRemoval(title: "Reset", resetting: app) })
            } else if model.isLoadingApps {
                ContentUnavailableView("Scanning applications… \(model.loadedCount) found", systemImage: "app.badge.checkmark")
            } else {
                ContentUnavailableView("Uninstall applications", systemImage: "app.badge.checkmark",
                                       description: Text("Select applications. Review service files.\nUninstall any application completely."))
            }
        case .remains:
            if let group = model.selectedRemains {
                RemainsDetailView(model: model, group: group)
            } else if model.isScanningRemains {
                ContentUnavailableView("Looking for files left behind by deleted apps…", systemImage: "doc.badge.clock")
            } else {
                ContentUnavailableView("Remaining files", systemImage: "doc.badge.clock",
                                       description: Text("Unneeded service files left after deleted applications.\nSelect remains to review and remove them."))
            }
        }
    }

    private func startRemoval(title: String, resetting app: InstalledApp? = nil) {
        if let app {
            removalFlow = RemovalFlow(title: "Reset \(app.name)", apps: [app], items: model.scans[app.id]?.allItems.filter { $0.kind != .bundle && $0.tier.isSelectableByDefault && !$0.needsRoot } ?? [],
                                      quit: { await model.quit(app) })
        } else {
            let perApp = model.selectedPerApp
            removalFlow = RemovalFlow(title: title, apps: perApp.map(\.app), items: perApp.flatMap(\.items), quit: {
                for app in perApp.map(\.app) where model.isRunning(app) { _ = await model.quit(app) }
                return true
            })
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), url.pathExtension == "app" else { return }
                Task { @MainActor in
                    if let existing = model.apps.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                        model.selectedAppID = existing.id
                        model.setChecked(existing, true)
                    } else if let identity = AppInspector.inspect(bundleURL: url, shared: Rules.bundled.shared) {
                        let app = InstalledApp(url: url, name: identity.name, bundleID: identity.bundleID, version: nil, build: nil, isSystem: false,
                                               modificationDate: nil, creationDate: nil, lastOpenedDate: nil, identity: identity)
                        model.apps.append(app)
                        model.selectedAppID = app.id
                        model.setChecked(app, true)
                    }
                }
            }
            return true
        }
        return false
    }
}

/// Left column: Apps/Remains switch, search, sort and the app list with checkboxes.
struct AppListPane: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var model: ApplicationsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $model.tab) {
                    ForEach(ApplicationsModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                .onChange(of: model.tab) { _, tab in if tab == .remains { Task { await model.loadRemains() } } }
                Spacer()
                if model.tab == .apps {
                    Menu {
                        Picker("Filter", selection: $model.filter) {
                            ForEach(ApplicationsModel.Filter.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Label(model.filter == .all ? "Filter" : model.filter.rawValue, systemImage: "line.3.horizontal.decrease.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Menu {
                    Picker("Sort", selection: $model.sort) {
                        ForEach(ApplicationsModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label(model.sort.rawValue, systemImage: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(10)
            TextField("Search applications", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            Divider()
            if model.tab == .apps {
                List(selection: $model.selectedAppID) {
                    ForEach(model.rows) { row in
                        switch row {
                        case .group(_, let name, let apps):
                            HStack(spacing: 8) {
                                TriStateCheckbox(state: groupState(apps)) {
                                    let allChecked = apps.allSatisfy { model.checkedAppIDs.contains($0.id) }
                                    for app in apps { model.setChecked(app, !allChecked) }
                                }
                                Image(systemName: "folder.fill").foregroundStyle(Theme.accent).frame(width: 28)
                                VStack(alignment: .leading) {
                                    Text(name).font(.callout.weight(.semibold))
                                    Text("\(apps.count) Applications").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(apps.compactMap { model.appSizes[$0.id] }.reduce(0, +).formattedBytes)
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .selectionDisabled()
                        case .app(let app, let indented):
                            AppListRow(model: model, app: app, indented: indented).tag(app.id)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .bottom) {
                    if model.isLoadingApps {
                        ProgressView().controlSize(.small).padding(8)
                    }
                }
                .onChange(of: model.selectedAppID) { _, newValue in
                    if let app = model.apps.first(where: { $0.id == newValue }) { Task { await model.ensureScan(for: app) } }
                }
            } else {
                RemainsListPane(model: model)
            }
            Divider()
            HStack {
                if model.tab == .apps {
                    Text("\(model.apps.count) Applications").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Rescan") { appModel.rescanEverything() }.buttonStyle(.link).font(.caption)
                } else {
                    Text("\(model.remains?.groups.count ?? 0) groups · \((model.remains?.totalSize ?? 0).formattedBytes)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Rescan") { Task { await model.loadRemains(force: true) } }.buttonStyle(.link).font(.caption)
                }
            }
            .padding(8)
        }
    }
}

extension AppListPane {
    /// Checkbox state of a developer group: all, some or none of its apps checked.
    func groupState(_ apps: [InstalledApp]) -> SelectionState {
        let count = apps.filter { model.checkedAppIDs.contains($0.id) }.count
        return count == 0 ? .none : (count == apps.count ? .all : .partial)
    }
}

struct AppListRow: View {
    @Bindable var model: ApplicationsModel
    let app: InstalledApp
    var indented: Bool

    var body: some View {
        HStack(spacing: 8) {
            TriStateCheckbox(state: model.checkedAppIDs.contains(app.id) ? .all : .none) {
                model.setChecked(app, !model.checkedAppIDs.contains(app.id))
            }
            FileIcon(url: app.url, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(app.name).lineLimit(1)
                    if model.isUnused(app) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).font(.caption)
                            .help("Not opened for more than 3 months")
                    }
                }
                if let last = app.lastOpenedDate {
                    Text(last, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(app.version ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if let size = model.appSizes[app.id] {
                    Text(size.formattedBytes).font(.callout.monospacedDigit())
                } else {
                    Text("…").foregroundStyle(.tertiary)
                }
                if model.scanning.contains(app.id) {
                    Text("Scanning…").font(.caption2).foregroundStyle(.secondary)
                } else if let result = model.scans[app.id] {
                    Text("\(result.itemCount - 1) service files").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, indented ? 18 : 0)
        .padding(.vertical, 2)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            Button("Add to Skip List") { AppSettings.addToSkipList(app.url.path); model.apps.removeAll { $0.id == app.id } }
            Button("Rescan Service Files") { Task { await model.rescan(app: app) } }
        }
    }
}


/// Left column for the Remains tab: one row per orphaned app.
struct RemainsListPane: View {
    @Bindable var model: ApplicationsModel

    var body: some View {
        if let remains = model.remains {
            if remains.groups.isEmpty {
                ContentUnavailableView("No remains found", systemImage: "checkmark.circle", description: Text("No leftovers of deleted apps were found."))
            } else {
                List(selection: $model.selectedRemainsID) {
                    ForEach(model.visibleRemains.filter { model.searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(model.searchText) }) { group in
                        HStack(spacing: 8) {
                            TriStateCheckbox(state: model.checkedRemainsIDs.contains(group.id) ? model.selection.state(of: group) : .none) {
                                model.setRemainsChecked(group, !model.checkedRemainsIDs.contains(group.id))
                            }
                            Image(systemName: "doc.badge.clock").foregroundStyle(Theme.accent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(group.title).lineLimit(1)
                                    ConfidenceBadge(raw: group.payload["confidence"])
                                }
                                Text(group.subtitle ?? "\(group.children.count) items").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(group.size.formattedBytes).font(.callout.monospacedDigit())
                        }
                        .padding(.vertical, 2)
                        .tag(group.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .bottom) {
                    if model.hiddenRemainsCount > 0 || model.showLowConfidenceRemains {
                        HStack(spacing: 6) {
                            Toggle("Show low-confidence groups", isOn: Binding(get: { model.showLowConfidenceRemains }, set: { model.showLowConfidenceRemains = $0 }))
                                .toggleStyle(.checkbox).font(.caption)
                            if model.hiddenRemainsCount > 0 { Text("(\(model.hiddenRemainsCount) hidden)").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                        }
                        .padding(8)
                        .background(.ultraThinMaterial)
                    }
                }
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Searching for leftovers of deleted apps…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Right pane for a Remains group: its files grouped by location.
struct RemainsDetailView: View {
    @Bindable var model: ApplicationsModel
    let group: ScanItem

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.clock").font(.largeTitle).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(group.title).font(.title3.weight(.semibold))
                        ConfidenceBadge(raw: group.payload["confidence"])
                    }
                    Text("\(group.children.count) items · \(group.size.formattedBytes)").foregroundStyle(.secondary)
                    Text(Array(Set(group.children.flatMap { $0.matchedBy.prefix(1) })).sorted().prefix(3).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
                Spacer()
                TriStateCheckbox(state: model.checkedRemainsIDs.contains(group.id) ? model.selection.state(of: group) : .none) {
                    model.setRemainsChecked(group, !model.checkedRemainsIDs.contains(group.id))
                }
                Text("Select all").font(.callout)
            }
            .padding(16)
            Divider().padding(.horizontal, 16)
            let sections = Dictionary(grouping: group.children, by: \.group)
            List {
                ForEach(sections.keys.sorted { LeftoverGroups.rank($0) < LeftoverGroups.rank($1) }, id: \.self) { name in
                    Section {
                        ForEach(sections[name] ?? []) { item in
                            ScanItemRow(item: item, selection: model.selection)
                                .onChange(of: model.selection.state(of: item)) { _, state in
                                    if state != .none { model.checkedRemainsIDs.insert(group.id) }
                                }
                        }
                    } header: {
                        HStack {
                            Text(name)
                            Spacer()
                            Text((sections[name] ?? []).reduce(0) { $0 + $1.size }.formattedBytes).monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}


/// Small badge for the Remains confidence (High / Medium / Low).
struct ConfidenceBadge: View {
    let raw: String?
    var body: some View {
        if let raw, let confidence = RemainsConfidence(rawValue: raw) {
            Text(confidence.rawValue.capitalized)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(color(confidence).opacity(0.18)))
                .foregroundStyle(color(confidence))
                .help("\(confidence.title): how sure CleanOS is that these files belong to software that is no longer installed")
        }
    }
    private func color(_ confidence: RemainsConfidence) -> Color {
        switch confidence {
        case .high: Theme.success
        case .medium: Theme.accent
        case .low: Theme.warning
        }
    }
}
