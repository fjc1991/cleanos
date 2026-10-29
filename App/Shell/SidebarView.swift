import SwiftUI
import CleanCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedSection) {
            ForEach(AppSection.Group.allCases, id: \.self) { group in
                let sections = AppSection.allCases.filter { $0.group == group }
                if group == .main {
                    ForEach(sections) { SidebarRow(section: $0) }
                } else {
                    Section(group.rawValue) {
                        ForEach(sections) { SidebarRow(section: $0) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            PermissionStatusFooter()
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
    }
}

private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let section: AppSection
    var body: some View {
        HStack {
            Label(section.title, systemImage: section.systemImage)
            Spacer()
            if let badge { Text(badge).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .tag(section)
    }

    private var badge: String? {
        switch section {
        case .cleanUp: model.cleanUp.results.isEmpty ? nil : model.cleanUp.junkTotal.formattedBytes
        case .applications:
            if let count = model.remainsHighConfidenceCount, count > 0 { "\(model.installedApps.count) · \(count) remains" }
            else { model.installedApps.isEmpty ? nil : "\(model.installedApps.count)" }
        case .updates: model.updateCount.map { $0 == 0 ? "Up to date" : "\($0)" }
        case .startup: model.startupEnabledCount.map { "\($0) enabled" }
        case .overview: model.cleanUp.results.isEmpty ? nil : model.cleanUp.junkTotal.formattedBytes
        default: nil
        }
    }
}

/// Small footer that shows whether Full Disk Access is granted, mirroring the originals' Disk Access hint.
private struct PermissionStatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Button { model.showHistory = true } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(.link).font(.caption)
                    .help("Everything CleanOS removed, with Restore")
                Spacer()
            }
            .padding(.horizontal, 12)
            HStack(spacing: 8) {
                Circle()
                    .fill(model.fullDiskAccess == .granted ? Theme.success : Theme.warning)
                    .frame(width: 8, height: 8)
                Text(model.fullDiskAccess == .granted ? "Full Disk Access granted" : "Full Disk Access needed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.fullDiskAccess != .granted {
                    Button("Grant") { model.isFullDiskAccessSheetDismissed = false }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }
}
