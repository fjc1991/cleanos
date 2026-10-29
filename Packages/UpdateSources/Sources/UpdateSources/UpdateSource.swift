import Foundation

/// Where an update was discovered.
public enum UpdateOrigin: String, Codable, Sendable, CaseIterable {
    case sparkle, homebrewCask, homebrewFormula, appStore
    public var title: String {
        switch self {
        case .sparkle: "Sparkle"
        case .homebrewCask: "Homebrew"
        case .homebrewFormula: "Command-line tools"
        case .appStore: "App Store"
        }
    }
}

/// One available update for an installed app or command-line tool.
public struct AvailableUpdate: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(origin.rawValue):\(identifier)" }
    public let identifier: String           // bundle ID, cask token or formula name
    public let displayName: String
    public let installedVersion: String
    public let latestVersion: String
    public let origin: UpdateOrigin
    public let appURL: URL?
    public let downloadURL: URL?
    public let releaseNotesURL: URL?
    public let checkedAt: Date

    public init(identifier: String, displayName: String, installedVersion: String, latestVersion: String,
                origin: UpdateOrigin, appURL: URL? = nil, downloadURL: URL? = nil,
                releaseNotesURL: URL? = nil, checkedAt: Date = .now) {
        self.identifier = identifier
        self.displayName = displayName
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.origin = origin
        self.appURL = appURL
        self.downloadURL = downloadURL
        self.releaseNotesURL = releaseNotesURL
        self.checkedAt = checkedAt
    }
}

/// A source that can check a set of installed apps for newer versions.
public protocol UpdateSource: Sendable {
    var origin: UpdateOrigin { get }
    func checkForUpdates() async throws -> [AvailableUpdate]
}
