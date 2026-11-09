import SwiftUI
import CleanCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class ExtensionsModel {
    var results: [String: [ScanItem]] = [:]
    var scanning: Set<String> = []
    var selectedGroupID: String? = ExtensionsScanner.groups.first?.id
    var expanded: Set<String> = []
    var busy: Set<String> = []
    let selection = SelectionStore()
    let scanner = ExtensionsScanner()
    var apps: [InstalledApp] = []
    var appProvider: (@MainActor () async -> [InstalledApp])?
    var selectedGroupIsDefaults: Bool { selectedGroupID == "defaults" }

    var groups: [ExtensionGroupInfo] {
        ExtensionsScanner.groups + [ExtensionGroupInfo(id: "defaults", title: "Default Applications", description: "Which app opens each kind of file or link.", systemImage: "checkmark.rectangle")]
    }

    func scanAll(volumes: [VolumeInfo], force: Bool = false) async {
        guard force || results.isEmpty, scanning.isEmpty else { return }
        if let appProvider { apps = await appProvider() }
        let context = CleanupContext(volumes: volumes, installedApps: apps, runningBundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)))
        scanning = Set(ExtensionsScanner.groups.map(\.id))
        for group in ExtensionsScanner.groups {
            results[group.id] = await scanner.scan(groupID: group.id, context: context)
            scanning.remove(group.id)
        }
    }

    func count(for group: ExtensionGroupInfo) -> Int { group.id == "defaults" ? DefaultAppsView.kinds.count : results[group.id]?.flatMap(\.leaves).count ?? 0 }
    var selectedItems: [ScanItem] { selection.selectedLeaves(in: results.values.flatMap { $0 }).filter { $0.payload["partOfApp"] != "1" } }

    func togglePluginkit(_ item: ScanItem) {
        guard let id = item.payload["identifier"] else { return }
        busy.insert(item.id)
        let enabled = item.payload["enabled"] == "1"
        _ = PluginkitController.setEnabled(identifier: id, !enabled)
        for (group, items) in results {
            results[group] = items.map { node in
                var node = node
                node.children = node.children.map { child in
                    var child = child
                    if child.id == item.id { child.payload["enabled"] = enabled ? "0" : "1"; child.subtitle = (enabled ? "Disabled" : "Enabled") + " · " + (child.payload["identifier"] ?? "") }
                    return child
                }
                if node.id == item.id { node.payload["enabled"] = enabled ? "0" : "1" }
                return node
            }
        }
        busy.remove(item.id)
    }
}

