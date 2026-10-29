import Foundation
import Combine
import Sparkle

/// Owns the Sparkle updater that keeps CleanOS itself up to date. (The Updates section checks *other* apps.)
///
/// The feed (`SUFeedURL`) is the `appcast.xml` attached to the latest GitHub release; `Scripts/release.sh`
/// writes and signs it. Sparkle checks once a day, shows the standard "A new version is available" window
/// and, when automatic installation is on, downloads in the background and asks before installing.
@MainActor
@Observable
final class UpdaterService {
    private let controller: SPUStandardUpdaterController
    private var subscriptions: Set<AnyCancellable> = []

    /// False while a check or an install is already running (drives the menu item and buttons).
    private(set) var canCheckForUpdates = false
    private(set) var lastCheckDate: Date?
    /// Set when Sparkle refused to start (for example a build without a valid `SUPublicEDKey`).
    private(set) var startupError: String?

    var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    var automaticallyDownloadsUpdates: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    var feedURL: URL? { controller.updater.feedURL }
    var isRunning: Bool { startupError == nil }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = value
                    self?.lastCheckDate = self?.controller.updater.lastUpdateCheckDate
                }
            }
            .store(in: &subscriptions)

        do {
            try updater.start()
            lastCheckDate = updater.lastUpdateCheckDate
            Diagnostics.log("updater started; feed = \(updater.feedURL?.absoluteString ?? "none")")
        } catch {
            startupError = error.localizedDescription
            Diagnostics.log("updater failed to start: \(error)")
        }
    }

    /// User-initiated check: shows progress and "You're up to date" as well as available updates.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
