import SwiftUI
import CleanCore

@MainActor
@Observable
final class SpeedUpModel {
    enum Row: String, CaseIterable, Identifiable {
        case startup = "Startup apps", heavy = "Heavy applications", ram = "Optimize RAM", spotlight = "Reindex Spotlight", mail = "Reindex Mail",
             browserExtensions = "Browser extensions", plugins = "Internet plugins"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .startup: "paperplane"; case .heavy: "memorychip"; case .ram: "cpu"; case .spotlight: "magnifyingglass"
            case .mail: "envelope"; case .browserExtensions: "puzzlepiece"; case .plugins: "network"
            }
        }
        var description: String {
            switch self {
            case .startup: "Applications, agents and extensions that start automatically at login. Disable unnecessary items from autorun."
            case .heavy: "Applications that consume excessive RAM and swap memory negatively impact performance. Review and quit any unused applications."
            case .ram: "Purge inactive memory so active apps get it back. Needs the helper."
            case .spotlight: "Rebuild the Spotlight index if search shows wrong or missing results. Indexing takes a while afterwards."
            case .mail: "Rebuild Mail's envelope index if Mail is slow or search misbehaves. Mail is quit and re-indexes on next launch."
            case .browserExtensions: "Extensions installed in your browsers. Managed in the Extensions section."
            case .plugins: "Legacy Internet plug-ins. Managed in the Extensions section."
            }
        }
    }

    var selected: Row? = .startup
    var startupItems: [StartupItem] = []
    var heavyApps: [AppMemoryUsage] = []
    var memory: MemoryStats? = MemoryStats.current()
    var busy: Set<String> = []
    var messages: [String: String] = [:]
    var isLoading = false
    let startupScanner = StartupScanner()
    var apps: [InstalledApp] = []
    var appProvider: (@MainActor () async -> [InstalledApp])?

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        if let appProvider { apps = await appProvider() }
        startupItems = await startupScanner.scan(installedApps: apps)
        refreshProcesses()
        isLoading = false
    }

    func refreshProcesses() {
        memory = MemoryStats.current()
        let mine = getuid()
        heavyApps = ProcessMonitor.groupByApp(ProcessMonitor.snapshot().filter { $0.uid == mine }).filter { $0.memory > 20 * 1024 * 1024 }
    }

    func quit(_ usage: AppMemoryUsage) {
        for process in usage.processes {
            if let app = NSRunningApplication(processIdentifier: process.pid) { app.terminate() }
        }
        Task { try? await Task.sleep(for: .seconds(1)); refreshProcesses() }
    }

    func run(_ task: MaintenanceTask, key: String, helper: HelperClient) async {
        busy.insert(key)
        if case .reindexMail = task { for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail") { app.terminate() } }
        let runner = MaintenanceRunner(runAsRoot: helper.isAvailable ? helper.rootRunner() : nil)
        messages[key] = await runner.run(task) ?? "Done."
        busy.remove(key)
        refreshProcesses()
    }

    var taskCount: Int { startupItems.filter(\.isEnabled).count + heavyApps.count }
}

