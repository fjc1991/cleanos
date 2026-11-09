import SwiftUI
import CleanCore
import QuickLook

@MainActor
@Observable
final class ManageFilesModel {
    var result: FileCategoriesResult?
    var isScanning = false
    var selectedID: String? = "archives"
    var expanded: Set<String> = []
    let selection = SelectionStore()
    let scanner = FileCategoriesScanner()

    private var scanTask: Task<Void, Never>?
    private var generation = 0
    /// The last scan was stopped, so the results are incomplete.
    var wasStopped = false

    /// Starts a scan that keeps running while you visit other sections; a forced scan replaces a running one.
    func start(volumes: [VolumeInfo], force: Bool = false) {
        guard force || (result == nil && scanTask == nil) else { return }
        let previous = scanTask
        previous?.cancel()
        generation += 1
        let current = generation
        scanTask = Task { [weak self] in
            await previous?.value
            await self?.scan(volumes: volumes, generation: current)
        }
    }

    func stop() { scanTask?.cancel() }

    private func scan(volumes: [VolumeInfo], generation current: Int) async {
        isScanning = true
        wasStopped = false
        let enabled = Set((try? JSONDecoder().decode([String].self, from: UserDefaults.standard.data(forKey: SettingsKey.enabledVolumeIDs) ?? Data())) ?? [])
        let found = await scanner.scan(volumes: volumes.filter { enabled.contains($0.id) && !$0.isReadOnly })
        guard current == generation else { return }
        wasStopped = Task.isCancelled
        result = found
        isScanning = false
        scanTask = nil
    }

    var rows: [(id: String, title: String, image: String, bytes: Int64)] {
        var rows = FileCategoriesScanner.categoryInfos.map { ($0.id, $0.title, $0.image, result?.total($0.id) ?? 0) }
        rows.append(("system", "System files", "gearshape", result?.systemBytes ?? 0))
        rows.append(("home", "Home folder", "house", result?.homeFolders.reduce(0) { $0 + $1.size } ?? 0))
        return rows
    }

    func items(for id: String) -> [ScanItem] {
        guard let result else { return [] }
        if id == "home" { return result.homeFolders }
        if id == "system" { return [] }
        return result.categories.first { $0.id == id }?.items ?? []
    }

    var selectedItems: [ScanItem] { selection.selectedLeaves(in: rows.flatMap { items(for: $0.id) }) }
}

struct ManageFilesView: View {
    @Environment(AppModel.self) private var appModel
    private var model: ManageFilesModel { appModel.sections.manageFiles }
    @State private var removalFlow: RemovalFlow?
    @State private var previewItem: ScanItem?

    var body: some View {
        @Bindable var model = model
        SectionLayout(section: .manageFiles) {
            if model.isScanning {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scanning…").font(.callout).foregroundStyle(.secondary) }
                Button("Stop") { model.stop() }
            } else {
                if model.wasStopped { Text("Stopped: sizes are incomplete").font(.callout).foregroundStyle(Theme.warning) }
                Button { model.start(volumes: appModel.volumes, force: true) } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            }
        } primary: {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.rows, id: \.id) { row in
                        HStack(spacing: 10) {
                            Image(systemName: row.image).frame(width: 22).foregroundStyle(Theme.accent)
                            Text(row.title)
                            Spacer()
                            Text(model.result == nil ? "…" : row.bytes.formattedBytes).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(model.selectedID == row.id ? Theme.accent.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedID = row.id }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { model.selectedID = row.id }
                    }
                    if let result = model.result {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Home folder").font(.caption).foregroundStyle(.secondary)
                            CapacityBar(segments: FileCategoriesScanner.categoryInfos.enumerated().map { index, info in (info.title, result.total(info.id), Theme.categoryPalette[index % Theme.categoryPalette.count]) },
                                        total: max(1, result.homeFolders.reduce(0) { $0 + $1.size }))
                        }
                        .padding(10)
                    }
                }
                .padding(8)
            }
        } detail: {
            if let id = model.selectedID {
                let items = model.items(for: id)
                VStack(spacing: 0) {
                    if id == "system" {
                        ContentUnavailableView("System files", systemImage: "gearshape", description: Text("\((model.result?.systemBytes ?? 0).formattedBytes) used by macOS, /Library and system data. System folders are protected from removal."))
                    } else if model.result == nil {
                        VStack(spacing: 10) { ProgressView(); Text("Measuring your files…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if items.isEmpty {
                        ContentUnavailableView("No files", systemImage: "checkmark.circle")
                    } else if id == "home" {
                        Text("What takes space in your home folder. These folders hold your own data, so they are shown for reference only; double-click one to open it in Finder.")
                            .font(.callout).foregroundStyle(.secondary).padding(12)
                        List(items) { item in
                            HStack {
                                FileIcon(url: item.url, size: 22)
                                Text(item.title)
                                Spacer()
                                Text(item.size.formattedBytes).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .onTapGesture(count: 2) { if let url = item.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                            .contextMenu { if let url = item.url { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } } }
                        }
                        .listStyle(.inset).scrollContentBackground(.hidden)
                    } else {
                        SelectAllHeader(items: items, selection: model.selection)
                        List(items) { item in
                            ScanItemRow(item: item, selection: model.selection)
                                .onTapGesture(count: 2) { if let url = item.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                                .contextMenu { if let url = item.url { Button("Quick Look") { previewItem = item }; Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } } }
                        }
                        .listStyle(.inset).scrollContentBackground(.hidden)
                    }
                }
            } else { EmptyDetailView() }
        } footer: {
            let items = model.selectedItems
            if !items.isEmpty { Text("\(countText(items.count, "item")) · \(items.reduce(0) { $0 + $1.size }.formattedBytes)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).padding(.trailing, 8) }
            Button(AppSection.manageFiles.actionTitle) { removalFlow = RemovalFlow(title: "Remove files", apps: [], items: items) }
                .buttonStyle(PrimaryActionButtonStyle()).disabled(items.isEmpty)
        }
        .task { model.start(volumes: appModel.volumes) }
        .onChange(of: appModel.rescanToken) { _, _ in model.start(volumes: appModel.volumes, force: true) }
        .quickLookPreview(Binding(get: { previewItem?.url }, set: { if $0 == nil { previewItem = nil } }))
        .sheet(item: $removalFlow) { flow in
            RemovalSheet(flow: flow) { _ in model.selection.clear(); model.start(volumes: appModel.volumes, force: true) }.environment(appModel)
        }
    }
}
