import Foundation
import Testing
@testable import CleanCore

struct StubReader: RegistrationReader {
    var handlers: [[String: String]] = []
    var tiles: [(index: Int, path: String)] = []
    var ncApps: [String] = []
    var tcc: [TCCRow] = []
    var keychain: [KeychainItem] = []
    var jobs: [(label: String, pid: Int?)] = []
    var firewall: [String] = []
    func launchServicesHandlers() -> [[String: String]] { handlers }
    func dockTiles() -> [(index: Int, path: String)] { tiles }
    func notificationCenterApps() -> [String] { ncApps }
    func tccRows() -> [TCCRow] { tcc }
    func keychainItems() -> [KeychainItem] { keychain }
    func launchdJobs() -> [(label: String, pid: Int?)] { jobs }
    func firewallApps() -> [String] { firewall }
}

@Suite struct RegistrationTests {
    let identity = AppIdentity(bundleID: "us.zoom.xos", name: "zoom.us", fileName: "zoom.us", executable: "zoom.us",
                               subBundleIDs: ["us.zoom.updater"], teamID: "BJ4HAAB9B3", launchdLabels: ["us.zoom.ZoomDaemon"])

    @Test func findsEveryKindOfTrace() {
        let reader = StubReader(
            handlers: [["LSHandlerURLScheme": "zoomphonecall", "LSHandlerRoleAll": "us.zoom.xos"],
                       ["LSHandlerURLScheme": "https", "LSHandlerRoleAll": "com.apple.safari"],
                       ["LSHandlerContentType": "public.zip-archive", "LSHandlerRoleViewer": "us.zoom.xos"]],
            tiles: [(0, "/Applications/zoom.us.app"), (1, "/Applications/Safari.app")],
            ncApps: ["us.zoom.xos", "com.apple.mail"],
            tcc: [TCCRow(service: "kTCCServiceCamera", client: "us.zoom.xos", allowed: true, lastModified: nil, isSystemDatabase: false),
                  TCCRow(service: "kTCCServiceScreenCapture", client: "us.zoom.xos", allowed: true, lastModified: nil, isSystemDatabase: true),
                  TCCRow(service: "kTCCServiceCamera", client: "com.apple.FaceTime", allowed: true, lastModified: nil, isSystemDatabase: false)],
            keychain: [KeychainItem(itemClass: "genp", service: "Zoom Safe Storage", account: "Zoom Key", label: "Zoom Safe Storage", accessGroup: nil, server: nil, persistentRef: Data([1])),
                       KeychainItem(itemClass: "genp", service: "us.zoom.xos.token", account: "a", label: nil, accessGroup: nil, server: nil, persistentRef: Data([2])),
                       KeychainItem(itemClass: "genp", service: "BJ4HAAB9B3.shared", account: "a", label: nil, accessGroup: "BJ4HAAB9B3.ZoomClient3rd", server: nil, persistentRef: Data([3])),
                       KeychainItem(itemClass: "inet", service: nil, account: "me", label: "github.com", accessGroup: nil, server: "api.github.com", persistentRef: Data([4]))],
            jobs: [("us.zoom.ZoomDaemon", 123), ("us.zoom.updater", nil), ("com.apple.Finder", 5)],
            firewall: ["/Applications/zoom.us.app/Contents/MacOS/zoom.us", "/usr/sbin/sshd"]
        )
        let items = RegistrationScanner(reader: reader).scan(identity: identity, appPath: "/Applications/zoom.us.app", shared: Rules.bundled.shared)
        let byGroup = Dictionary(grouping: items, by: \.group)
        #expect(byGroup[RegistrationScanner.groupLaunchServices]?.count == 2)
        #expect(byGroup[RegistrationScanner.groupDock]?.count == 1)
        #expect(byGroup[RegistrationScanner.groupNotifications]?.count == 1)
        #expect(byGroup[RegistrationScanner.groupPermissions]?.count == 2)
        #expect(byGroup[RegistrationScanner.groupPermissions]?.first { $0.title == "Screen Recording" }?.needsRoot == true)
        #expect(byGroup[RegistrationScanner.groupKeychain]?.count == 3)
        #expect(byGroup[RegistrationScanner.groupKeychain]?.allSatisfy { $0.tier == .caution } == true)
        #expect(byGroup[RegistrationScanner.groupRunningJobs]?.count == 2)
        #expect(byGroup[RegistrationScanner.groupFirewall]?.count == 1)
        #expect(items.allSatisfy { $0.kind == .registration && !$0.payload.isEmpty })
        #expect(byGroup[RegistrationScanner.groupPermissions]?.first { $0.title == "Camera" }?.payload["service"] == "Camera")
    }

