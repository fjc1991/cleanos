import SwiftUI
import CleanCore
import ServiceManagement
import HelperProtocol

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            LocationsSettingsView().tabItem { Label("Locations", systemImage: "folder") }
            SkipListSettingsView().tabItem { Label("Skip List", systemImage: "minus.circle") }
            RemoveSettingsView().tabItem { Label("Remove", systemImage: "trash") }
            HelperSettingsView().tabItem { Label("Helper", systemImage: "wrench.and.screwdriver") }
            DiskAccessSettingsView().tabItem { Label("Disk Access", systemImage: "lock.shield") }
            AdvancedSettingsView().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            UpdatesSettingsView().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            AboutSettingsView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 720, height: 420)
    }
}

struct GeneralSettingsView: View {
    @AppStorage(SettingsKey.showSystemApps) private var showSystemApps = false
    @State private var watcherEnabled = SMAppService.loginItem(identifier: HelperConstants.trashWatcherBundleIdentifier).status == .enabled
    @State private var watcherStatus = SMAppService.loginItem(identifier: HelperConstants.trashWatcherBundleIdentifier).status
    @State private var watcherError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Detect apps moved to Trash and offer full removal", isOn: Binding(get: { watcherEnabled }, set: { setWatcher($0) }))
                Text("Get notified when an app is deleted so its leftover files can be removed too. Runs as a login item (CleanOS Trash Watcher).")
                    .font(.caption).foregroundStyle(.secondary)
                if watcherStatus == .requiresApproval {
                    HStack {
                        Text("Approve CleanOS Trash Watcher in System Settings → General → Login Items.").font(.caption).foregroundStyle(Theme.warning)
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                    }
                }
                if let watcherError { Text(watcherError).font(.caption).foregroundStyle(Theme.danger) }
            } header: { Text("App monitor") }
            Section {
                Toggle("Show system applications", isOn: $showSystemApps)
                Text("Built-in macOS apps cannot be removed, but their service files can be reset.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("System apps") }
        }
        .formStyle(.grouped)
    }

    private func setWatcher(_ enabled: Bool) {
        let service = SMAppService.loginItem(identifier: HelperConstants.trashWatcherBundleIdentifier)
        do {
            if enabled { try service.register() } else { try service.unregister() }
            watcherError = nil
        } catch {
            watcherError = error.localizedDescription
        }
        watcherStatus = service.status
        watcherEnabled = service.status == .enabled
        UserDefaults.standard.set(watcherEnabled, forKey: SettingsKey.detectTrashedApps)
    }
}

