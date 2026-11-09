import SwiftUI
import CleanCore
import QuickLook

@MainActor
@Observable
final class DuplicatesModel {
    var groups: [DuplicateGroup] = []
    var isScanning = false
    var status = ""
    var selectedGroupID: String?
    var searchText = ""
    var folders: [URL] = [FileManager.default.homeDirectoryForCurrentUser]
    let selection = SelectionStore()
    let finder = DuplicateFinder()

    private var scanTask: Task<Void, Never>?
    private var generation = 0
    /// The last scan was stopped, so the results are incomplete.
    var wasStopped = false

    /// Starts a scan that keeps running while you visit other sections; a forced scan replaces a running one.
    func start(folders: [URL]? = nil, force: Bool = false) {
        guard force || (groups.isEmpty && scanTask == nil) else { return }
        if let folders { self.folders = folders }
        hasScanned = true
        let previous = scanTask
        previous?.cancel()
        generation += 1
        let current = generation
        scanTask = Task { [weak self] in
            await previous?.value
            await self?.scan(generation: current)
        }
    }

    func stop() { scanTask?.cancel() }

    /// Duplicates are only searched for on request: hashing reads every candidate file.
    var hasScanned = false

    private func scan(generation current: Int) async {
        isScanning = true
        wasStopped = false
        selection.clear()
        var options = DuplicateFinder.Options()
        options.excludedPathPrefixes = [NSHomeDirectory() + "/Library", NSHomeDirectory() + "/.Trash"]
        let found = await finder.find(roots: folders, options: options) { [weak self] message in Task { @MainActor in self?.status = message } }
        guard current == generation else { return }
        wasStopped = Task.isCancelled
        groups = found
        isScanning = false
        scanTask = nil
        status = ""
        if selectedGroupID == nil || !groups.contains(where: { $0.id == selectedGroupID }) { selectedGroupID = groups.first?.id }
    }

    var filtered: [DuplicateGroup] { groups.filter { searchText.isEmpty || $0.files.contains { $0.title.localizedCaseInsensitiveContains(searchText) } } }
    var selected: DuplicateGroup? { groups.first { $0.id == selectedGroupID } }
    var allFiles: [ScanItem] { groups.flatMap(\.files) }
    var selectedItems: [ScanItem] { selection.selectedLeaves(in: allFiles) }
    var wasted: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }

    func smartSelect() {
        selection.clear()
        for item in DuplicateFinder.smartSelection(groups) { selection.set(item, selected: true) }
    }
}

struct DuplicatesView: View {
    @Environment(AppModel.self) private var appModel
    private var model: DuplicatesModel { appModel.sections.duplicates }
    @State private var removalFlow: RemovalFlow?
    @State private var previewURL: URL?

    var body: some View {
        @Bindable var model = model
        SectionLayout(section: .duplicates) {
            if model.isScanning {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.status).font(.callout).foregroundStyle(.secondary) }
                Button("Stop") { model.stop() }
            } else {
                if model.wasStopped { Text("Stopped: results are incomplete").font(.callout).foregroundStyle(Theme.warning) }
                Button("Smart Select") { model.smartSelect() }.disabled(model.groups.isEmpty)
                Button {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true; panel.prompt = "Scan"
                    if panel.runModal() == .OK, !panel.urls.isEmpty { model.start(folders: panel.urls, force: true) }
                } label: { Label("Choose Folders…", systemImage: "folder") }
                if model.hasScanned { Button { model.start(force: true) } label: { Label("Rescan", systemImage: "arrow.clockwise") } }
            }
        } primary: {
            VStack(spacing: 0) {
                TextField("Search", text: $model.searchText).textFieldStyle(.roundedBorder).padding(10)
                Divider()
                List(selection: $model.selectedGroupID) {
                    ForEach(model.filtered) { group in
                        HStack(spacing: 8) {
                            TriStateCheckbox(state: groupState(group), title: group.files.first?.title) {
                                if groupState(group) == .none { for file in group.files.dropFirst() { model.selection.set(file, selected: true) } }
                                else { model.selection.deselect(in: group.files) }
                            }
                            FileIcon(url: group.files.first?.url, size: 24)
                            Text(group.files.first?.title ?? "").lineLimit(1)
                            Spacer()
                            Text("\(group.files.count)").font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Theme.accent.opacity(0.25)))
                            Text(group.size.formattedBytes).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .tag(group.id)
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
                Divider()
                HStack { Text("\(countText(model.groups.count, "group")) · \(model.wasted.formattedBytes) recoverable").font(.caption).foregroundStyle(.secondary); Spacer() }.padding(8)
            }
        } detail: {
            if let group = model.selected {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        FileIcon(url: group.files.first?.url, size: 48)
                        VStack(alignment: .leading) {
                            Text(group.files.first?.title ?? "").font(.title3.weight(.semibold))
                            Text("\(group.files.count) copies · \(group.size.formattedBytes) each · \(group.wastedBytes.formattedBytes) recoverable").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Quick Look") { previewURL = group.files.first?.url }
                    }
                    .padding(16)
                    Divider().padding(.horizontal, 16)
                    List(group.files) { file in
                        HStack {
                            ScanItemRow(item: file, selection: model.selection)
                            Text(file.modificationDate?.formatted(.dateTime.day().month().year()) ?? "").font(.caption).foregroundStyle(.secondary)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url!]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                        }
                    }
                    .listStyle(.inset).scrollContentBackground(.hidden)
                    Text("The first file in each group is the oldest copy; Smart Select keeps it and selects the rest.").font(.caption).foregroundStyle(.tertiary).padding(12)
                }
            } else if model.isScanning {
                VStack(spacing: 10) { ProgressView(); Text(model.status).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.hasScanned {
                ContentUnavailableView {
                    Label("Duplicates", systemImage: "doc.on.doc")
                } description: {
                    Text("Finds files with identical contents in your home folder (or folders you choose). It reads every candidate file, so it can take a while; files that are only in iCloud are skipped.")
                } actions: {
                    Button("Find Duplicates") { model.start(force: true) }.buttonStyle(PrimaryActionButtonStyle())
                }
            } else {
                ContentUnavailableView("No duplicates found", systemImage: "doc.on.doc", description: Text(model.wasStopped ? "The search was stopped before it finished." : "No files with identical contents were found."))
            }
        } footer: {
            let items = model.selectedItems
            if !items.isEmpty { Text("\(countText(items.count, "item")) · \(items.reduce(0) { $0 + $1.size }.formattedBytes)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).padding(.trailing, 8) }
            Button(AppSection.duplicates.actionTitle) { removalFlow = RemovalFlow(title: "Remove duplicates", apps: [], items: items) }
                .buttonStyle(PrimaryActionButtonStyle()).disabled(items.isEmpty)
        }
        .onChange(of: appModel.rescanToken) { _, _ in if model.hasScanned { model.start(force: true) } }
        .quickLookPreview($previewURL)
        .sheet(item: $removalFlow) { flow in
            RemovalSheet(flow: flow) { _ in model.start(force: true) }.environment(appModel)
        }
    }

    private func groupState(_ group: DuplicateGroup) -> SelectionState {
        let count = group.files.filter { model.selection.isSelected($0) }.count
        return count == 0 ? .none : (count == group.files.count ? .all : .partial)
    }
}