    @Test func remainsLocatorFindsOrphansAndSkipsInstalled() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "RemainsHome-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        func dir(_ p: String) throws { try fm.createDirectory(at: home.appending(path: p), withIntermediateDirectories: true) }
        func file(_ p: String, _ c: String = "x") throws {
            try fm.createDirectory(at: home.appending(path: p).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(c.utf8).write(to: home.appending(path: p))
        }
        try dir("Library/Application Support/com.gone.app")
        try dir("Library/Caches/com.gone.app")
        try dir("Library/Caches/com.gone.app.helper")
        try file("Library/Preferences/com.gone.app.plist")
        try dir("Library/Containers/com.gone.app.share")
        try dir("Library/Group Containers/ZZZZZZZZZZ.com.gone.app")
        try dir("Library/Caches/com.installed.app")                 // owned by an installed app
        try dir("Library/Caches/com.installed.app.helper")
        try dir("Library/Group Containers/AAAAAAAAAA.shared")      // installed team
        try dir("Library/Caches/com.apple.something")              // Apple, protected
        try dir("Library/Caches/Some Folder")                      // not identifier-shaped
        try dir("Library/Caches/com.installed.other")              // same vendor as installed → caution, still listed
        try file("Library/LaunchAgents/com.gone.agent.plist", try LeftoverLocatorTests.plist(["Label": "com.gone.agent", "Program": "/nonexistent/binary"]))
        try file("Library/LaunchAgents/com.live.agent.plist", try LeftoverLocatorTests.plist(["Label": "com.live.agent", "Program": "/bin/ls"]))

        let installed = InstalledApp(url: home.appending(path: "Applications/Installed.app"), name: "Installed", bundleID: "com.installed.app", version: nil, build: nil,
                                     isSystem: false, modificationDate: nil, creationDate: nil, lastOpenedDate: nil,
                                     identity: AppIdentity(bundleID: "com.installed.app", name: "Installed", fileName: "Installed", teamID: "AAAAAAAAAA"))
        let locator = RemainsLocator(rules: .bundled, home: home.path)
        let result = await locator.locate(installed: [installed])
        let paths = Set(result.groups.flatMap(\.children).compactMap { $0.url?.standardizedFileURL.path })
        func has(_ p: String) -> Bool { paths.contains(home.appending(path: p).standardizedFileURL.path) }
        #expect(has("Library/Application Support/com.gone.app"))
        #expect(has("Library/Caches/com.gone.app"))
        #expect(has("Library/Caches/com.gone.app.helper"))
        #expect(has("Library/Preferences/com.gone.app.plist"))
        #expect(has("Library/Containers/com.gone.app.share"))
        #expect(has("Library/Group Containers/ZZZZZZZZZZ.com.gone.app"))
        #expect(has("Library/LaunchAgents/com.gone.agent.plist"))
        #expect(!has("Library/Caches/com.installed.app"))
        #expect(!has("Library/Caches/com.installed.app.helper"))
        #expect(!has("Library/Group Containers/AAAAAAAAAA.shared"))
        #expect(!has("Library/Caches/com.apple.something"))
        #expect(!has("Library/Caches/Some Folder"))
        #expect(!has("Library/LaunchAgents/com.live.agent.plist"))
        let sameVendor = result.groups.flatMap(\.children).first { $0.url?.lastPathComponent == "com.installed.other" }
        #expect(sameVendor?.tier == .caution)
        let gone = result.groups.first { $0.title == "gone.app" }
        #expect(gone != nil)
        #expect((gone?.children.count ?? 0) >= 6)
        let agentGroup = result.groups.first { $0.title == "com.gone.agent" || $0.title == "gone.agent" }
        #expect(agentGroup != nil)
    }
}

@Suite struct RemainsPassesTests {
    @Test func receiptTitlesAndFamilyTokens() {
        #expect(RemainsLocator.receiptTitle("com.google.pkg.ChromeRemoteDesktopHostService") == "Chrome Remote Desktop Host Service (Google)")
        #expect(RemainsLocator.receiptTitle("us.zoom.pkg.videomeeting") == "videomeeting (Zoom)")
        let families = Rules.bundled.families
        #expect(RemainsLocator.family(for: "/private/tmp/KSInstallAction.AnxY8JgJO6", in: families)?.id == "google-keystone")
        #expect(RemainsLocator.family(for: "/Users/x/Library/Application Support/CrashReporter/remoting_host_uninstaller_1.plist", in: families)?.id == "chrome-remote-desktop")
        #expect(RemainsLocator.family(for: "/private/var/folders/qc/x/C/com.google.chromeremotedesktop.me2me-host-uninstaller", in: families)?.id == "chrome-remote-desktop")
        #expect(RemainsLocator.family(for: "/Users/x/Library/Caches/com.example.other", in: families) == nil)
    }

