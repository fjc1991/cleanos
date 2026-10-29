import SwiftUI

/// The three-pane layout every section uses: header, a category/list column, a detail pane and a bottom bar.
struct SectionLayout<Header: View, Primary: View, Detail: View, Footer: View>: View {
    let section: AppSection
    @ViewBuilder var header: Header
    @ViewBuilder var primary: Primary
    @ViewBuilder var detail: Detail
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(section: section) { header }
            HStack(spacing: 16) {
                primary
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 420, maxHeight: .infinity)
                    .card()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .card()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            BottomBar { footer }
        }
    }
}

struct SectionHeader<Trailing: View>: View {
    let section: AppSection
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: section.systemImage)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.accentSecondary], startPoint: .top, endPoint: .bottom))
                .frame(width: 48, height: 48)
                .card()
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title).font(.title2.weight(.semibold))
                Text(section.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }
}

struct BottomBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack {
            Spacer()
            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

/// "Select a category to preview content" — the empty state of a detail pane.
struct EmptyDetailView: View {
    var title: String = "Select a category to preview content"
    var systemImage: String = "sidebar.left"
    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .foregroundStyle(.secondary)
    }
}

/// A category row with checkbox, icon, title and trailing size, as in Clean Up / Speed Up / Manage Files.
struct CategoryRow: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String
    var sizeText: String = "–"
    @Binding var isChecked: Bool
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isChecked).toggleStyle(.checkbox).labelsHidden()
            Image(systemName: systemImage)
                .frame(width: 22)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(sizeText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.18) : .clear)
        )
        .contentShape(Rectangle())
    }
}
