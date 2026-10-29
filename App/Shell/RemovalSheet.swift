import SwiftUI
import CleanCore
import UserNotifications

/// Everything a removal needs: what to remove and how to quit the affected apps first.
struct RemovalFlow: Identifiable {
    let id = UUID()
    let title: String
    let apps: [InstalledApp]
    let items: [ScanItem]
    let quit: @MainActor () async -> Bool

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

    enum Phase { case review, running(done: Int, total: Int, current: ScanItem?), finished(RemovalResult) }
    @State private var phase: Phase = .review
    @State private var permanently = AppSettings.removesPermanently
    @State private var recent: [ScanItem] = []
    @State private var freedSoFar: Int64 = 0
    @State private var excluded: Set<String> = []

    private var includedItems: [ScanItem] { flow.items.filter { !excluded.contains($0.id) } }
    private var includedSize: Int64 { includedItems.reduce(0) { $0 + $1.size } }
    private var isRunning: Bool { if case .running = phase { return true } else { return false } }
    private var runningApps: [InstalledApp] { flow.apps.filter { !ProcessMonitor.processes(inBundle: $0.url.standardizedFileURL.path).isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .review: review
            case .running(let done, let total, let current):
                CleanupProgressView(title: flow.title, done: done, total: total, current: current, recent: recent, freedSoFar: freedSoFar,
                                    groups: Array(NSOrderedSet(array: includedItems.map(\.group))) as? [String] ?? [])
            case .finished(let result): finished(result)
            }
        }
        .frame(width: 640, height: 560)
        .interactiveDismissDisabled(isRunning)
    }

    // MARK: Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summaryTitle).font(.title3.weight(.semibold))
            Text(permanently ? "Items will be deleted permanently and cannot be restored."
                             : "Items will be moved to the Trash and can be restored from History.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(Dictionary(grouping: flow.items, by: \.group).keys.sorted { LeftoverGroups.rank($0) < LeftoverGroups.rank($1) }, id: \.self) { group in
                    Section(group) {
                        ForEach(flow.items.filter { $0.group == group }) { item in
                            HStack {
                                TriStateCheckbox(state: excluded.contains(item.id) ? .none : .all) {
                                    if excluded.contains(item.id) { excluded.remove(item.id) } else { excluded.insert(item.id) }
                                }
                                if item.kind == .registration { Image(systemName: CleanupSymbols.symbol(for: item.group)).foregroundStyle(Theme.accent) } else { FileIcon(url: item.url) }
                                VStack(alignment: .leading) {
                                    Text(item.title).lineLimit(1)
                                    Text(item.subtitle ?? item.url?.path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                if item.needsRoot { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
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
                let processCount = runningApps.reduce(0) { $0 + ProcessMonitor.processes(inBundle: $1.url.standardizedFileURL.path).count }
                Label("\(runningApps.map(\.name).joined(separator: ", ")) \(runningApps.count == 1 ? "has" : "have") \(processCount) running process\(processCount == 1 ? "" : "es") (app, helpers, background agents); they will be quit, force-stopped if needed.", systemImage: "power")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if flow.items.contains(where: { $0.tier == .caution }) {
                Label("Some items are marked Caution: they may hold your own data or be shared with other apps.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Theme.warning)
            }
            if flow.items.contains(where: \.needsRoot) {
                HStack {
                    Label(appModel.helper.isAvailable ? "Items with a lock are removed by the CleanOS helper with administrator privileges."
                                                      : "Items with a lock need administrator privileges, or they will be skipped.",
                          systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(.secondary)
                    if !appModel.helper.isAvailable {
                        Button("Enable Helper…") { appModel.helper.register() }.controlSize(.small)
                    }
                }
            }
            HStack {
                Toggle("Delete permanently", isOn: $permanently).toggleStyle(.checkbox)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(flow.title.hasPrefix("Reset") ? "Reset" : (excluded.isEmpty ? "Remove" : "Remove \(includedItems.count)")) { Task { await run() } }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(includedItems.isEmpty)
            }
        }
        .padding(20)
    }

    private var summaryTitle: String {
        let apps = includedItems.filter { $0.kind == .bundle }.count
        let items = includedItems.filter { $0.kind != .bundle }.count
        switch (apps, items) {
        case (0, _): return "\(items) Item\(items == 1 ? "" : "s") Cleanup · \(includedSize.formattedBytes)"
        case (_, 0): return "\(apps) Application\(apps == 1 ? "" : "s") Uninstalling · \(includedSize.formattedBytes)"
        default: return "\(apps) Application\(apps == 1 ? "" : "s") Uninstalling, \(items) Item\(items == 1 ? "" : "s") Cleanup · \(includedSize.formattedBytes)"
        }
    }

    // MARK: Running

    private func run() async {
        let plan = RemovalPlan(selected: includedItems, permanently: permanently)
        phase = .running(done: 0, total: plan.count, current: nil)
        let quitOK = await flow.quit()
        if !quitOK {
            var result = RemovalResult()
            for item in includedItems { result.failed.append((item, "The application is still running.")) }
            phase = .finished(result)
            return
        }
        let executor = RemovalExecutor(journal: appModel.journal,
                                       rootRemover: appModel.helper.isAvailable ? appModel.helper.rootRemover() : nil,
                                       registrationRemover: RegistrationRemover(runAsRoot: appModel.helper.isAvailable ? appModel.helper.rootRunner() : nil))
        let result = await executor.execute(plan, title: flow.title, appVersion: AppModel.appVersion) { done, total, current in
            Task { @MainActor in
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
        content.body = "\(result.succeeded.count) item\(result.succeeded.count == 1 ? "" : "s") removed, \(result.freedBytes.formattedBytes) freed" + (result.failed.isEmpty ? "." : "; \(result.failed.count) skipped.")
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Finished

    private func finished(_ result: RemovalResult) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: result.failed.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(LinearGradient(colors: [Theme.success, Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                .symbolEffect(.bounce, value: result.succeeded.count)
                .transition(.scale.combined(with: .opacity))
            Text(result.isDryRun ? "Dry run complete" : "You just successfully removed \(result.succeeded.count) item\(result.succeeded.count == 1 ? "" : "s")")
                .font(.title3.weight(.semibold))
            Text("\(result.freedBytes.formattedBytes) of space freed").font(.title3.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
            if result.isDryRun {
                Text("CLEANOS_DRY_RUN is set, so nothing was touched.").font(.caption).foregroundStyle(.secondary)
            }
            if !result.failed.isEmpty {
                List(result.failed, id: \.item.id) { failure in
                    VStack(alignment: .leading) {
                        Text(failure.item.title)
                        Text(failure.error).font(.caption).foregroundStyle(Theme.danger)
                    }
                }
                .frame(maxHeight: 180)
            }
            Spacer()
            HStack {
                if !result.isDryRun, result.succeeded.contains(where: { $0.kind != .registration }) {
                    Button("Show in Trash") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")) }
                    Button("History…") { dismiss(); appModel.showHistory = true }
                }
                Button("Done") { dismiss() }.buttonStyle(PrimaryActionButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
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
