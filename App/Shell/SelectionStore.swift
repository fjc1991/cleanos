import SwiftUI
import CleanCore

enum SelectionState { case none, partial, all }

/// Tri-state selection over `ScanItem` trees. Only leaf ids are stored; group state is derived.
@MainActor
@Observable
final class SelectionStore {
    private(set) var selectedLeafIDs: Set<String> = []

    func state(of item: ScanItem) -> SelectionState {
        let leaves = item.leaves.filter { $0.tier.isSelectable }
        guard !leaves.isEmpty else { return .none }
        let count = leaves.filter { selectedLeafIDs.contains($0.id) }.count
        if count == 0 { return .none }
        return count == leaves.count ? .all : .partial
    }

    func isSelected(_ item: ScanItem) -> Bool { state(of: item) == .all }

    func set(_ item: ScanItem, selected: Bool) {
        for leaf in item.leaves where leaf.tier.isSelectable {
            if selected { selectedLeafIDs.insert(leaf.id) } else { selectedLeafIDs.remove(leaf.id) }
        }
    }

    func toggle(_ item: ScanItem) {
        set(item, selected: state(of: item) != .all)
    }

    func selectDefaults(in items: [ScanItem], allowRoot: Bool) {
        for leaf in items.flatMap(\.leaves) where leaf.tier.isSelectableByDefault && (allowRoot || !leaf.needsRoot) {
            selectedLeafIDs.insert(leaf.id)
        }
    }

    func deselect(ids: Set<String>) { selectedLeafIDs.subtract(ids) }

    func deselect(in items: [ScanItem]) {
        for leaf in items.flatMap(\.leaves) { selectedLeafIDs.remove(leaf.id) }
    }

    func selectedLeaves(in items: [ScanItem]) -> [ScanItem] {
        items.flatMap(\.leaves).filter { selectedLeafIDs.contains($0.id) }
    }

    func selectedSize(in items: [ScanItem]) -> Int64 {
        selectedLeaves(in: items).reduce(0) { $0 + $1.size }
    }

    func clear() { selectedLeafIDs.removeAll() }
}

/// A checkbox that can show the partial state of a group.
struct TriStateCheckbox: View {
    let state: SelectionState
    var isEnabled = true
    /// What the box selects, for VoiceOver ("Clean Caches"); the state is read as its value.
    var title: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(state == .none ? Color.secondary : Theme.accent)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(title ?? "Select")
        .accessibilityValue(state == .all ? "Selected" : state == .partial ? "Partially selected" : "Not selected")
    }

    private var symbol: String {
        switch state {
        case .none: "square"
        case .partial: "minus.square.fill"
        case .all: "checkmark.square.fill"
        }
    }
}

extension ScanItem {
    /// `OutlineGroup` needs optional children.
    var outlineChildren: [ScanItem]? { children.isEmpty ? nil : children }
}

/// Small coloured badge for a risk tier.
struct TierBadge: View {
    let tier: RiskTier
    var body: some View {
        Text(tier.title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
            .help(helpText)
    }
    private var helpText: String {
        switch tier {
        case .safe: "Safe: regenerable data such as caches, logs and saved state. Selected by default."
        case .normal: "Normal: settings and app data that only matter while the app is installed. Selected by default."
        case .caution: "Caution: your own files, shared folders, keychain items or iCloud data. Review before selecting."
        case .protected: "Protected: system locations and Skip List items. Shown for transparency, never removed."
        }
    }
    private var color: Color {
        switch tier {
        case .safe: Theme.success
        case .normal: Theme.accent
        case .caution: Theme.warning
        case .protected: Theme.danger
        }
    }
}

/// Icon for a file or app, from the workspace.
struct FileIcon: View {
    let url: URL?
    var size: CGFloat = 18
    var body: some View {
        if let url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "doc").frame(width: size, height: size)
        }
    }
}
