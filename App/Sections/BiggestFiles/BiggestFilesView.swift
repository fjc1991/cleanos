import SwiftUI
import CleanCore
import QuickLook

@MainActor
@Observable
final class BiggestFilesModel {
    var items: [ScanItem] = []
    var isScanning = false
    var scannedCount = 0
    var selectedID: String?
    var searchText = ""
    let selection = SelectionStore()
    let scanner = LargeFilesScanner()
    var minimumMB: Int = UserDefaults.standard.integer(forKey: "biggestFilesMinimumMB") == 0 ? 50 : UserDefaults.standard.integer(forKey: "biggestFilesMinimumMB") {
        didSet { UserDefaults.standard.set(minimumMB, forKey: "biggestFilesMinimumMB") }
    }

    func scan(volumes: [VolumeInfo], force: Bool = false) async {
        guard !isScanning, items.isEmpty || force else { return }
        isScanning = true
        selection.clear()
        let enabled = Set((try? JSONDecoder().decode([String].self, from: UserDefaults.standard.data(forKey: SettingsKey.enabledVolumeIDs) ?? Data())) ?? [])
        var roots = [FileManager.default.homeDirectoryForCurrentUser]
        roots.append(contentsOf: volumes.filter { !$0.isRoot && enabled.contains($0.id) }.map(\.url))
        var options = LargeFilesScanner.Options()
        options.minimumSize = Int64(minimumMB) * 1024 * 1024
        options.excludedPathPrefixes = [NSHomeDirectory() + "/Library", NSHomeDirectory() + "/.Trash"]
        items = await scanner.scan(roots: roots, options: options) { [weak self] count in Task { @MainActor in self?.scannedCount = count } }
        isScanning = false
        if selectedID == nil { selectedID = items.first?.id }
    }

    var filtered: [ScanItem] { items.filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) } }
    var selected: ScanItem? { items.first { $0.id == selectedID } }
    var selectedItems: [ScanItem] { selection.selectedLeaves(in: items) }
}

struct BiggestFilesView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model = BiggestFilesModel()
    @State private var removalFlow: RemovalFlow?
    @State private var previewURL: URL?

    var body: some View {
        @Bindable var model = model
        SectionLayout(section: .biggestFiles) {
            Picker("Larger than", selection: Binding(get: { model.minimumMB }, set: { model.minimumMB = $0; Task { await model.scan(volumes: appModel.volumes, force: true) } })) {
                Text("50 MB").tag(50); Text("100 MB").tag(100); Text("250 MB").tag(250); Text("1 GB").tag(1024); Text("5 GB").tag(5120)
            }
            .pickerStyle(.menu).fixedSize()
            if model.isScanning { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scanned \(model.scannedCount) items…").font(.callout).foregroundStyle(.secondary) } }
            else { Button { Task { await model.scan(volumes: appModel.volumes, force: true) } } label: { Label("Rescan", systemImage: "arrow.clockwise") } }
        } primary: {
            VStack(spacing: 0) {
                TextField("Search", text: $model.searchText).textFieldStyle(.roundedBorder).padding(10)
                Divider()
                List(selection: $model.selectedID) {
                    ForEach(model.filtered) { item in
                        ScanItemRow(item: item, selection: model.selection).tag(item.id)
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
                Divider()
                HStack { Text("\(model.items.count) files ≥ \(model.minimumMB >= 1024 ? "\(model.minimumMB / 1024) GB" : "\(model.minimumMB) MB")").font(.caption).foregroundStyle(.secondary); Spacer() }.padding(8)
            }
        } detail: {
            if let item = model.selected, let url = item.url {
                VStack(spacing: 16) {
                    FileIcon(url: url, size: 96)
                    Text(item.title).font(.title3.weight(.semibold))
                    InfoSection(title: "Information") {
                        InfoRow("Kind", item.payload["kind"] ?? (item.kind == .bundle ? "Application" : "File"))
                        InfoRow("Size", item.size.formattedBytes)
                        InfoRow("Modified", item.modificationDate?.formatted(.dateTime.day().month().year().hour().minute()) ?? "–")
                        InfoRow("Last Opened", item.payload["lastOpened"].flatMap { ISO8601DateFormatter().date(from: $0) }?.formatted(.dateTime.day().month().year().hour().minute()) ?? "–")
                        InfoRow("Path", url.path)
                    }
                    HStack {
                        Button("Quick Look") { previewURL = url }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Spacer()
                }
                .padding(20)
            } else if model.isScanning {
                VStack(spacing: 10) { ProgressView(); Text("Looking for the biggest files…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyDetailView(title: "Select a file to see details", systemImage: "doc")
            }
        } footer: {
            let items = model.selectedItems
            if !items.isEmpty { Text("\(items.count) items · \(items.reduce(0) { $0 + $1.size }.formattedBytes)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).padding(.trailing, 8) }
            Button(AppSection.biggestFiles.actionTitle) { removalFlow = RemovalFlow(title: "Remove biggest files", apps: [], items: items, quit: { true }) }
                .buttonStyle(PrimaryActionButtonStyle()).disabled(items.isEmpty)
        }
        .task { await model.scan(volumes: appModel.volumes) }
        .onChange(of: appModel.rescanToken) { _, _ in Task { await model.scan(volumes: appModel.volumes, force: true) } }
        .quickLookPreview($previewURL)
        .sheet(item: $removalFlow) { flow in
            RemovalSheet(flow: flow) { _ in Task { await model.scan(volumes: appModel.volumes, force: true) } }.environment(appModel)
        }
    }
}
