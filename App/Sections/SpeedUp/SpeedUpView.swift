import SwiftUI
import CleanCore

@MainActor
@Observable
final class SpeedUpModel {
    enum Row: String, CaseIterable, Identifiable {
        case startup = "Startup apps", heavy = "Heavy applications", ram = "Memory", spotlight = "Reindex Spotlight", mail = "Reindex Mail",
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
            case .heavy: "Applications using a lot of memory (over 1 GB, or the largest few). Quitting the ones you are not using is what actually frees memory; each app asks to save first."
            case .ram: "How your memory is used right now. macOS manages memory itself and reuses cached files on demand, so there is nothing to purge by hand."
            case .spotlight: "Rebuild the Spotlight index if search shows wrong or missing results. Search on that disk is incomplete until indexing finishes, which can take hours. Needs administrator rights."
            case .mail: "Rebuild Mail's envelope index if Mail is slow or search misbehaves. Mail is quit, the old index goes to the Trash and Mail rebuilds it on its next launch, which can take a long time for big mailboxes."
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
    /// A maintenance task waiting for confirmation.
    var pendingTask: (task: MaintenanceTask, key: String, title: String)?
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

    private var isRefreshing = false

    /// Reads memory and the process table off the main thread.
    func refreshProcesses() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let (memory, groups) = await Task.detached(priority: .utility) { () -> (MemoryStats?, [AppMemoryUsage]) in
                let mine = getuid()
                return (MemoryStats.current(), ProcessMonitor.groupByApp(ProcessMonitor.snapshot().filter { $0.uid == mine }))
            }.value
            self.memory = memory
            let sorted = groups.sorted { $0.memory > $1.memory }
            heavyApps = sorted.enumerated().filter { index, usage in usage.memory > 1 << 30 || (index < 5 && usage.memory > 300 << 20) }.map(\.element)
            isRefreshing = false
        }
    }

    /// Only regular apps outside /System may be quit from here (never Finder, the Dock or CleanOS itself).
    func canQuit(_ usage: AppMemoryUsage) -> Bool {
        guard let path = usage.bundlePath, path != Bundle.main.bundlePath, !path.hasPrefix("/System/") else { return false }
        return usage.processes.contains { NSRunningApplication(processIdentifier: $0.pid)?.activationPolicy == .regular }
    }

    func quit(_ usage: AppMemoryUsage) {
        for process in usage.processes {
            if let app = NSRunningApplication(processIdentifier: process.pid) { app.terminate() }
        }
        Task { try? await Task.sleep(for: .seconds(1)); refreshProcesses() }
    }

    func run(_ task: MaintenanceTask, key: String, appModel: AppModel) async {
        busy.insert(key)
        defer { busy.remove(key); refreshProcesses() }
        if case .reindexMail = task {
            // Mail must really be gone before its database is touched.
            let mail = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail")
            for app in mail { app.terminate() }
            for _ in 0..<40 where !mail.allSatisfy(\.isTerminated) { try? await Task.sleep(for: .milliseconds(250)) }
            guard mail.allSatisfy(\.isTerminated) else {
                messages[key] = "Mail did not quit (it may be asking to save a message). Quit Mail and try again."
                return
            }
        }
        await appModel.helper.refreshAndVerify()
        let runner = MaintenanceRunner(runAsRoot: appModel.rootRunner())
        messages[key] = await runner.run(task) ?? "Done."
    }

    var taskCount: Int { startupItems.filter(\.isEnabled).count }
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
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { model.selected = row }
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
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if model.selected == .heavy || model.selected == .ram, NSApp.isActive { model.refreshProcesses() }
        }
        .alert(model.pendingTask?.title ?? "", isPresented: Binding(get: { model.pendingTask != nil }, set: { if !$0 { model.pendingTask = nil } })) {
            Button("Continue") {
                if let pending = model.pendingTask { Task { await model.run(pending.task, key: pending.key, appModel: appModel) } }
                model.pendingTask = nil
            }
            Button("Cancel", role: .cancel) { model.pendingTask = nil }
        } message: {
            Text(model.pendingTask.map { if case .reindexMail = $0.task { return SpeedUpModel.Row.mail.description } else { return SpeedUpModel.Row.spotlight.description } } ?? "")
        }
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
                        if item.canToggle && item.kind != .systemDaemon {
                            Button("Disable") {
                                Task {
                                    if let error = await StartupController(runAsRoot: appModel.rootRunner()).setEnabled(item, false) { model.messages["startup:\(item.id)"] = error }
                                    await model.load()
                                }
                            }
                            .controlSize(.small)
                        }
                        if let error = model.messages["startup:\(item.id)"] { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).help(error) }
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
                        if model.canQuit(usage) {
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
                        if memory.swapUsed > 2 << 30 {
                            Label("Your Mac is swapping to disk. Quitting heavy applications helps most.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                            Button("Show Heavy Applications") { model.selected = .heavy }.buttonStyle(.link)
                        }
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
                            actionButton("Reindex", key: "spotlight:\(volume.id)", task: .reindexSpotlight(mount: volume.url.path), confirm: "Rebuild the Spotlight index of \(volume.name)?")
                        }
                    }
                }
                .padding(16)
                Spacer()
            case .mail:
                VStack(alignment: .leading, spacing: 10) { actionButton("Reindex Mail", key: "mail", task: .reindexMail, confirm: "Quit Mail and rebuild its index?") }.padding(16)
                Spacer()
            case .browserExtensions, .plugins:
                Button("Open Extensions") { appModel.selectedSection = .extensions }.buttonStyle(PrimaryActionButtonStyle()).padding(16)
                Spacer()
            }
        }
    }

    @ViewBuilder private func actionButton(_ title: String, key: String, task: MaintenanceTask, confirm: String) -> some View {
        HStack(spacing: 10) {
            Button(title) { model.pendingTask = (task, key, confirm) }
                .buttonStyle(PrimaryActionButtonStyle()).disabled(model.busy.contains(key))
            if model.busy.contains(key) { ProgressView().controlSize(.small) }
            if let message = model.messages[key] { Text(message).font(.callout).foregroundStyle(message == "Done." ? Theme.success : Theme.warning) }
        }
    }
}
