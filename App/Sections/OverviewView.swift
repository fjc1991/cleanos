import SwiftUI
import CleanCore

/// Dashboard: one capacity bar per volume, junk/memory headline and the one-button clean-up.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedVolumeID: String?
    @State private var removalFlow: RemovalFlow?

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(section: .overview) {
                if model.cleanUp.isScanning { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scanning…").font(.callout).foregroundStyle(.secondary) } }
            }
            ScrollView {
                VStack(spacing: 14) {
                    FastCleanupCard()
                    if model.support.isPromptVisible { SupportBanner() }
                    ForEach(model.volumes) { volume in
                        VolumeCard(volume: volume, isSelected: volume.id == (selectedVolumeID ?? model.bootVolume?.id))
                            .onTapGesture { selectedVolumeID = volume.id }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            BottomBar {
                let items = model.cleanUp.selectedItems
                if !items.isEmpty {
                    Text("\(countText(items.count, "item")) · \(model.cleanUp.selectedSize.formattedBytes)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).padding(.trailing, 8)
                }
                Button(AppSection.overview.actionTitle) {
                    removalFlow = RemovalFlow(title: "Clean Up", apps: [], items: items)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(items.isEmpty)
            }
        }
        .task { model.cleanUp.appProvider = { await model.installedApps() }; await model.cleanUp.scanAll(volumes: model.volumes) }
        .onChange(of: model.rescanToken) { _, _ in Task { await model.cleanUp.scanAll(volumes: model.volumes, force: true) } }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in model.refreshMemory() }
        .sheet(item: $removalFlow) { flow in
            RemovalSheet(flow: flow) { result in model.cleanUp.finishedRemoval(result, volumes: model.volumes) }
                .environment(model)
        }
    }
}

struct VolumeCard: View {
    let volume: VolumeInfo
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: volume.isRoot ? "internaldrive.fill" : (volume.isLocal ? "externaldrive.fill" : "network"))
                    .foregroundStyle(Theme.accent)
                Text(volume.name).font(.headline)
                Text(volume.format).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(volume.availableCapacity.formattedBytes) available of \(volume.totalCapacity.formattedBytes)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            CapacityBar(segments: [
                (label: "Used", bytes: volume.usedCapacity - volume.purgeableCapacity, color: Theme.categoryPalette[0]),
                (label: "Purgeable", bytes: volume.purgeableCapacity, color: Theme.categoryPalette[2]),
            ], total: volume.totalCapacity)
            HStack(spacing: 18) {
                LegendDot(color: Theme.categoryPalette[0], label: "Used", value: (volume.usedCapacity - volume.purgeableCapacity).formattedBytes)
                LegendDot(color: Theme.categoryPalette[2], label: "Purgeable", value: volume.purgeableCapacity.formattedBytes)
                Spacer()
            }
        }
        .padding(16)
        .card()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5)
        )
    }
}

struct CapacityBar: View {
    let segments: [(label: String, bytes: Int64, color: Color)]
    let total: Int64

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    let fraction = total > 0 ? Double(max(0, segment.bytes)) / Double(total) : 0
                    if fraction > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(segment.color)
                            .frame(width: max(3, geo.size.width * fraction))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption)
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct FastCleanupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Text("Fast Cleanup Mode").font(.headline)
            HStack(spacing: 48) {
                VStack(spacing: 4) {
                    Text("Junk Files").font(.caption).foregroundStyle(.secondary)
                    if model.cleanUp.results.isEmpty && model.cleanUp.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(model.cleanUp.junkTotal.formattedBytes).font(.title.weight(.semibold).monospacedDigit())
                    }
                }
                VStack(spacing: 4) {
                    Text("Memory Usage").font(.caption).foregroundStyle(.secondary)
                    Text(model.memory.map { "\(Int(($0.usedFraction * 100).rounded()))%" } ?? "–").font(.title.weight(.semibold).monospacedDigit())
                    if let memory = model.memory {
                        Text("\(memory.used.formattedBytes) of \(memory.total.formattedBytes)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            if !model.cleanUp.results.isEmpty {
                HStack(spacing: 14) {
                    ForEach(model.cleanUp.categories.filter { (model.cleanUp.results[$0.id]?.totalSize ?? 0) > 0 }) { category in
                        let index = model.cleanUp.categories.firstIndex(where: { $0.id == category.id }) ?? 0
                        LegendDot(color: Theme.categoryPalette[index % Theme.categoryPalette.count], label: category.title,
                                  value: model.cleanUp.results[category.id]?.totalSize.formattedBytes ?? "")
                    }
                }
                .font(.caption)
            }
            Text("Caches, logs, the Trash and other files apps recreate are pre-selected. Installers, screenshots and anything marked Caution are listed but left for you to choose.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .card()
    }
}
