import AppKit
import Foundation

/// Project links configured in `project.yml` (`CLEANOS_GITHUB_REPO`, `CLEANOS_KOFI_NAME`) and read from Info.plist.
/// A value that still holds the `YOUR-…` placeholder counts as not configured, so dev builds never show a dead link.
enum AppLinks {
    static let repository = url(forInfoKey: "CleanOSRepositoryURL")
    static let support = url(forInfoKey: "CleanOSSupportURL")
    static var issues: URL? { repository?.appending(path: "issues") }
    static var releases: URL? { repository?.appending(path: "releases") }

    private static func url(forInfoKey key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !raw.contains("YOUR-"), let url = URL(string: raw), url.host() != nil else { return nil }
        return url
    }
}

/// Counts app launches ("sessions") and decides when to show the Ko-fi tip nudge.
///
/// Rules: nothing before the sixth launch; never when the support link is not configured; "Maybe later" hides it
/// for 30 days; "Don't ask again" or visiting the tip page hides it for good. The link stays in Help and Settings → About.
@MainActor
@Observable
final class SupportPromptModel {
    static let sessionsBeforePrompt = 5
    static let snoozeInterval: TimeInterval = 30 * 24 * 60 * 60

    private let defaults: UserDefaults
    private(set) var isPromptVisible = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var sessionCount: Int { defaults.integer(forKey: SettingsKey.sessionCount) }
    var isConfigured: Bool { AppLinks.support != nil }

    /// Call exactly once per launch.
    func recordLaunch() {
        defaults.set(sessionCount + 1, forKey: SettingsKey.sessionCount)
        isPromptVisible = shouldPrompt
        if isPromptVisible { Diagnostics.log("support prompt shown (session \(sessionCount))") }
    }

    var shouldPrompt: Bool {
        guard isConfigured, sessionCount > Self.sessionsBeforePrompt else { return false }
        guard !defaults.bool(forKey: SettingsKey.supportPromptDisabled) else { return false }
        if let last = defaults.object(forKey: SettingsKey.supportPromptLastShown) as? Date,
           Date().timeIntervalSince(last) < Self.snoozeInterval { return false }
        return true
    }

    /// Opens the Ko-fi page. Whoever got this far is not nagged again; the link stays available in Help and Settings.
    func openSupportPage() {
        guard let url = AppLinks.support else { return }
        NSWorkspace.shared.open(url)
        defaults.set(true, forKey: SettingsKey.supportPromptDisabled)
        isPromptVisible = false
    }

    func remindLater() {
        defaults.set(Date(), forKey: SettingsKey.supportPromptLastShown)
        isPromptVisible = false
    }

    func dontAskAgain() {
        defaults.set(true, forKey: SettingsKey.supportPromptDisabled)
        isPromptVisible = false
    }

    /// Re-enables the nudge (Settings → About).
    func reset() {
        defaults.removeObject(forKey: SettingsKey.supportPromptDisabled)
        defaults.removeObject(forKey: SettingsKey.supportPromptLastShown)
        isPromptVisible = shouldPrompt
    }
}