struct LocationsSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.scanLocations) private var locationsData: Data = Data()
    @AppStorage(SettingsKey.includeNetworkVolumes) private var includeNetworkVolumes = false
    @AppStorage(SettingsKey.enabledVolumeIDs) private var enabledVolumesData: Data = Data()
    @State private var selection: String?

    private var locations: [String] {
        get { (try? JSONDecoder().decode([String].self, from: locationsData)) ?? SettingsKey.defaultScanLocations }
    }
    private func setLocations(_ value: [String]) {
        locationsData = (try? JSONEncoder().encode(value)) ?? Data()
    }
    private var enabledVolumes: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: enabledVolumesData)) ?? [])
    }
    private func setEnabledVolumes(_ value: Set<String>) {
        enabledVolumesData = (try? JSONEncoder().encode(Array(value))) ?? Data()
        model.refreshVolumes()
    }

    var body: some View {
        Form {
            Section("Folders to scan for applications") {
                List(selection: $selection) {
                    ForEach(locations, id: \.self) { path in
                        Label(path, systemImage: "folder").tag(path)
                    }
                }
                .frame(minHeight: 110)
                HStack {
                    Button {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.prompt = "Add"
                        if panel.runModal() == .OK, let url = panel.url {
                            var current = locations
                            if !current.contains(url.path) { current.append(url.path) }
                            setLocations(current)
                        }
                    } label: { Image(systemName: "plus") }
                    Button {
                        if let selection { setLocations(locations.filter { $0 != selection }) }
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil || SettingsKey.defaultScanLocations.contains(selection ?? ""))
                    Text("Applications will be searched in the added folder and its subfolders.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Volumes") {
                ForEach(model.volumes) { volume in
                    Toggle(isOn: Binding(
                        get: { volume.isRoot || enabledVolumes.contains(volume.id) },
                        set: { on in var s = enabledVolumes; if on { s.insert(volume.id) } else { s.remove(volume.id) }; setEnabledVolumes(s) }
                    )) {
                        HStack {
                            Text(volume.name)
                            Text(volume.format).foregroundStyle(.secondary)
                            Spacer()
                            Text(volume.totalCapacity.formattedBytes).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(volume.isRoot)
                }
                Toggle("Include network volumes", isOn: $includeNetworkVolumes)
                    .onChange(of: includeNetworkVolumes) { model.refreshVolumes() }
            }
        }
        .formStyle(.grouped)
    }
}

struct SkipListSettingsView: View {
    @AppStorage(SettingsKey.skipList) private var skipData: Data = Data()
    @AppStorage(SettingsKey.skipListUpdates) private var skipUpdatesData: Data = Data()
    @State private var tab = 0
    @State private var selection: String?

    private func decode(_ data: Data) -> [String] { (try? JSONDecoder().decode([String].self, from: data)) ?? [] }
    private func encode(_ v: [String]) -> Data { (try? JSONEncoder().encode(v)) ?? Data() }

    var body: some View {
        VStack {
            Picker("", selection: $tab) {
                Text("Applications").tag(0)
                Text("Updates").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            let items = tab == 0 ? decode(skipData) : decode(skipUpdatesData)
            List(selection: $selection) {
                ForEach(items, id: \.self) { Label($0, systemImage: tab == 0 ? "folder" : "app").tag($0) }
            }
            .frame(minHeight: 200)
            HStack {
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = true
                    if panel.runModal() == .OK, let url = panel.url {
                        var current = items
                        if !current.contains(url.path) { current.append(url.path) }
                        if tab == 0 { skipData = encode(current) } else { skipUpdatesData = encode(current) }
                    }
                } label: { Image(systemName: "plus") }
                Button {
                    guard let selection else { return }
                    let current = items.filter { $0 != selection }
                    if tab == 0 { skipData = encode(current) } else { skipUpdatesData = encode(current) }
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                Text("Items in the Skip List are never selected or removed.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
    }
}

struct RemoveSettingsView: View {
    @AppStorage(SettingsKey.removalMethod) private var removalMethod = "trash"
    @AppStorage(SettingsKey.remindUnusedApps) private var remindUnusedApps = true
    @AppStorage(SettingsKey.showSummaryAfterRemoval) private var showSummary = true

    var body: some View {
        Form {
            Section("Removal method") {
                Picker("", selection: $removalMethod) {
                    VStack(alignment: .leading) {
                        Text("Move to Trash")
                        Text("Move items to Trash during removal. Everything can be restored from History.").font(.caption).foregroundStyle(.secondary)
                    }.tag("trash")
                    VStack(alignment: .leading) {
                        Text("Delete items permanently")
                        Text("Items will be permanently deleted and cannot be restored.").font(.caption).foregroundStyle(.secondary)
                    }.tag("permanent")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Section("Notifications") {
                Toggle("Remind me to clean up unused apps", isOn: $remindUnusedApps)
            }
            Section("Confirmation") {
                Toggle("Show detailed summary after successful removal or update", isOn: $showSummary)
            }
        }
        .formStyle(.grouped)
    }
}

struct DiskAccessSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: model.fullDiskAccess == .granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.title)
                    .foregroundStyle(model.fullDiskAccess == .granted ? Theme.success : Theme.warning)
                VStack(alignment: .leading) {
                    Text(model.fullDiskAccess == .granted ? "Full Disk Access is granted" : "Full Disk Access is not granted")
                        .font(.headline)
                    Text("Needed to scan caches, service files, hidden folders on external disks and the Trash of every volume.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if model.fullDiskAccess != .granted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Click the button below to open Privacy & Security → Full Disk Access.")
                    Text("2. Turn on CleanOS. If it is not listed, click + and pick CleanOS from Applications.")
                    Text("3. Switch back to CleanOS; the status updates automatically.")
                }
                .font(.callout)
                Button("Open System Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                    .buttonStyle(PrimaryActionButtonStyle())
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AdvancedSettingsView: View {
    @AppStorage(SettingsKey.outdatedMonths) private var outdatedMonths = 3
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.auto.rawValue
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section("Outdated apps criteria") {
                Picker("Last opened date", selection: $outdatedMonths) {
                    Text("more than 1 month ago").tag(1)
                    Text("more than 3 months ago").tag(3)
                    Text("more than 6 months ago").tag(6)
                    Text("more than 1 year ago").tag(12)
                }
            }
            Section("Appearance mode") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section {
                Button("Reset Application Settings") { showResetConfirmation = true }
                    .confirmationDialog("Reset all CleanOS settings to their defaults?", isPresented: $showResetConfirmation) {
                        Button("Reset", role: .destructive) {
                            let defaults = UserDefaults.standard
                            for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
                            SettingsKey.registerDefaults()
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }
}


struct HelperSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let helper = model.helper
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: helper.isAvailable ? "checkmark.shield.fill" : "wrench.and.screwdriver")
                    .font(.title).foregroundStyle(helper.isAvailable ? Theme.success : Theme.accent)
                VStack(alignment: .leading) {
                    Text(statusTitle(helper.status)).font(.headline)
                    Text("The helper runs with administrator privileges to remove files owned by the system (launch daemons, privileged helpers, /Library caches), delete snapshots, reindex Spotlight and reset system permissions. It only accepts connections from CleanOS.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let version = helper.version { Text("Helper version \(version)").font(.caption).foregroundStyle(.secondary) }
            if let error = helper.lastError { Text(error).font(.caption).foregroundStyle(Theme.danger) }
            HStack {
                if helper.isAvailable {
                    Button("Disable Helper") { Task { await helper.unregister() } }
                    Button("Check Version") { Task { await helper.checkVersion() } }
                } else {
                    Button("Enable Helper") { helper.register() }.buttonStyle(PrimaryActionButtonStyle())
                    if helper.status == .requiresApproval {
                        Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Button("Refresh") { helper.refresh() }
            }
            Text("macOS asks you to allow \"CleanOS\" under System Settings → General → Login Items & Extensions the first time. Development builds signed ad hoc may be refused by macOS; a Developer ID build is required for distribution.")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { helper.refresh(); if helper.isAvailable { await helper.checkVersion() } }
    }

    private func statusTitle(_ status: HelperClient.Status) -> String {
        switch status {
        case .enabled: "Helper is enabled"
        case .requiresApproval: "Helper needs approval in System Settings"
        case .notRegistered: "Helper is not enabled"
        case .notFound: "Helper is missing from the app bundle"
        case .unknown: "Helper status unknown"
        }
    }
}


/// Sparkle preferences for CleanOS's own updates.
struct UpdatesSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updater = model.updater
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
                    .disabled(!updater.automaticallyChecksForUpdates)
                Text("CleanOS looks for a new version once a day. With automatic installation the update downloads in the background and you are asked before it is installed; otherwise you are told about it and choose when to install.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Software updates") }
            Section {
                LabeledContent("Installed version", value: AppModel.appVersion)
                LabeledContent("Last checked", value: updater.lastCheckDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                if let feed = updater.feedURL { LabeledContent("Update feed", value: feed.absoluteString).font(.caption).foregroundStyle(.secondary) }
                if let error = updater.startupError {
                    Text("The updater is not running: \(error)").font(.caption).foregroundStyle(Theme.danger)
                }
                Button("Check Now") { model.updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } header: { Text("Status") }
        }
        .formStyle(.grouped)
    }
}

/// Version, project links and the Ko-fi tip link.
struct AboutSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("CleanOS").font(.title2.weight(.semibold))
            Text("Version \(AppModel.appVersion)").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Check for Updates…") { model.updater.checkForUpdates() }
                    .disabled(!model.updater.canCheckForUpdates)
                if let repository = AppLinks.repository {
                    Button("GitHub") { NSWorkspace.shared.open(repository) }
                    Button("Report an Issue") { if let url = AppLinks.issues { NSWorkspace.shared.open(url) } }
                }
            }
            .padding(.top, 4)
            if model.support.isConfigured {
                Divider().padding(.vertical, 8)
                Text("CleanOS is free and made by one person. If it has saved you space or time, a small tip keeps it going.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                Button { model.support.openSupportPage() } label: { Label("Support CleanOS on Ko-fi", systemImage: "cup.and.saucer.fill") }
                    .buttonStyle(PrimaryActionButtonStyle())
                Text("Used in \(model.support.sessionCount) sessions so far.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("Set CLEANOS_KOFI_NAME in project.yml to enable the tip link.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
