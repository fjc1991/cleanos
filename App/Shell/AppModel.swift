import SwiftUI
import CleanCore

/// Application-wide state shared through the environment.
@MainActor
@Observable
final class AppModel {
    var selectedSection: AppSection = .overview
    var volumes: [VolumeInfo] = []
    var fullDiskAccess: FullDiskAccess.Status = .unknown
    var isFullDiskAccessSheetDismissed = false
    /// Set by a `cleanos://remains?bundleID=` deep link; the Applications section consumes it.
    var pendingRemainsBundleID: String?

    let journal = RemovalJournal()
    let cleanUp = CleanUpModel()
    let helper = HelperClient()
    /// Sparkle updater for CleanOS itself (Check for Updates…, Settings → Updates).
    let updater = UpdaterService()
    /// Launch counter and Ko-fi nudge (Overview banner, Help menu, Settings → About).
    let support = SupportPromptModel()
    var memory: MemoryStats? = MemoryStats.current()

    // Shared application catalog so every section reuses one scan.
    let catalog = AppCatalog()
    var installedApps: [InstalledApp] = []
    var installedAppsLoadedAt: Date?
    var isLoadingApps = false
    var appLoadProgress = 0

    /// Incremented by the Rescan command; sections observe it.
    var rescanToken = 0
    var showHistory = false
    /// Counts other sections report for the sidebar.
    var updateCount: Int?
    var remainsHighConfidenceCount: Int?
    var startupEnabledCount: Int?

    /// Installed apps, scanned at most every ten minutes unless forced.
    func installedApps(force: Bool = false) async -> [InstalledApp] {
        if !force, let at = installedAppsLoadedAt, Date().timeIntervalSince(at) < 600, !installedApps.isEmpty { return installedApps }
        if isLoadingApps {
            while isLoadingApps { try? await Task.sleep(for: .milliseconds(100)) }
            return installedApps
        }
        isLoadingApps = true
        appLoadProgress = 0
        let locations = AppSettings.scanLocations.map { URL(filePath: $0) }
        let apps = await catalog.scan(locations: locations, extraBundleURLs: NSWorkspace.shared.runningApplications.compactMap(\.bundleURL),
                                      includeSystem: UserDefaults.standard.bool(forKey: SettingsKey.showSystemApps), skipList: AppSettings.skipList) { [weak self] count in
            Task { @MainActor in self?.appLoadProgress = count }
        }
        installedApps = apps
        installedAppsLoadedAt = .now
        isLoadingApps = false
        try? await catalog.saveSnapshot(apps)
        return apps
    }

    func rescanEverything() {
        installedAppsLoadedAt = nil
        rescanToken += 1
    }

    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    init() {
        refreshVolumes()
        refreshPermissions()
        Diagnostics.log("launch \(Self.appVersion); full disk access = \(fullDiskAccess); arguments = \(CommandLine.arguments.dropFirst().joined(separator: " "))")
        support.recordLaunch()
        handleLaunchArguments()
    }

    /// `--restore <sessionUUID> <entryUUID>` puts a journaled item back on launch (automation and support).
    private func handleLaunchArguments() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--restore"), args.count > index + 2,
              let session = UUID(uuidString: args[index + 1]), let entry = UUID(uuidString: args[index + 2]) else { return }
        Task { await restore(entry: entry, in: session) }
    }

    func restore(entry: UUID, in session: UUID) async {
        do {
            let report = try await journal.restore(entryID: entry, in: session)
            Diagnostics.log("restore \(entry): restored=\(report.restored.map(\.originalPath)) failed=\(report.failed.map { "\($0.entry.originalPath): \($0.error)" })")
        } catch {
            Diagnostics.log("restore \(entry) threw: \(error)")
        }
        showHistory = true
    }

    func refreshVolumes() {
        let includeNetwork = UserDefaults.standard.bool(forKey: SettingsKey.includeNetworkVolumes)
        volumes = VolumeCatalog.mountedVolumes(includeNetwork: includeNetwork)
    }

    func refreshPermissions() {
        fullDiskAccess = FullDiskAccess.status()
    }

    func refreshMemory() {
        memory = MemoryStats.current()
    }

    var needsFullDiskAccessPrompt: Bool {
        fullDiskAccess != .granted && !isFullDiskAccessSheetDismissed
    }

    var bootVolume: VolumeInfo? { volumes.first(where: \.isRoot) }
}

/// `UserDefaults` keys used by Settings. Kept in one place so CleanCore-facing code and views agree.
enum SettingsKey {
    static let appearance = "appearance"
    static let detectTrashedApps = "detectTrashedApps"
    static let showSystemApps = "showSystemApps"
    static let removalMethod = "removalMethod"               // "trash" | "permanent"
    static let remindUnusedApps = "remindUnusedApps"
    static let showSummaryAfterRemoval = "showSummaryAfterRemoval"
    static let outdatedMonths = "outdatedMonths"
    static let scanLocations = "scanLocations"               // [String]
    static let skipList = "skipList"                         // [String]
    static let skipListUpdates = "skipListUpdates"           // [String]
    static let includeNetworkVolumes = "includeNetworkVolumes"
    static let enabledVolumeIDs = "enabledVolumeIDs"         // [String]
    static let sessionCount = "sessionCount"                 // launches so far; drives the Ko-fi nudge
    static let supportPromptLastShown = "supportPromptLastShown" // Date of the last "Maybe later"
    static let supportPromptDisabled = "supportPromptDisabled"   // "Don't ask again" or the tip page was opened

    static let defaultScanLocations = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            appearance: AppearanceMode.auto.rawValue,
            detectTrashedApps: true,
            showSystemApps: false,
            removalMethod: "trash",
            remindUnusedApps: true,
            showSummaryAfterRemoval: true,
            outdatedMonths: 3,
            scanLocations: defaultScanLocations,
            skipList: [String](),
            skipListUpdates: [String](),
            includeNetworkVolumes: false,
            enabledVolumeIDs: [String](),
        ])
    }
}


/// Appends one-line diagnostics to ~/Library/Application Support/com.cleanos/diagnostics.log (unified logging is not always visible).
enum Diagnostics {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/com.cleanos/diagnostics.log")
    static func log(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
        NSLog("%@", message)
    }
}
