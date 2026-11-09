import SwiftUI
import CleanCore

/// Generic tree of scan groups and leaves with tri-state selection, used by Clean Up, Remains and other sections.
struct ScanTreeView: View {
    let items: [ScanItem]
    let selection: SelectionStore
    @Binding var expanded: Set<String>
    var allowRoot = false

    var body: some View {
        List {
            ForEach(items) { item in
                if item.children.isEmpty {
                    ScanItemRow(item: item, selection: selection)
                } else {
                    DisclosureGroup(isExpanded: Binding(
                        get: { expanded.contains(item.id) },
                        set: { if $0 { expanded.insert(item.id) } else { expanded.remove(item.id) } }
                    )) {
                        ForEach(item.children) { child in
                            if child.children.isEmpty {
                                ScanItemRow(item: child, selection: selection)
                            } else {
                                DisclosureGroup {
                                    ForEach(child.children) { ScanItemRow(item: $0, selection: selection) }
                                } label: {
                                    GroupLabel(item: child, selection: selection)
                                }
                            }
                        }
                    } label: {
                        GroupLabel(item: item, selection: selection)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

struct GroupLabel: View {
    let item: ScanItem
    let selection: SelectionStore
    var body: some View {
        HStack(spacing: 8) {
            TriStateCheckbox(state: selection.state(of: item), isEnabled: item.leaves.contains { $0.tier.isSelectable }, title: item.title) { selection.toggle(item) }
            if let iconPath = item.payload["iconPath"] {
                FileIcon(url: URL(filePath: iconPath), size: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.callout.weight(.semibold))
                if let subtitle = item.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(item.leaves.count == 1 ? "1 item" : "\(countText(item.leaves.count, "item"))").font(.caption).foregroundStyle(.secondary)
            Text(item.size.formattedBytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
        }
    }
}

/// "Select all" header shown above a tree.
struct SelectAllHeader: View {
    let items: [ScanItem]
    let selection: SelectionStore
    var allowRoot = false

    private var state: SelectionState {
        let states = items.map { selection.state(of: $0) }
        if states.isEmpty || states.allSatisfy({ $0 == .none }) { return .none }
        if states.allSatisfy({ $0 == .all }) { return .all }
        return .partial
    }

    var body: some View {
        HStack {
            TriStateCheckbox(state: state) {
                if state == .all { selection.deselect(in: items) } else { for item in items { selection.set(item, selected: true) } }
            }
            Text("Select All").font(.callout)
            Spacer()
            Text("\(selection.selectedLeaves(in: items).count) selected · \(selection.selectedSize(in: items).formattedBytes)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}
