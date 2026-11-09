import SwiftUI
import CleanCore

struct CleanOSApp: App {
    @State private var model = AppModel()
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.auto.rawValue

    init() {
        SettingsKey.registerDefaults()
    }

    var body: some Scene {
        WindowGroup("CleanOS") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 1040, minHeight: 660)
                .preferredColorScheme(AppearanceMode(rawValue: appearance)?.colorScheme)
                .onOpenURL { url in handle(url) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.updater.checkForUpdates() }
                    .disabled(!model.updater.canCheckForUpdates)
            }
            CommandGroup(after: .appSettings) {
                Button("History…") { model.showHistory = true }.keyboardShortcut("y", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                if let repository = AppLinks.repository {
                    Button("CleanOS on GitHub") { NSWorkspace.shared.open(repository) }
                    Button("Release Notes") { if let url = AppLinks.releases { NSWorkspace.shared.open(url) } }
                    Button("Report an Issue…") { if let url = AppLinks.issues { NSWorkspace.shared.open(url) } }
                }
                if AppLinks.support != nil {
                    Divider()
                    Button("Support CleanOS on Ko-fi…") { model.support.openSupportPage() }
                }
            }
            CommandMenu("Scan") {
                Button("Rescan") { model.rescanEverything() }.keyboardShortcut("r", modifiers: .command)
                Divider()
                ForEach(AppSection.allCases) { section in
                    Button(section.title) { model.selectedSection = section }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(AppearanceMode(rawValue: appearance)?.colorScheme)
        }
    }

    /// `cleanos://remains?bundleID=…` and `cleanos://section/<name>` deep links (used by the Trash watcher).
    private func handle(_ url: URL) {
        guard url.scheme == "cleanos" else { return }
        switch url.host() {
        case "remains":
            model.selectedSection = .applications
            model.pendingRemainsBundleID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "bundleID" }?.value ?? ""
            NSApp.activate()
        case "restore":
            // cleanos://restore?session=<uuid>&entry=<uuid>  — puts one journaled item back (used by History and automation).
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let session = items.first(where: { $0.name == "session" })?.value.flatMap(UUID.init(uuidString:)),
                  let entry = items.first(where: { $0.name == "entry" })?.value.flatMap(UUID.init(uuidString:)) else { return }
            Diagnostics.log("restore requested via URL")
            Task { await model.restore(entry: entry, in: session) }
            NSApp.activate()
        case "section":
            if let name = url.pathComponents.dropFirst().first, let section = AppSection(rawValue: name) {
                model.selectedSection = section
            }
        default: break
        }
    }
}
