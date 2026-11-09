import SwiftUI
import CleanCore
import UserNotifications

/// Everything a removal needs: what to remove and how to quit the affected apps first.
struct RemovalFlow: Identifiable {
    let id = UUID()
    let title: String
    let apps: [InstalledApp]
    let items: [ScanItem]
    /// Quits the affected apps; returns the names of processes that are still running afterwards.
    var quit: @MainActor () async -> [String] = { [] }

    var bundles: [ScanItem] { items.filter { $0.kind == .bundle } }
    var others: [ScanItem] { items.filter { $0.kind != .bundle } }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// Review → progress → results, shared by every section that removes things.
struct RemovalSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let flow: RemovalFlow
    var onFinished: (RemovalResult) -> Void

    enum Phase { case review, blocked([String]), running(done: Int, total: Int, current: ScanItem?), finished(RemovalResult) }
    @State private var phase: Phase = .review
    @State private var permanently = AppSettings.removesPermanently
    @State private var recent: [ScanItem] = []
    @State private var freedSoFar: Int64 = 0
    @State private var excluded: Set<String> = []
    @State private var lastProgress = Date.now
    @State private var confirmPermanentFor: [ScanItem]?

    private var includedItems: [ScanItem] { flow.items.filter { !excluded.contains($0.id) } }
    private var includedSize: Int64 { includedItems.reduce(0) { $0 + $1.size } }
    private var isRunning: Bool { if case .running = phase { return true } else { return false } }
    /// Apps with processes running from their bundle, and how many processes; read once when the sheet opens.
    @State private var runningApps: [InstalledApp] = []
    @State private var runningProcessCount = 0
    private var plan: RemovalPlan { RemovalPlan(selected: includedItems, permanently: permanently) }
    /// Deleting for good: either the user's choice or items that are already in a Trash.
    private var isDestructive: Bool { permanently || includedItems.contains { $0.payload["permanent"] == "1" } }

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .review: review
            case .blocked(let survivors): blocked(survivors)
            case .running(let done, let total, let current):
                CleanupProgressView(title: flow.title, done: done, total: total, current: current, recent: recent, freedSoFar: freedSoFar,
                                    groups: Array(NSOrderedSet(array: includedItems.map(\.group))) as? [String] ?? [])
                    .overlay(alignment: .bottomTrailing) { stalledEscape }
            case .finished(let result): finished(result)
            }
        }
        .frame(width: 640, height: 560)
        .interactiveDismissDisabled(isRunning)
        .task {
            let apps = flow.apps
            let found = await Task.detached(priority: .userInitiated) {
                apps.map { ($0, ProcessMonitor.processes(inBundle: $0.url.standardizedFileURL.path).count) }.filter { $0.1 > 0 }
            }.value
            runningApps = found.map(\.0)
            runningProcessCount = found.reduce(0) { $0 + $1.1 }
        }
        .alert("Delete permanently?", isPresented: Binding(get: { confirmPermanentFor != nil }, set: { if !$0 { confirmPermanentFor = nil } })) {
            Button("Delete Permanently", role: .destructive) {
                let items = confirmPermanentFor ?? []
                confirmPermanentFor = nil
                Task { await execute(RemovalPlan(selected: items, permanently: true)) }
            }
            Button("Cancel", role: .cancel) { confirmPermanentFor = nil }
        } message: {
            Text("\(countText(confirmPermanentFor?.count ?? 0, "item")) will be deleted and cannot be restored, not even from History.")
        }
    }

    // MARK: Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summaryTitle).font(.title3.weight(.semibold))
            Text(summaryText).font(.callout).foregroundStyle(isDestructive ? Theme.warning : .secondary)
            List {
                ForEach(Dictionary(grouping: flow.items, by: \.group).keys.sorted { LeftoverGroups.rank($0) < LeftoverGroups.rank($1) }, id: \.self) { group in
                    Section(group) {
                        ForEach(flow.items.filter { $0.group == group }) { item in
                            HStack {
                                TriStateCheckbox(state: excluded.contains(item.id) ? .none : .all) {
                                    if excluded.contains(item.id) { excluded.remove(item.id) } else { excluded.insert(item.id) }
                                }
                                .accessibilityLabel("Include \(item.title)")
                                if item.kind == .registration { Image(systemName: CleanupSymbols.symbol(for: item.group)).foregroundStyle(Theme.accent) } else { FileIcon(url: item.url) }
                                VStack(alignment: .leading) {
                                    Text(item.title).lineLimit(1)
                                    Text(item.subtitle ?? item.url?.path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                if item.needsRoot {
                                    Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Needs administrator rights").accessibilityLabel("Needs administrator rights")
                                }
                                TierBadge(tier: item.tier)
                                Text(item.size.formattedBytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                            }
                            .opacity(excluded.contains(item.id) ? 0.45 : 1)
                            .contextMenu { if let url = item.url { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } } }
                        }
                    }
                }
            }
            .listStyle(.inset)
            if !runningApps.isEmpty {
                let processCount = runningProcessCount
                Label("\(runningApps.map(\.name).joined(separator: ", ")) \(runningApps.count == 1 ? "has" : "have") \(countText(processCount, "running process", plural: "running processes")) (app, helpers, background agents); they will be quit first. Unsaved changes in them may be lost.", systemImage: "power")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if includedItems.contains(where: { $0.tier == .caution }) {
                Label("Some items are marked Caution: they may hold your own data or be shared with other apps.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Theme.warning)
            }
            if includedItems.contains(where: \.needsRoot) {
                Label(appModel.helper.isAvailable ? "Items with a lock are removed by the CleanOS helper."
                                                  : "Items with a lock belong to the system or another user. macOS will ask for your administrator password once.",
                      systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Delete permanently", isOn: $permanently).toggleStyle(.checkbox)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if isDestructive {
                    Button(role: .destructive) { Task { await start() } } label: { Text(excluded.isEmpty ? "Delete Permanently" : "Delete \(includedItems.count) Permanently") }
                        .buttonStyle(.borderedProminent).tint(Theme.danger)
                        .disabled(includedItems.isEmpty)
                } else {
                    Button(flow.title.hasPrefix("Reset") ? "Reset" : (excluded.isEmpty ? "Remove" : "Remove \(includedItems.count)")) { Task { await start() } }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(includedItems.isEmpty)
                }
            }
        }
        .padding(20)
    }

    private var summaryTitle: String {
        let apps = includedItems.filter { $0.kind == .bundle }.count
        let items = includedItems.filter { $0.kind != .bundle }.count
        if flow.title.hasPrefix("Reset") { return "\(flow.title) · \(countText(items, "item")) · \(includedSize.formattedBytes)" }
        switch (apps, items) {
        case (0, _): return "Remove \(countText(items, "item")) · \(includedSize.formattedBytes)"
        case (_, 0): return "Uninstall \(countText(apps, "app")) · \(includedSize.formattedBytes)"
        default: return "Uninstall \(countText(apps, "app")) and \(countText(items, "related item")) · \(includedSize.formattedBytes)"
        }
    }

    private var summaryText: String {
        if permanently { return "Everything below will be deleted permanently and cannot be restored." }
        let plan = plan
        let irreversible = plan.irreversibleCount
        let base = "Items are moved to the Trash and can be put back from History."
        guard irreversible > 0 else { return base }
        return base + " \(countText(irreversible, "item")) (Trash contents and system settings) cannot be restored."
    }

    // MARK: Running

    private func start() async {
        let plan = plan
        phase = .running(done: 0, total: plan.count, current: nil)
        lastProgress = .now
        let survivors = await flow.quit()
        if !survivors.isEmpty {
            phase = .blocked(survivors)
            return
        }
        await execute(plan)
    }

    private func blocked(_ survivors: [String]) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 48)).foregroundStyle(Theme.warning)
            Text("Some processes are still running").font(.title3.weight(.semibold))
            Text("\(survivors.joined(separator: ", ")) could not be stopped; they probably belong to the system or another user. Removing the app while they run can leave parts of it behind until you restart.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 480)
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove Anyway") { Task { await execute(plan) } }.buttonStyle(PrimaryActionButtonStyle())
            }
        }
        .padding(20)
    }

    /// Appears when nothing has progressed for a while, so no failure can trap the user in the sheet.
    @ViewBuilder private var stalledEscape: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if context.date.timeIntervalSince(lastProgress) > 20 {
                Button("Close") { dismiss() }
                    .help("The removal continues in the background; History shows what was removed.")
                    .padding(16)
            }
        }
    }

    private func execute(_ plan: RemovalPlan) async {
        guard !plan.isEmpty else { return }
        recent = []
        freedSoFar = 0
        phase = .running(done: 0, total: plan.count, current: nil)
        lastProgress = .now
        await appModel.helper.refreshAndVerify()
        let executor = RemovalExecutor(journal: appModel.journal, rootRemover: appModel.rootRemover(),
                                       registrationRemover: RegistrationRemover(runAsRoot: appModel.rootRunner()))
        let result = await executor.execute(plan, title: flow.title, appVersion: AppModel.appVersion) { done, total, current in
            Task { @MainActor in
                lastProgress = .now
                if case .running(let previousDone, _, let previous) = phase, let previous, done > previousDone {
                    withAnimation(.spring(duration: 0.4)) {
                        recent.insert(previous, at: 0)
                        if recent.count > 6 { recent.removeLast() }
                        freedSoFar += previous.size
                    }
                }
                withAnimation(.easeInOut(duration: 0.35)) { phase = .running(done: done, total: total, current: current) }
            }
        }
        for failure in result.failed {
            Diagnostics.log("removal failed [\(failure.problem.rawValue)] \(failure.item.url?.path ?? failure.item.id): \(failure.error)")
        }
        try? await Task.sleep(for: .milliseconds(600))   // let the ring reach 100 % before the results appear
        withAnimation(.spring(duration: 0.5)) { phase = .finished(result) }
        onFinished(result)
        if !NSApp.isActive { await notifyCompletion(result) }
    }

    /// Posts a notification when the clean-up finished while another app was in front.
    private func notifyCompletion(_ result: RemovalResult) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(flow.title) finished"
        content.body = "\(countText(result.succeeded.count, "item")) removed" + (result.failed.isEmpty ? "." : "; \(result.failed.count) need your attention.")
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Finished

    private func headline(_ result: RemovalResult) -> String {
        if result.isDryRun { return "Simulation finished: nothing was removed" }
        if result.failed.isEmpty { return "Removed \(countText(result.succeeded.count, "item"))" }
        if result.succeeded.isEmpty { return "Nothing was removed" }
        return "Removed \(result.succeeded.count) of \(result.succeeded.count + result.failed.count); \(result.failed.count) need\(result.failed.count == 1 ? "s" : "") your attention"
    }

    private func spaceLine(_ result: RemovalResult) -> String {
        var parts: [String] = []
        if result.trashedBytes > 0 { parts.append("\(result.trashedBytes.formattedBytes) moved to the Trash") }
        if result.freedBytes > 0 { parts.append("\(result.freedBytes.formattedBytes) freed") }
        return parts.isEmpty ? "" : parts.joined(separator: ", ")
    }

    private func finished(_ result: RemovalResult) -> some View {
        VStack(spacing: 12) {
            let ok = result.failed.isEmpty
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(ok ? AnyShapeStyle(LinearGradient(colors: [Theme.success, Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(Theme.warning))
                .symbolEffect(.bounce, value: result.succeeded.count)
                .padding(.top, 8)
            Text(headline(result)).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            if !spaceLine(result).isEmpty {
                Text(spaceLine(result)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if result.journalFailed {
                Label("History could not record these removals; use the Trash to put things back.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
            if !result.failed.isEmpty { failureList(result) }
            Spacer(minLength: 0)
            HStack {
                if !result.isDryRun, !result.trashedPaths.isEmpty {
                    Button("Show in Trash") { NSWorkspace.shared.activateFileViewerSelecting(result.trashedPaths.prefix(20).map { URL(filePath: $0) }) }
                }
                if !result.isDryRun, result.sessionID != nil {
                    Button("History…") { dismiss(); appModel.showHistory = true }
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryActionButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func failureList(_ result: RemovalResult) -> some View {
        let groups = Dictionary(grouping: result.failed, by: \.problem)
        let order: [RemovalProblem] = [.needsAdministrator, .cancelled, .privacyProtected, .stillRunning, .noTrash, .readOnlyVolume, .locked, .protectedLocation, .notFound, .other]
        return List {
            ForEach(order.filter { groups[$0] != nil }, id: \.self) { problem in
                let failures = groups[problem] ?? []
                Section {
                    ForEach(failures) { failure in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.item.title).lineLimit(1)
                                Text(failure.error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if let url = failure.item.url, FileManager.default.fileExists(atPath: url.path) {
                                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                                    .buttonStyle(.borderless).help("Reveal in Finder").accessibilityLabel("Reveal \(failure.item.title) in Finder")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(Self.title(for: problem)).font(.headline)
                        Spacer()
                        actions(for: problem, items: failures.map(\.item))
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(maxHeight: 250)
    }

    @ViewBuilder private func actions(for problem: RemovalProblem, items: [ScanItem]) -> some View {
        switch problem {
        case .needsAdministrator, .cancelled:
            Button("Try Again with Password") { Task { await execute(RemovalPlan(selected: items, permanently: permanently)) } }.controlSize(.small)
        case .privacyProtected:
            if items.contains(where: { $0.url?.pathExtension == "app" }) {
                Button("Open App Management") { NSWorkspace.shared.open(Self.appManagementURL) }.controlSize(.small)
            }
            Button("Open Full Disk Access") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }.controlSize(.small)
            Button("Try Again") { Task { await execute(RemovalPlan(selected: items, permanently: permanently)) } }.controlSize(.small)
        case .stillRunning, .other:
            Button("Try Again") { Task { await execute(RemovalPlan(selected: items, permanently: permanently)) } }.controlSize(.small)
        case .noTrash:
            Button("Delete Permanently…") { confirmPermanentFor = items }.controlSize(.small)
        case .readOnlyVolume, .locked, .protectedLocation, .notFound:
            EmptyView()
        }
    }

    static let appManagementURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!

    static func title(for problem: RemovalProblem) -> String {
        switch problem {
        case .needsAdministrator: "Needs administrator rights"
        case .cancelled: "Password prompt cancelled"
        case .privacyProtected: "Blocked by macOS privacy protection"
        case .stillRunning: "Still in use"
        case .noTrash: "This disk has no Trash"
        case .readOnlyVolume: "On a read-only disk"
        case .locked: "Locked or protected by macOS"
        case .protectedLocation: "Protected by CleanOS"
        case .notFound: "No longer there"
        case .other: "Could not be removed"
        }
    }
}

/// "1 item", "3 items".
func countText(_ count: Int, _ singular: String, plural: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
}

/// Animated "cleaning in progress" view: gradient ring with a sweeping highlight, the item being removed,
/// pulsing icons for the kinds of things in the batch and a feed of what was just removed.
struct CleanupProgressView: View {
    let title: String
    let done: Int
    let total: Int
    let current: ScanItem?
    let recent: [ScanItem]
    let freedSoFar: Int64
    let groups: [String]

    private var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    var body: some View {
        VStack(spacing: 22) {
            Text(done >= total && total > 0 ? "Finishing up…" : "Cleaning up…").font(.title3.weight(.semibold))
            GroupIconRow(groups: groups, activeGroup: current?.group)
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: max(0.012, fraction))
                    .stroke(AngularGradient(colors: [Theme.accent, Theme.accentSecondary, Theme.success, Theme.accent], center: .center),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Theme.accent.opacity(0.45), radius: 10)
                    .animation(.easeInOut(duration: 0.4), value: fraction)
                SweepHighlight()
                VStack(spacing: 2) {
                    Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit()).contentTransition(.numericText())
                    Text("\(done) of \(total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 150)
            CurrentItemLine(item: current)
                .frame(height: 44)
            ShimmerBar(fraction: fraction).frame(width: 360, height: 8)
            RecentFeed(items: recent, freedSoFar: freedSoFar)
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
    }
}

/// Icons for the groups being cleaned; the active one is lifted and tinted, all of them bob gently.
struct GroupIconRow: View {
    let groups: [String]
    let activeGroup: String?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 14) {
                ForEach(Array(groups.prefix(9).enumerated()), id: \.offset) { index, group in
                    let active = group == activeGroup
                    Image(systemName: CleanupSymbols.symbol(for: group))
                        .font(.system(size: active ? 22 : 17, weight: .medium))
                        .foregroundStyle(active ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accentSecondary], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.secondary.opacity(0.7)))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(active ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.05)))
                        .offset(y: CGFloat(sin(t * 1.6 + Double(index) * 0.9)) * (active ? 5 : 2.5))
                        .scaleEffect(active ? 1.12 : 1)
                        .symbolEffect(.pulse, options: .repeating, isActive: active)
                        .help(group)
                        .animation(.spring(duration: 0.4), value: activeGroup)
                }
            }
        }
    }
}

/// A short bright arc that travels around the ring, so even a long single item looks alive.
struct SweepHighlight: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.12)
                .stroke(AngularGradient(colors: [.white.opacity(0), .white.opacity(0.75), .white.opacity(0)], center: .center), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees((t * 120).truncatingRemainder(dividingBy: 360) - 90))
                .blendMode(.plusLighter)
        }
    }
}

/// The item currently being removed, sliding in from below as it changes.
struct CurrentItemLine: View {
    let item: ScanItem?

    var body: some View {
        ZStack {
            if let item {
                HStack(spacing: 10) {
                    if item.kind == .registration {
                        Image(systemName: CleanupSymbols.symbol(for: item.group)).foregroundStyle(Theme.accent).frame(width: 24)
                    } else {
                        FileIcon(url: item.url, size: 24)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).lineLimit(1)
                        Text(item.group + (item.size > 0 ? " · \(item.size.formattedBytes)" : "")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    ProgressView().controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                .frame(width: 360)
                .id(item.id)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
            } else {
                Text("Preparing…").font(.callout).foregroundStyle(.secondary).transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.35), value: item?.id)
    }
}

/// Modern capsule bar: gradient fill plus a moving shimmer stripe.
struct ShimmerBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accentSecondary], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, geo.size.width * fraction))
                    .animation(.easeInOut(duration: 0.4), value: fraction)
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let x = CGFloat((t * 0.45).truncatingRemainder(dividingBy: 1)) * (geo.size.width + 80) - 40
                    Capsule()
                        .fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 60)
                        .offset(x: x)
                        .blendMode(.plusLighter)
                }
                .mask(Capsule().frame(width: max(8, geo.size.width * fraction)).frame(maxWidth: .infinity, alignment: .leading))
            }
        }
    }
}

