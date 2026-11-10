import SwiftUI
import CleanCore

/// Right pane: general information about the selected app, or the Expert Mode tree of its service files.
struct AppDetailView: View {
    @Bindable var model: ApplicationsModel
    let app: InstalledApp
    var onReset: () -> Void
    /// Processes running from inside the bundle, read off the main thread when the app is shown.
    @State private var background: [RunningProcess] = []

    private var result: LeftoverScanResult? { model.scans[app.id] }

    private func refreshProcesses() async {
        let path = app.url.standardizedFileURL.path
        background = await Task.detached(priority: .utility) { ProcessMonitor.processes(inBundle: path) }.value
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 16)
            if model.expertMode {
                ExpertTreeView(model: model, app: app)
            } else {
                generalInfo
            }
            EmptyView().task(id: app.id) { await refreshProcesses() }
        }
        .task(id: app.id) { await model.ensureScan(for: app) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            FileIcon(url: app.url, size: model.expertMode ? 36 : 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.title3.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    GridRow {
                        Text("Apps files and folders").foregroundStyle(.secondary)
                        if let result {
                            HStack(spacing: 6) {
                                Text("\(result.itemCount) items").foregroundStyle(Theme.accent)
                                if result.isPartial { Text("search stopped early").font(.caption).foregroundStyle(Theme.warning) }
                            }
                        } else if model.scanning.contains(app.id) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Button("Stop") { Task { await model.stopScan(for: app) } }.controlSize(.mini)
                            }
                        } else { Text("–") }
                    }
                    GridRow {
                        Text("Developer").foregroundStyle(.secondary)
                        Text(app.developerName ?? "Unknown")
                    }
                    GridRow {
                        Text("App verification").foregroundStyle(.secondary)
                        Text(app.identity.isNotarized == true ? "Notarized" : app.teamID == nil ? "Unsigned" : "Signed")
                    }
                }
                .font(.callout)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text((result?.totalSize ?? model.appSizes[app.id] ?? 0).formattedBytes).font(.title3.weight(.semibold).monospacedDigit())
                if !background.isEmpty {
                    HStack(spacing: 6) {
                        Label(model.isRunning(app) ? "Running" : "\(background.count) background process\(background.count == 1 ? "" : "es")", systemImage: "circle.fill")
                            .font(.caption).foregroundStyle(Theme.success)
                        Button("Force Stop") { Task { _ = await model.quit([app]); await refreshProcesses() } }.controlSize(.mini)
                            .help(background.map { "\($0.name) (pid \($0.pid))" }.joined(separator: "\n"))
                    }
                }
                Menu {
                    Button("Reset Application…") { onReset() }
                    Button("Rescan Service Files") { Task { await model.rescan(app: app) } }
                    Divider()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                    Button("Add to Skip List") { AppSettings.addToSkipList(app.url.path) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(16)
    }

    private var generalInfo: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InfoSection(title: "General") {
                    InfoRow("Version", app.version.map { v in app.build.map { "\(v) (\($0))" } ?? v } ?? "–")
                    InfoRow("Bundle ID", app.bundleID)
                    InfoRow("Modified", app.modificationDate.map(format) ?? "–")
                    InfoRow("Last Opened", app.lastOpenedDate.map(format) ?? "–")
                    InfoRow("Created", app.creationDate.map(format) ?? "–")
                    InfoRow("Location", app.url.deletingLastPathComponent().path)
                }
                if let result {
                    InfoSection(title: "Service files (\(result.itemCount - (result.groups.first?.title == "Executables" ? 1 : 0)) items · \(result.totalSize.formattedBytes))") {
                        ForEach(result.groups) { group in
                            HStack {
                                Text(group.title)
                                Spacer()
                                Text("\(group.children.count)").foregroundStyle(.secondary)
                                Text(group.size.formattedBytes).monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                            }
                            .font(.callout)
                        }
                        Button("Show in Expert Mode") { model.expertMode = true }.buttonStyle(.link).font(.callout)
                    }
                } else if model.scanning.contains(app.id) {
                    HStack { ProgressView().controlSize(.small); Text("Searching for service files…").foregroundStyle(.secondary) }
                }
                let permissions = result?.allItems.filter { $0.group == RegistrationScanner.groupPermissions } ?? []
                InfoSection(title: permissions.isEmpty ? "App Access" : "App Access (\(permissions.count))") {
                    if permissions.isEmpty {
                        Text(FullDiskAccess.isGranted ? "No system permissions recorded for this app."
                             : "Grant Full Disk Access to view this app's system permissions and the folders it can access.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(permissions) { permission in
                                Label(permission.title, systemImage: permission.subtitle?.hasPrefix("Allowed") == true ? "checkmark.circle" : "xmark.circle")
                                    .font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                        }
                        Text("Screen Recording, Accessibility, Input Monitoring and Full Disk Access live in the system database and need the helper to read or reset.")
                            .font(.caption).foregroundStyle(.tertiary)
                        Button("Manage Permissions in Expert Mode") { model.expertMode = true; model.expandedGroups.insert("group:" + RegistrationScanner.groupPermissions) }
                            .buttonStyle(.link).font(.callout)
                    }
                }
                let traces = result?.allItems.filter { $0.kind == .registration && $0.group != RegistrationScanner.groupPermissions } ?? []
                if !traces.isEmpty {
                    InfoSection(title: "Other traces (\(traces.count))") {
                        ForEach(Dictionary(grouping: traces, by: \.group).keys.sorted(), id: \.self) { group in
                            HStack { Text(group); Spacer(); Text("\(traces.filter { $0.group == group }.count)").foregroundStyle(.secondary) }.font(.callout)
                        }
                    }
                }
                InfoSection(title: "Identity signals") {
                    InfoRow("Team ID", app.teamID ?? "–")
                    InfoRow("Helpers", "\(app.identity.subBundleIDs.count) bundles, \(app.identity.extensionIDs.count) extensions")
                    if !app.identity.groupIDs.isEmpty { InfoRow("App groups", app.identity.groupIDs.sorted().joined(separator: ", ")) }
                    if !app.identity.launchdLabels.isEmpty { InfoRow("launchd labels", app.identity.launchdLabels.sorted().joined(separator: ", ")) }
                    if app.identity.isElectron { InfoRow("Framework", "Electron") }
                    if app.identity.hasMASReceipt { InfoRow("Source", "Mac App Store") }
                    if let feed = app.identity.sparkleFeedURL { InfoRow("Sparkle feed", feed) }
                }
            }
            .padding(16)
        }
    }

    private func format(_ date: Date) -> String {
        date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().hour().minute())
    }
}

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}