struct SpeedUpView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model = SpeedUpModel()

    var body: some View {
        @Bindable var model = model
        SectionLayout(section: .speedUp) {
            Text("\(model.taskCount) tasks").font(.callout).foregroundStyle(.secondary)
        } primary: {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SpeedUpModel.Row.allCases) { row in
                        HStack(spacing: 10) {
                            Image(systemName: row.systemImage).frame(width: 22).foregroundStyle(Theme.accent)
                            Text(row.rawValue)
                            Spacer()
                            Text(trailing(for: row)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(model.selected == row ? Theme.accent.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { model.selected = row }
                    }
                }
                .padding(8)
            }
        } detail: {
            if let row = model.selected { detail(for: row) } else { EmptyDetailView() }
        } footer: {
            EmptyView()
        }
        .task { model.appProvider = { await appModel.installedApps() }; await model.load() }
        .onChange(of: appModel.rescanToken) { _, _ in Task { await model.load() } }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in model.refreshProcesses() }
    }

    private func trailing(for row: SpeedUpModel.Row) -> String {
        switch row {
        case .startup: "\(model.startupItems.filter(\.isEnabled).count) enabled"
        case .heavy: (model.memory?.used ?? 0).formattedBytes
        case .ram: model.memory.map { "\(Int(($0.usedFraction * 100).rounded()))% used" } ?? "–"
        default: ""
        }
    }

    @ViewBuilder private func detail(for row: SpeedUpModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Image(systemName: row.systemImage).font(.title2).foregroundStyle(Theme.accent); Text(row.rawValue).font(.title3.weight(.semibold)) }
                Text(row.description).font(.callout).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider().padding(.horizontal, 16)
            switch row {
            case .startup:
                List(model.startupItems.filter(\.isEnabled)) { item in
                    HStack(spacing: 10) {
                        FileIcon(url: item.ownerAppURL ?? item.plistURL, size: 24)
                        VStack(alignment: .leading) { Text(item.title); Text(item.kind.rawValue).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if item.canToggle {
                            Button("Disable") { Task { _ = await StartupController(runAsRoot: appModel.helper.isAvailable ? appModel.helper.rootRunner() : nil).setEnabled(item, false); await model.load() } }
                                .controlSize(.small)
                        }
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
                Button("Manage all startup programs") { appModel.selectedSection = .startup }.buttonStyle(.link).padding(16)
            case .heavy:
                List(model.heavyApps) { usage in
                    HStack(spacing: 10) {
                        FileIcon(url: usage.bundlePath.map { URL(filePath: $0) }, size: 24)
                        VStack(alignment: .leading) { Text(usage.name); Text("\(usage.processes.count) process\(usage.processes.count == 1 ? "" : "es")").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(usage.memory.formattedBytes).font(.callout.monospacedDigit())
                        if usage.bundlePath != nil, usage.bundlePath != Bundle.main.bundlePath {
                            Button("Quit") { model.quit(usage) }.controlSize(.small)
                        }
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
            case .ram:
                if let memory = model.memory {
                    VStack(alignment: .leading, spacing: 10) {
                        CapacityBar(segments: [("App memory", memory.appMemory, Theme.categoryPalette[0]), ("Wired", memory.wired, Theme.categoryPalette[1]),
                                               ("Compressed", memory.compressed, Theme.categoryPalette[2]), ("Cached", memory.cached, Theme.categoryPalette[5])], total: memory.total)
                        HStack(spacing: 16) {
                            LegendDot(color: Theme.categoryPalette[0], label: "App memory", value: memory.appMemory.formattedBytes)
                            LegendDot(color: Theme.categoryPalette[1], label: "Wired", value: memory.wired.formattedBytes)
                            LegendDot(color: Theme.categoryPalette[2], label: "Compressed", value: memory.compressed.formattedBytes)
                            LegendDot(color: Theme.categoryPalette[5], label: "Cached files", value: memory.cached.formattedBytes)
                        }
                        Text("\(memory.used.formattedBytes) of \(memory.total.formattedBytes) used · swap \(memory.swapUsed.formattedBytes)").font(.callout).foregroundStyle(.secondary)
                        actionButton("Free Up RAM", key: "ram", task: .optimizeRAM)
                    }
                    .padding(16)
                }
                Spacer()
            case .spotlight:
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(appModel.volumes) { volume in
                        HStack {
                            Text(volume.name)
                            Spacer()
                            actionButton("Reindex", key: "spotlight:\(volume.id)", task: .reindexSpotlight(mount: volume.url.path))
                        }
                    }
                }
                .padding(16)
                Spacer()
            case .mail:
                VStack(alignment: .leading, spacing: 10) { actionButton("Reindex Mail", key: "mail", task: .reindexMail) }.padding(16)
                Spacer()
            case .browserExtensions, .plugins:
                Button("Open Extensions") { appModel.selectedSection = .extensions }.buttonStyle(PrimaryActionButtonStyle()).padding(16)
                Spacer()
            }
        }
    }

    @ViewBuilder private func actionButton(_ title: String, key: String, task: MaintenanceTask) -> some View {
        HStack(spacing: 10) {
            Button(title) { Task { await model.run(task, key: key, helper: appModel.helper) } }
                .buttonStyle(PrimaryActionButtonStyle()).disabled(model.busy.contains(key))
            if model.busy.contains(key) { ProgressView().controlSize(.small) }
            if let message = model.messages[key] { Text(message).font(.callout).foregroundStyle(message == "Done." ? Theme.success : Theme.warning) }
        }
    }
}