struct ExtensionsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model = ExtensionsModel()
    @State private var removalFlow: RemovalFlow?

    var body: some View {
        @Bindable var model = model
        SectionLayout(section: .extensions) {
            if !model.scanning.isEmpty { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scanning…").font(.callout).foregroundStyle(.secondary) } }
            else { Button { Task { await model.scanAll(volumes: appModel.volumes, force: true) } } label: { Label("Rescan", systemImage: "arrow.clockwise") } }
        } primary: {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.groups) { group in
                        HStack(spacing: 10) {
                            Image(systemName: group.systemImage).frame(width: 22).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.title)
                                Text(model.scanning.contains(group.id) ? "Scanning…" : (model.count(for: group) == 0 ? "No items" : "\(model.count(for: group)) items"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(model.selectedGroupID == group.id ? Theme.accent.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedGroupID = group.id }
                    }
                }
                .padding(8)
            }
        } detail: {
            if model.selectedGroupIsDefaults {
                DefaultAppsView()
            } else if let id = model.selectedGroupID, let group = model.groups.first(where: { $0.id == id }) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: group.systemImage).font(.title2).foregroundStyle(Theme.accent)
                            Text(group.title).font(.title3.weight(.semibold))
                            Spacer()
                        }
                        Text(group.description).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    Divider().padding(.horizontal, 16)
                    if let items = model.results[id] {
                        if items.isEmpty {
                            ContentUnavailableView("No items", systemImage: "checkmark.circle")
                        } else {
                            SelectAllHeader(items: items, selection: model.selection)
                            ExtensionTree(model: model, items: items)
                        }
                    } else {
                        VStack(spacing: 10) { ProgressView(); Text("Scanning…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                EmptyDetailView()
            }
        } footer: {
            let items = model.selectedItems
            if !items.isEmpty { Text("\(items.count) items · \(items.reduce(0) { $0 + $1.size }.formattedBytes)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).padding(.trailing, 8) }
            Button("Remove") { removalFlow = RemovalFlow(title: "Remove extensions", apps: [], items: items) }
                .buttonStyle(PrimaryActionButtonStyle()).disabled(items.isEmpty)
        }
        .task { model.appProvider = { await appModel.installedApps() }; await model.scanAll(volumes: appModel.volumes) }
        .onChange(of: appModel.rescanToken) { _, _ in Task { await model.scanAll(volumes: appModel.volumes, force: true) } }
        .sheet(item: $removalFlow) { flow in
            RemovalSheet(flow: flow) { _ in model.selection.clear(); Task { await model.scanAll(volumes: appModel.volumes, force: true) } }.environment(appModel)
        }
    }
}

/// Tree with an enable/disable switch for pluginkit-managed items.
struct ExtensionTree: View {
    @Bindable var model: ExtensionsModel
    let items: [ScanItem]

    var body: some View {
        List {
            ForEach(items) { item in
                if item.children.isEmpty {
                    row(item)
                } else {
                    DisclosureGroup(isExpanded: Binding(get: { model.expanded.contains(item.id) || model.expanded.isEmpty }, set: { if $0 { model.expanded.insert(item.id) } else { model.expanded.remove(item.id) } })) {
                        ForEach(item.children) { row($0) }
                    } label: {
                        GroupLabel(item: item, selection: model.selection)
                    }
                }
            }
        }
        .listStyle(.inset).scrollContentBackground(.hidden)
    }

    @ViewBuilder private func row(_ item: ScanItem) -> some View {
        HStack {
            ScanItemRow(item: item, selection: model.selection)
            if item.payload["type"] == "pluginkit" {
                Toggle("", isOn: Binding(get: { item.payload["enabled"] == "1" }, set: { _ in model.togglePluginkit(item) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            if let owner = item.payload["ownerPath"] ?? (item.payload["partOfApp"] == "1" ? item.url?.path : nil) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: owner)]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Reveal in Finder")
            }
        }
    }
}


/// Which app opens each common file type or link; change it with a picker that lists every app able to open it.
struct DefaultAppsView: View {
    struct Kind: Identifiable { let id: String; let title: String; let type: UTType?; let scheme: String? }
    static let kinds: [Kind] = [
        Kind(id: "http", title: "Web links (http, https)", type: nil, scheme: "http"),
        Kind(id: "mailto", title: "Email links (mailto)", type: nil, scheme: "mailto"),
        Kind(id: "pdf", title: "PDF documents", type: .pdf, scheme: nil),
        Kind(id: "html", title: "HTML files", type: .html, scheme: nil),
        Kind(id: "png", title: "PNG images", type: .png, scheme: nil),
        Kind(id: "jpeg", title: "JPEG images", type: .jpeg, scheme: nil),
        Kind(id: "heic", title: "HEIC photos", type: .heic, scheme: nil),
        Kind(id: "mp4", title: "MP4 videos", type: .mpeg4Movie, scheme: nil),
        Kind(id: "mov", title: "QuickTime movies", type: .quickTimeMovie, scheme: nil),
        Kind(id: "mp3", title: "MP3 audio", type: .mp3, scheme: nil),
        Kind(id: "txt", title: "Plain text", type: .plainText, scheme: nil),
        Kind(id: "md", title: "Markdown", type: UTType(filenameExtension: "md"), scheme: nil),
        Kind(id: "zip", title: "ZIP archives", type: .zip, scheme: nil),
        Kind(id: "epub", title: "EPUB books", type: UTType(filenameExtension: "epub"), scheme: nil),
        Kind(id: "docx", title: "Word documents", type: UTType(filenameExtension: "docx"), scheme: nil),
        Kind(id: "xlsx", title: "Excel spreadsheets", type: UTType(filenameExtension: "xlsx"), scheme: nil),
        Kind(id: "csv", title: "CSV data", type: .commaSeparatedText, scheme: nil),
        Kind(id: "json", title: "JSON", type: .json, scheme: nil),
    ]
    @State private var refresh = 0
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Image(systemName: "checkmark.rectangle").font(.title2).foregroundStyle(Theme.accent); Text("Default Applications").font(.title3.weight(.semibold)) }
                Text("Choose which app opens each kind of file or link. The change applies to Finder and every app that opens files.").font(.callout).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider().padding(.horizontal, 16)
            List(Self.kinds) { kind in
                let current = currentApp(for: kind)
                HStack(spacing: 10) {
                    FileIcon(url: current, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.title)
                        Text(current?.deletingPathExtension().lastPathComponent ?? "No default app").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Change…") {
                        ForEach(candidates(for: kind), id: \.path) { url in
                            Button { set(url, for: kind) } label: { Label(url.deletingPathExtension().lastPathComponent, systemImage: "app") }
                        }
                        Divider()
                        Button("Other…") { pickOther(for: kind) }
                    }
                    .fixedSize()
                }
                .id("\(kind.id)-\(refresh)")
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
            if let message { Divider(); Text(message).font(.caption).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private func currentApp(for kind: Kind) -> URL? {
        if let scheme = kind.scheme, let url = URL(string: "\(scheme)://example.com") { return NSWorkspace.shared.urlForApplication(toOpen: url) }
        if let type = kind.type { return NSWorkspace.shared.urlForApplication(toOpen: type) }
        return nil
    }

    private func candidates(for kind: Kind) -> [URL] {
        var urls: [URL] = []
        if let scheme = kind.scheme, let url = URL(string: "\(scheme)://example.com") { urls = NSWorkspace.shared.urlsForApplications(toOpen: url) }
        else if let type = kind.type { urls = NSWorkspace.shared.urlsForApplications(toOpen: type) }
        return Array(Set(urls)).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func set(_ app: URL, for kind: Kind) {
        Task {
            do {
                if let scheme = kind.scheme { try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) }
                else if let type = kind.type { try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) }
                message = "\(app.deletingPathExtension().lastPathComponent) now opens \(kind.title.lowercased())."
            } catch { message = error.localizedDescription }
            refresh += 1
        }
    }

    private func pickOther(for kind: Kind) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { set(url, for: kind) }
    }
}
