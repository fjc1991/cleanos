import SwiftUI

/// Temporary stand-in for sections whose scanners are built in later phases.
/// Shows the planned categories so the navigation and layout can be reviewed now.
struct PlaceholderSectionView: View {
    let section: AppSection
    @State private var checked: Set<String> = []
    @State private var selected: String?

    private var categories: [(String, String)] {
        switch section {
        case .cleanUp: [("Caches", "externaldrive"), ("Downloads", "arrow.down.circle"), ("Installation files", "shippingbox"),
                        ("Screenshot files", "camera.viewfinder"), ("Language files", "character.book.closed"), ("Xcode junk", "hammer"),
                        ("Bin", "trash"), ("Mail attachments", "paperclip"), ("Purgeable space", "square.stack.3d.up.slash"),
                        ("External disk junk", "externaldrive.badge.xmark")]
        case .speedUp: [("Startup apps", "paperplane"), ("Heavy applications", "memorychip"), ("Optimize RAM", "cpu"),
                        ("Reindex Spotlight", "magnifyingglass"), ("Reindex Mail", "envelope"), ("Browser extensions", "puzzlepiece"),
                        ("Internet plugins", "network")]
        case .manageFiles: [("Archives", "archivebox"), ("Documents", "doc.text"), ("Movie files", "film"), ("Music files", "music.note"),
                            ("Pictures", "photo"), ("System files", "gearshape"), ("Home folder", "house")]
        case .applications: [("Apps", "app"), ("Remains", "doc.badge.clock")]
        case .startup: [("User Login Items", "person"), ("Application Login Items", "app.badge"), ("Launch Agents", "clock.arrow.circlepath"), ("System Daemons", "gearshape.2")]
        case .extensions: [("Installation Files", "shippingbox"), ("Web Browser Extensions", "safari"), ("Screen Savers", "display"),
                           ("Settings Panes", "slider.horizontal.3"), ("Internet Plugins", "network"), ("Widgets", "square.grid.2x2"),
                           ("Audio & Video Plug-ins", "waveform"), ("Default Applications", "checkmark.rectangle")]
        case .updates: [("Applications", "app.badge.checkmark"), ("Command-line tools", "terminal")]
        case .duplicates: [("Duplicate groups", "doc.on.doc")]
        case .biggestFiles: [("Files over 50 MB", "externaldrive.fill.badge.exclamationmark")]
        case .overview: []
        }
    }

    var body: some View {
        SectionLayout(section: section) {
            EmptyView()
        } primary: {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(categories, id: \.0) { category in
                        CategoryRow(title: category.0, systemImage: category.1,
                                    isChecked: Binding(get: { checked.contains(category.0) },
                                                       set: { if $0 { checked.insert(category.0) } else { checked.remove(category.0) } }),
                                    isSelected: selected == category.0)
                            .onTapGesture { selected = category.0 }
                    }
                }
                .padding(8)
            }
        } detail: {
            if let selected {
                ContentUnavailableView("\(selected) scanner is coming in a later phase", systemImage: "hourglass")
            } else {
                EmptyDetailView()
            }
        } footer: {
            Button(section.actionTitle) { }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(checked.isEmpty)
        }
    }
}
