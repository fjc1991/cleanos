import SwiftUI

/// Sidebar entries. Merges MacCleaner Pro's sections with App Cleaner's tabs.
enum AppSection: String, CaseIterable, Identifiable, Codable {
    case overview, cleanUp, speedUp, manageFiles
    case applications, startup, extensions, updates
    case duplicates, biggestFiles

    var id: String { rawValue }

    enum Group: String, CaseIterable { case main = "", apps = "Apps", tools = "Tools" }

    var group: Group {
        switch self {
        case .overview, .cleanUp, .speedUp, .manageFiles: .main
        case .applications, .startup, .extensions, .updates: .apps
        case .duplicates, .biggestFiles: .tools
        }
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .cleanUp: "Clean Up"
        case .speedUp: "Speed Up"
        case .manageFiles: "Manage Files"
        case .applications: "Applications"
        case .startup: "Startup Programs"
        case .extensions: "Extensions"
        case .updates: "Updates"
        case .duplicates: "Duplicates"
        case .biggestFiles: "Biggest Files"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "See what is taking up space and clean it in one pass"
        case .cleanUp: "Delete temporary files created by applications or downloaded from the Internet"
        case .speedUp: "Manage programs to optimize your Mac's performance"
        case .manageFiles: "View the items that occupy significant disk space and delete unneeded ones"
        case .applications: "Completely uninstall apps with all their leftovers"
        case .startup: "Programs and processes that automatically run when you log in to your Mac"
        case .extensions: "Programs that add functionality or customize experience with browsers, apps and system processes"
        case .updates: "Update your applications to keep them running smoothly"
        case .duplicates: "Free up space by deleting duplicate files"
        case .biggestFiles: "Review and remove unneeded biggest files"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .cleanUp: "sparkles"
        case .speedUp: "bolt.fill"
        case .manageFiles: "folder.fill"
        case .applications: "app.badge.checkmark"
        case .startup: "paperplane.fill"
        case .extensions: "puzzlepiece.extension.fill"
        case .updates: "arrow.triangle.2.circlepath"
        case .duplicates: "doc.on.doc.fill"
        case .biggestFiles: "externaldrive.fill.badge.exclamationmark"
        }
    }

    /// Title of the bottom-bar action button.
    var actionTitle: String {
        switch self {
        case .overview: "Review and Clean Up"
        case .cleanUp: "Review to Clean Up"
        case .speedUp: "Review to Speed Up"
        case .applications: "Uninstall"
        case .startup: "Disable"
        case .updates: "Update"
        default: "Review to Remove"
        }
    }
}
