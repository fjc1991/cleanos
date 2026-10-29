import SwiftUI
import CleanCore

/// Onboarding sheet explaining why Full Disk Access is needed and how to grant it.
struct FullDiskAccessView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.accentSecondary], startPoint: .top, endPoint: .bottom))
            Text("Grant Full Disk Access").font(.title2.weight(.semibold))
            Text("CleanOS scans caches, logs, service files and the Trash of every disk. macOS hides most of those folders from apps until you allow Full Disk Access. The app only reads sizes until you confirm a removal.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            VStack(alignment: .leading, spacing: 8) {
                Label("Open System Settings → Privacy & Security → Full Disk Access", systemImage: "1.circle")
                Label("Turn on CleanOS in the list (drag the app in if it is missing)", systemImage: "2.circle")
                Label("Come back here; the status updates automatically", systemImage: "3.circle")
            }
            .font(.callout)
            .frame(maxWidth: 420, alignment: .leading)
            HStack {
                Button("Not Now") { model.isFullDiskAccessSheetDismissed = true; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open System Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                    .buttonStyle(PrimaryActionButtonStyle())
            }
            .frame(maxWidth: 420)
            if model.fullDiskAccess == .granted {
                Label("Full Disk Access is granted", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
            }
        }
        .padding(32)
        .frame(width: 520)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
            if model.fullDiskAccess == .granted { dismiss() }
        }
    }
}