    @Test func familyAndRegistrationOrphans() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "RemainsFamily-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        func dir(_ p: String) throws { try fm.createDirectory(at: home.appending(path: p), withIntermediateDirectories: true) }
        try dir(".zoomus")
        try dir("Library/Application Support/zoom.us")
        try dir("Library/Application Support/Chrome Remote Desktop")
        try dir("Library/Application Support/CrashReporter")
        try dir("Applications/Broken.app/Contents/MacOS")                       // no Info.plist
        try dir("Applications/Hollow.app/Contents/MacOS")
        try Data(try LeftoverLocatorTests.plist(["CFBundleIdentifier": "com.hollow.app", "CFBundleExecutable": "Hollow"]).utf8).write(to: home.appending(path: "Applications/Hollow.app/Contents/Info.plist"))
        try Data("x".utf8).write(to: home.appending(path: "Library/Application Support/CrashReporter/remoting_host_uninstaller_ABC.plist"))

        let reader = StubReader(handlers: [["LSHandlerURLScheme": "gonescheme", "LSHandlerRoleAll": "com.gone.app"], ["LSHandlerURLScheme": "https", "LSHandlerRoleAll": "com.apple.safari"]],
                                tiles: [(0, "/Applications/Gone.app")], ncApps: ["com.gone.app", "com.apple.mail"],
                                tcc: [TCCRow(service: "kTCCServiceCamera", client: "com.gone.app", allowed: true, lastModified: nil, isSystemDatabase: false)],
                                keychain: [KeychainItem(itemClass: "genp", service: "Gone Safe Storage", account: "Gone Key", label: "Gone Safe Storage", accessGroup: nil, server: nil, persistentRef: Data([1]))],
                                jobs: [], firewall: ["/Applications/Gone.app/Contents/MacOS/Gone"])
        let locator = RemainsLocator(rules: .bundled, home: home.path, registrations: reader)
        let result = await locator.locate(installed: [], appLocations: [home.appending(path: "Applications")])
        #expect(result.groups.contains { $0.title == "Broken" && $0.children.first?.subtitle?.contains("no Info.plist") == true })
        #expect(result.groups.contains { $0.title == "Hollow" && $0.children.first?.subtitle?.contains("executable Hollow is missing") == true })
        let titles = Set(result.groups.map(\.title))
        #expect(titles.contains("Zoom"))
        #expect(titles.contains("Chrome Remote Desktop"))
        let zoom = result.groups.first { $0.title == "Zoom" }!
        let zoomPaths = Set(zoom.children.compactMap { $0.url?.standardizedFileURL.path })
        #expect(zoomPaths.contains(home.appending(path: ".zoomus").standardizedFileURL.path))
        #expect(zoomPaths.contains(home.appending(path: "Library/Application Support/zoom.us").standardizedFileURL.path))
        #expect(zoom.payload["confidence"] == "high")
        let crd = result.groups.first { $0.title == "Chrome Remote Desktop" }!
        #expect(crd.children.contains { $0.title == "remoting_host_uninstaller_ABC.plist" })
        #expect(crd.children.contains { $0.url?.lastPathComponent == "Chrome Remote Desktop" })
        let registrations = result.groups.flatMap(\.children).filter { $0.kind == .registration }
        #expect(registrations.contains { $0.payload["type"] == "lsHandler" && $0.subtitle?.contains("com.gone.app") == true })
        #expect(registrations.contains { $0.payload["type"] == "dockTile" })
        #expect(registrations.contains { $0.payload["type"] == "notificationCenter" && $0.payload["bundleID"] == "com.gone.app" })
        #expect(registrations.contains { $0.payload["type"] == "tcc" })
        #expect(registrations.contains { $0.payload["type"] == "keychain" })
        #expect(registrations.contains { $0.payload["type"] == "firewall" })
        #expect(!registrations.contains { ($0.payload["bundleID"] ?? "").hasPrefix("com.apple.") })
    }
}