/// Expert Mode: every matched item grouped by location, with tri-state checkboxes, tier badges and the match reasons.
struct ExpertTreeView: View {
    @Bindable var model: ApplicationsModel
    let app: InstalledApp

    var body: some View {
        if let result = model.scans[app.id] {
            VStack(spacing: 0) {
                if result.isPartial {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        Text("The search was stopped early; more files may exist and sizes were not measured.").font(.caption)
                        Spacer()
                        Button("Search Again") { Task { await model.rescan(app: app) } }.controlSize(.small)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Theme.warning.opacity(0.12))
                }
                HStack {
                    TriStateCheckbox(state: overallState(result)) {
                        if overallState(result) == .all { model.selection.deselect(in: result.groups) }
                        else { model.selection.selectDefaults(in: result.groups, allowRoot: false); for g in result.groups { model.selection.set(g, selected: true) } }
                    }
                    Text("Select All").font(.callout)
                    Spacer()
                    Text("\(model.selection.selectedLeaves(in: result.groups).count) selected · \(model.selection.selectedSize(in: result.groups).formattedBytes)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                List {
                    ForEach(result.groups) { group in
                        DisclosureGroup(isExpanded: Binding(
                            get: { model.expandedGroups.contains(group.id) },
                            set: { if $0 { model.expandedGroups.insert(group.id) } else { model.expandedGroups.remove(group.id) } }
                        )) {
                            ForEach(group.children) { item in
                                ScanItemRow(item: item, selection: model.selection)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                TriStateCheckbox(state: model.selection.state(of: group), title: group.title) { model.selection.toggle(group) }
                                Text(group.title).font(.callout.weight(.semibold))
                                Spacer()
                                Text(group.children.count == 1 ? "1 item" : "\(countText(group.children.count, "item"))").font(.caption).foregroundStyle(.secondary)
                                Text(group.size.formattedBytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Searching every known location for files that belong to \(app.name)…").foregroundStyle(.secondary)
                Button("Stop Search") { Task { await model.stopScan(for: app) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func overallState(_ result: LeftoverScanResult) -> SelectionState {
        let states = result.groups.map { model.selection.state(of: $0) }
        if states.allSatisfy({ $0 == .all }) { return .all }
        if states.allSatisfy({ $0 == .none }) { return .none }
        return .partial
    }
}

/// One leaf row in a scan tree.
struct ScanItemRow: View {
    let item: ScanItem
    let selection: SelectionStore
    /// A row that names no file and can never be ticked is an explanation: it shows its whole text.
    private var isNote: Bool { !item.tier.isSelectable && item.url == nil }

    var body: some View {
        HStack(spacing: 8) {
            TriStateCheckbox(state: selection.state(of: item), isEnabled: item.tier.isSelectable, title: item.title) { selection.toggle(item) }
            if isNote {
                Image(systemName: "info.circle").frame(width: 18).foregroundStyle(.secondary)
            } else if item.kind == .registration {
                Image(systemName: "text.alignleft").frame(width: 18).foregroundStyle(Theme.accent)
            } else {
                FileIcon(url: item.url)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1)
                    if item.needsRoot { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("Needs administrator privileges") }
                    if !isNote { TierBadge(tier: item.tier) }
                }
                if isNote {
                    Text(item.subtitle ?? "").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(item.subtitle ?? item.url?.deletingLastPathComponent().path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Text(item.size.formattedBytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
        }
        .help("Matched by: " + item.matchedBy.joined(separator: ", "))
        .contextMenu {
            if let url = item.url {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Add to Skip List") { AppSettings.addToSkipList(url.path) }
            }
            Text("Matched by: " + item.matchedBy.joined(separator: ", "))
        }
    }
}


/// Wraps chips onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
