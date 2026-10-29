import SwiftUI
import CleanCore

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } detail: {
            SectionContainer(section: model.selectedSection)
        }
        .navigationSplitViewStyle(.balanced)
        .background(Theme.backgroundGradient(for: scheme).ignoresSafeArea())
        .sheet(isPresented: Binding(
            get: { model.needsFullDiskAccessPrompt },
            set: { if !$0 { model.isFullDiskAccessSheetDismissed = true } }
        )) {
            FullDiskAccessView()
        }
        .sheet(isPresented: $model.showHistory) { HistoryView().environment(model) }
        .task { _ = await model.installedApps() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in model.refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in model.refreshVolumes() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
            model.refreshVolumes()
        }
    }
}

/// Routes a sidebar selection to its section view.
struct SectionContainer: View {
    let section: AppSection

    var body: some View {
        Group {
            switch section {
            case .overview: OverviewView()
            case .applications: ApplicationsView()
            case .cleanUp: CleanUpView()
            case .startup: StartupView()
            case .extensions: ExtensionsView()
            case .speedUp: SpeedUpView()
            case .manageFiles: ManageFilesView()
            case .biggestFiles: BiggestFilesView()
            case .duplicates: DuplicatesView()
            case .updates: UpdatesView()
            default: PlaceholderSectionView(section: section)
            }
        }
        .id(section)
    }
}
