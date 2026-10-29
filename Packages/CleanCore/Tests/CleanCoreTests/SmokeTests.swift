import Foundation
import Testing
@testable import CleanCore

/// Runs the real catalog + deep dive on this Mac. Enabled only with `CLEANOS_SMOKE=1` because it reads the whole disk.
@Suite struct SmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLEANOS_SMOKE"] == "1"))
    func deepDiveRealApps() async throws {
        let catalog = AppCatalog()
        let apps = await catalog.scan(locations: [URL(filePath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")])
        print("SMOKE: \(apps.count) apps")
        let wanted = ProcessInfo.processInfo.environment["CLEANOS_SMOKE_APPS"]?.split(separator: ",").map(String.init) ?? ["zoom.us", "Dropbox", "Claude", "Microsoft Teams"]
        let locator = LeftoverLocator()
        for name in wanted {
            guard let app = apps.first(where: { $0.name == name || $0.url.lastPathComponent == name + ".app" }) else { print("SMOKE: \(name) not installed"); continue }
            let result = await locator.locate(app: app, otherApps: apps)
            print("SMOKE: === \(app.name) (\(app.bundleID)) team=\(app.teamID ?? "-") dev=\(app.developerName ?? "-") notarized=\(String(describing: app.identity.isNotarized)) subBundles=\(app.identity.subBundleIDs.count) groups=\(app.identity.groupIDs) labels=\(app.identity.launchdLabels.sorted())")
            print("SMOKE: \(result.itemCount) items, \(result.totalSize.formattedBytes), \(String(format: "%.2f", result.duration))s")
            for group in result.groups {
                print("SMOKE:  [\(group.title)] \(group.size.formattedBytes)")
                for item in group.children {
                    print("SMOKE:     \(item.tier.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(item.size.formattedBytes.padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.url?.path ?? item.title)  <- \(item.matchedBy.joined(separator: "; "))\(item.subtitle.map { " [\($0)]" } ?? "")")
                }
            }
        }
    }
}

@Suite struct RemainsSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLEANOS_SMOKE"] == "1"))
    func remainsOnThisMac() async throws {
        let catalog = AppCatalog()
        let apps = await catalog.scan(locations: [URL(filePath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")])
        let result = await RemainsLocator(registrations: SystemRegistrationReader()).locate(installed: apps)
        print("SMOKE: remains groups=\(result.groups.count) total=\(result.totalSize.formattedBytes) in \(String(format: "%.2f", result.duration))s")
        for group in result.groups.prefix(40) {
            print("SMOKE: [\(group.title)] \(group.size.formattedBytes) · \(group.subtitle ?? "")")
            for item in group.children.prefix(12) {
                print("SMOKE:     \(item.tier.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(item.url?.path ?? item.title)  <- \(item.matchedBy.joined(separator: "; "))\(item.subtitle.map { " [\($0)]" } ?? "")")
            }
        }
        if let zoom = apps.first(where: { $0.bundleID == "us.zoom.xos" }) {
            print("SMOKE: zoom subBundles contain ZoomClips=\(zoom.identity.subBundleIDs.contains("us.zoom.ZoomClips")) total=\(zoom.identity.subBundleIDs.count) sample=\(zoom.identity.subBundleIDs.sorted().prefix(12))")
        }
        let registrations = RegistrationScanner().scan(identity: apps.first { $0.bundleID == "us.zoom.xos" }!.identity, appPath: "/Applications/zoom.us.app", shared: Rules.bundled.shared)
        print("SMOKE: zoom registrations=\(registrations.count)")
        for item in registrations { print("SMOKE:     [\(item.group)] \(item.title) — \(item.subtitle ?? "") (\(item.tier.rawValue))") }
    }
}

@Suite struct CleanupSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLEANOS_SMOKE"] == "1"))
    func everyCategoryOnThisMac() async throws {
        let volumes = VolumeCatalog.mountedVolumes()
        let apps = await AppCatalog().scan(locations: [URL(filePath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")])
        let context = CleanupContext(volumes: volumes, enabledVolumeIDs: Set(volumes.map(\.id)), installedApps: apps, runningBundleIDs: [], rules: .bundled)
        print("SMOKE: volumes=\(volumes.map(\.name)) apps=\(apps.count) FDA=\(FullDiskAccess.status())")
        let engine = CleanupEngine()
        for category in CleanupEngine.categories {
            let start = Date()
            let result = await engine.scan(categoryID: category.id, context: context)
            let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
            guard let result else { print("SMOKE: \(category.id): NO RESULT"); continue }
            let leaves = result.items.flatMap(\.leaves)
            print("SMOKE: \(category.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \(seconds)s groups=\(result.items.count) leaves=\(leaves.count) total=\(result.totalSize.formattedBytes) selectableByDefault=\(leaves.filter { $0.tier.isSelectableByDefault }.count)")
            for item in result.items.prefix(6) {
                print("SMOKE:     [\(item.tier.rawValue)] \(item.title) \(item.size.formattedBytes) children=\(item.children.count) \(item.subtitle ?? "")")
            }
        }
    }
}
