import SwiftUI
import CleanCore

struct CleanUpView: View {
    @Environment(AppModel.self) private var appModel
    @State private var removalFlow: RemovalFlow?

    private var model: CleanUpModel { appModel.cleanUp }

    var body: some View {
        @Bindable var model = appModel.cleanUp
        SectionLayout(section: .cleanUp) {
            Picker(selection: Binding(get: { model.scope }, set: { model.scope = $0; Task { await model.scanAll(volumes: appModel.volumes, force: true) } })) {
                Label("All disks", systemImage: "externaldrive.connected.to.line.below").tag(CleanUpModel.Scope.allDisks)
                Divider()
                ForEach(appModel.volumes) { volume in
                    Label(volume.name, systemImage: volume.isRoot ? "internaldrive" : "externaldrive").tag(CleanUpModel.Scope.volume(volume.id))
                }
            } label: { Text("Disk") }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Which disks the Bin, Purgeable space, External disk junk and Installation files categories look at")
            if model.isScanning {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scanning…").font(.callout).foregroundStyle(.secondary) }
            } else {
                Button { Task { await model.scanAll(volumes: appModel.volumes, force: true) } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            }
        } primary: {
            ScrollView {
                VStack(spacing: 2) {
                    if appModel.fullDiskAccess != .granted {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lock.shield").foregroundStyle(Theme.warning)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Full Disk Access is off").font(.callout.weight(.semibold))
                                Text("The Bin, Mail attachments, Safari caches and hidden folders on external disks can't be read until you allow it.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Allow in System Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }.font(.caption)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.warning.opacity(0.12)))
                        .padding(.bottom, 6)
                    }
                    ForEach(model.categories) { category in
                        HStack(spacing: 10) {
                            TriStateCheckbox(state: model.state(for: category), isEnabled: model.results[category.id] != nil) { model.toggle(category: category) }
                            Image(systemName: category.systemImage).frame(width: 22).foregroundStyle(Theme.accent)
                            Text(category.title)
                            Spacer()
                            if model.scanning.contains(category.id) {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text(model.sizeText(for: category)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(model.selectedCategoryID == category.id ? Theme.accent.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedCategoryID = category.id }
                    }
                }
                .padding(8)
            }
        } detail: {
            if let id = model.selectedCategoryID, let category = model.categories.first(where: { $0.id == id }) {
                CategoryDetailView(category: category)
            } else {
                EmptyDetailView()
            }
        } footer: {
            if !model.selectedItems.isEmpty {
                Text("\(model.selectedItems.count) items · \(model.selectedSize.formattedBytes)")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary).padding(.trailing, 8)
            }
            Button(AppSection.cleanUp.actionTitle) {
                removalFlow = RemovalFlow(title: "Clean Up", apps: [], items: model.selectedItems, quit: { true })
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(model.selectedItems.isEmpty)
        }
        .task { model.appProvider = { await appModel.installedApps() }; await model.scanAll(volumes: appModel.volumes) }
        .onChange(of: appModel.rescanToken) { _, _ in Task { await model.scanAll(volumes: appModel.volumes, force: true) } }
        .onChange(of: appModel.fullDiskAccess) { old, new in
            if old != .granted, new == .granted { Task { await model.scanAll(volumes: appModel.volumes, force: true) } }
        }
        .sheet(item: $removalFlow) { flow in
            RemovalSheet(flow: flow) { result in model.finishedRemoval(result, volumes: appModel.volumes) }
                .environment(appModel)
        }
    }
}

/// Right pane of Clean Up: description, totals and the item tree for one category.
struct CategoryDetailView: View {
    @Environment(AppModel.self) private var appModel
    let category: CleanupCategoryInfo

    var body: some View {
        @Bindable var model = appModel.cleanUp
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: category.systemImage).font(.title2).foregroundStyle(Theme.accent)
                    Text(category.title).font(.title3.weight(.semibold))
                    Spacer()
                    if let result = model.results[category.id] {
                        Text("\(result.leafCount) items · \(result.totalSize.formattedBytes)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Button { Task { await model.rescan(categoryID: category.id, volumes: appModel.volumes) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(model.scanning.contains(category.id))
                }
                Text(category.description).font(.callout).foregroundStyle(.secondary)
                if category.tier == .caution {
                    Label("Items in this category are not selected by default.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
                }
            }
            .padding(16)
            Divider().padding(.horizontal, 16)
            if let result = model.results[category.id] {
                if result.items.isEmpty {
                    ContentUnavailableView("Nothing to clean", systemImage: "checkmark.circle", description: Text("No \(category.title.lowercased()) were found."))
                } else {
                    SelectAllHeader(items: result.items, selection: model.selection)
                    ScanTreeView(items: result.items, selection: model.selection, expanded: $model.expanded)
                }
            } else if model.scanning.contains(category.id) {
                VStack(spacing: 10) { ProgressView(); Text("Scanning \(category.title.lowercased())…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyDetailView(title: "Not scanned yet", systemImage: "magnifyingglass")
            }
        }
    }
}