/// The last few removed items, fading out as new ones arrive, plus the running total.
struct RecentFeed: View {
    let items: [ScanItem]
    let freedSoFar: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Removed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(freedSoFar.formattedBytes) freed so far").font(.caption.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).font(.caption)
                    Text(item.title).font(.caption).lineLimit(1)
                    Spacer()
                    Text(item.size.formattedBytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .opacity(1 - Double(index) * 0.15)
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
        .frame(width: 360)
        .animation(.spring(duration: 0.4), value: items.map(\.id))
    }
}

/// SF Symbols for the groups a removal can touch.
enum CleanupSymbols {
    static func symbol(for group: String) -> String {
        let g = group.lowercased()
        if g.contains("cache") { return "externaldrive" }
        if g.contains("log") { return "doc.text" }
        if g.contains("trash") || g.contains("bin") { return "trash" }
        if g.contains("preference") { return "gearshape" }
        if g.contains("container") { return "shippingbox" }
        if g.contains("executable") || g.contains("app") { return "app" }
        if g.contains("login") || g.contains("startup") { return "paperplane" }
        if g.contains("permission") { return "lock.shield" }
        if g.contains("keychain") { return "key" }
        if g.contains("launch services") { return "link" }
        if g.contains("dock") { return "dock.rectangle" }
        if g.contains("notification") { return "bell" }
        if g.contains("receipt") { return "doc.badge.gearshape" }
        if g.contains("temporary") { return "clock" }
        if g.contains("crash") { return "exclamationmark.triangle" }
        if g.contains("web") { return "globe" }
        if g.contains("cloud") { return "icloud" }
        if g.contains("dotfile") || g.contains("cli") || g.contains("shell") { return "terminal" }
        if g.contains("purgeable") || g.contains("snapshot") { return "square.stack.3d.up.slash" }
        if g.contains("junk") { return "externaldrive.badge.xmark" }
        if g.contains("screenshot") { return "camera.viewfinder" }
        if g.contains("download") { return "arrow.down.circle" }
        if g.contains("installation") { return "shippingbox" }
        if g.contains("language") { return "character.book.closed" }
        if g.contains("xcode") || g.contains("derived") { return "hammer" }
        if g.contains("mail") { return "paperclip" }
        if g.contains("duplicate") { return "doc.on.doc" }
        if g.contains("extension") || g.contains("plug") { return "puzzlepiece.extension" }
        if g.contains("user data") || g.contains("document") { return "doc" }
        if g.contains("saved state") { return "rectangle.on.rectangle" }
        return "sparkles"
    }
}
