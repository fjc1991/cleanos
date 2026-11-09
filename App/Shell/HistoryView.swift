import SwiftUI
import CleanCore

/// Every removal session with its entries; items that are still in the Trash can be put back.
struct HistoryView: View {
    @State private var pendingDelete: JournalSession?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [JournalSession] = []
    @State private var selectedID: UUID?
    @State private var message: String?
    @State private var busy = false

    private var selected: JournalSession? { sessions.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.title3.weight(.semibold))
                Spacer()
                Button("Open Trash") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            HSplitView {
                List(selection: $selectedID) {
                    ForEach(sessions) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title).lineLimit(1)
                            Text("\(session.startedAt.formatted(.dateTime.day().month().year().hour().minute())) · \(countText(session.entries.filter { $0.action != .restored }.count, "item")) · \(session.totalBytes.formattedBytes)")
                                .font(.caption).foregroundStyle(.secondary)
                            if !session.restorableEntries.isEmpty {
                                Text("\(session.restorableEntries.count) restorable").font(.caption2).foregroundStyle(Theme.success)
                            }
                        }
                        .tag(session.id)
                    }
                }
                .frame(minWidth: 260, idealWidth: 300)
                VStack(spacing: 0) {
                    if let session = selected {
                        HStack {
                            Text(session.title).font(.headline)
                            Spacer()
                            Button("Restore All Restorable") { Task { await restore(session: session) } }.disabled(session.restorableEntries.isEmpty || busy)
                            Button("Delete Record", role: .destructive) { pendingDelete = session }
                        }
                        .padding(12)
                        Divider()
                        List(session.entries) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: symbol(entry.action)).foregroundStyle(color(entry.action)).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(URL(filePath: entry.originalPath).lastPathComponent).lineLimit(1)
                                    Text(entry.detail ?? entry.originalPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(entry.size.formattedBytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                if entry.isRestorable {
                                    Button("Restore") { Task { await restore(entry: entry, in: session) } }.controlSize(.small).disabled(busy)
                                } else if entry.action == .movedToTrash {
                                    Text("gone").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .contextMenu {
                                Button("Reveal Original Location") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: entry.originalPath).deletingLastPathComponent()]) }
                                if let trashed = entry.trashedPath, entry.isRestorable { Button("Reveal in Trash") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: trashed)]) } }
                            }
                        }
                    } else {
                        ContentUnavailableView("Select a session", systemImage: "clock.arrow.circlepath",
                                               description: Text(sessions.isEmpty ? "Nothing has been removed yet." : "Items moved to the Trash can be restored while they are still there."))
                    }
                }
                .frame(minWidth: 380)
            }
            if let message {
                Divider()
                Text(message).font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 760, height: 480)
        .task { await reload() }
        .confirmationDialog("Delete this record from History?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete Record", role: .destructive) {
                if let session = pendingDelete { Task { await deleteRecord(session) } }
                pendingDelete = nil
            }
        } message: {
            Text((pendingDelete?.restorableEntries.isEmpty ?? true)
                 ? "The removed items are not affected."
                 : "CleanOS will no longer be able to put its items back; they stay in the Trash, where Finder's Put Back may still work.")
        }
    }

    private func reload() async {
        sessions = (try? await model.journal.allSessions()) ?? []
        if selectedID == nil { selectedID = sessions.first?.id }
    }

    private func restore(session: JournalSession) async {
        busy = true
        defer { busy = false }
        do {
            let report = try await model.journal.restore(sessionID: session.id)
            message = "Restored \(report.restored.count) item\(report.restored.count == 1 ? "" : "s")" + (report.failed.isEmpty ? "." : "; \(report.failed.count) could not be restored: \(report.failed.first?.error ?? "").")
        } catch { message = error.localizedDescription }
        await reload()
    }

    private func restore(entry: JournalEntry, in session: JournalSession) async {
        busy = true
        defer { busy = false }
        do {
            let report = try await model.journal.restore(entryID: entry.id, in: session.id)
            message = report.failed.isEmpty ? "Restored \(URL(filePath: entry.originalPath).lastPathComponent)." : (report.failed.first?.error ?? "Could not restore.")
        } catch { message = error.localizedDescription }
        await reload()
    }

    private func deleteRecord(_ session: JournalSession) async {
        try? await model.journal.deleteSession(id: session.id)
        selectedID = nil
        await reload()
    }

    private func symbol(_ action: JournalAction) -> String {
        switch action {
        case .movedToTrash: "trash"
        case .deletedPermanently: "xmark.bin"
        case .restored: "arrow.uturn.backward"
        case .registrationRemoved: "link"
        case .launchdDisabled, .launchdEnabled: "paperplane"
        case .lineRemoved: "text.alignleft"
        }
    }

    private func color(_ action: JournalAction) -> Color {
        switch action {
        case .restored: Theme.success
        case .deletedPermanently: Theme.danger
        default: Theme.accent
        }
    }
}
