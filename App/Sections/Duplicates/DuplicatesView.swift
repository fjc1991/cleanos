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

    func scan(force: Bool = false) async {
        guard !isScanning, groups.isEmpty || force else { return }
        isScanning = true
        selection.clear()
        var options = DuplicateFinder.Options()
        options.excludedPathPrefixes = [NSHomeDirectory() + "/Library", NSHomeDirectory() + "/.Trash"]
        groups = await finder.find(roots: folders, options: options) { [weak self] message in Task { @MainActor in self?.status = message } }
        isScanning = false
        status = ""
        if selectedGroupID == nil { selectedGroupID = groups.first?.id }
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
    @State private var model = DuplicatesModel()
    @State private var removalFlow: RemovalFlow?
    @State private var previewURL: URL?

    var body: some View {
        @Bindable var model = model
        SectionLayout(section: .duplicates) {
            if model.isScanning { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.status).font(.callout).foregroundStyle(.secondary) } }
            else {
                Button("Smart Select") { model.smartSelect() }.disabled(model.groups.isEmpty)
                Button {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true; panel.prompt = "Scan"
                    if panel.runModal() == .OK, !panel.urls.isEmpty { model.folders = panel.urls; Task { await model.scan(force: true) } }
                } label: { Label("Choose Folders…", systemImage: "folder") }
                Button { Task { await model.scan(force: true) } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            }
        } primary: {
            VStack(spacing: 0) {
                TextField("Search", text: $model.searchText).textFieldStyle(.roundedBorder).padding(10)
                Divider()
                List(selection: $model.selectedGroupID) {
                    ForEach(model.filtered) { group in
                        HStack(spacing: 8) {
                            TriStateCheckbox(state: groupState(group)) {
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
                HStack { Text("\(model.groups.count) groups · \(model.wasted.formattedBytes) recoverable").font(.caption).foregroundStyle(.secondary); Spacer() }.padding(8)
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
            } else {
                ContentUnavailableView("Duplicates", systemImage: "doc.on.doc", description: Text("Free up space by deleting duplicate files."))
            }
        } footer: {
            let items = model.selectedItems
            if !items.isEmpty { Text("\(items.count) items · \(items.reduce(0) { $0 + $1.size }.formattedBytes)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).padding(.trailing, 8) }
            Button(AppSection.duplicates.actionTitle) { removalFlow = RemovalFlow(title: "Remove duplicates", apps: [], items: items) }
                .buttonStyle(PrimaryActionButtonStyle()).disabled(items.isEmpty)
        }
        .task { await model.scan() }
        .onChange(of: appModel.rescanToken) { _, _ in Task { await model.scan(force: true) } }
        .quickLookPreview($previewURL)
        .sheet(item: $removalFlow) { flow in
            RemovalSheet(flow: flow) { _ in Task { await model.scan(force: true) } }.environment(appModel)
        }
    }

    private func groupState(_ group: DuplicateGroup) -> SelectionState {
        let count = group.files.filter { model.selection.isSelected($0) }.count
        return count == 0 ? .none : (count == group.files.count ? .all : .partial)
    }
}
