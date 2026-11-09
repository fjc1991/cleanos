import Foundation
import Testing
@testable import CleanCore

/// Remains scans with a fixture home and a stubbed Launch Services, so nothing depends on what this Mac has installed.
@Suite struct RemainsPrecisionTests {
    /// The bundled rules with the given families only, stripped of host-dependent parts (system paths, running processes).
    static func rules(families ids: [String], adjust: (inout LeftoverFamily) -> Void = { _ in }) -> Rules {
        let bundled = Rules.bundled
        let families = bundled.families.filter { ids.contains($0.id) }.map { family -> LeftoverFamily in
            var family = family
            family.paths = family.paths.filter { $0.hasPrefix("~") }
            family.cautionPaths = family.cautionPaths?.filter { $0.hasPrefix("~") }
            family.installedIfExists = family.installedIfExists?.filter { $0.hasPrefix("~") }
            family.processNames = []
            adjust(&family)
            return family
        }
        return Rules(catalogue: bundled.catalogue, shared: bundled.shared, overrides: bundled.overrides,
                     protectedRules: bundled.protectedRules, families: families)
    }

    static let nothingElsewhere: @Sendable (String) -> LaunchServicesLookup.Resolution = { _ in .notRegistered }

    static func items(_ result: RemainsScanResult) -> [String: ScanItem] {
        Dictionary(result.groups.flatMap(\.children).compactMap { item in item.url.map { ($0.standardizedFileURL.path, item) } },
                   uniquingKeysWith: { first, _ in first })
    }

    @Test func cloudStorageFamilyPathsAreCautionAndNeverPreselected() async throws {
        let home = FixtureHome("RemainsCloud")
        defer { home.remove() }
        try home.file("Library/CloudStorage/OneDrive-Personal/Document.docx")
        try home.dir("Library/Mobile Documents/iCloud~com~skype~skype")
        let locator = RemainsLocator(rules: Self.rules(families: ["onedrive", "skype"]), home: home.path, appLookup: Self.nothingElsewhere)
        let result = await locator.locate(installed: [], appLocations: [])
        let items = Self.items(result)
        let oneDrive = items[home.p("Library/CloudStorage/OneDrive-Personal")]
        #expect(oneDrive?.group == "Cloud")
        #expect(oneDrive?.tier == .caution)
        #expect(oneDrive?.tier.isSelectableByDefault == false)
        let skype = items[home.p("Library/Mobile Documents/iCloud~com~skype~skype")]
        #expect(skype?.group == "Cloud")
        #expect(skype?.tier == .caution)
        #expect(RemainsLocator.group(forPath: home.p("Library/CloudStorage/GoogleDrive-me@example.com"), home: home.path) == "Cloud")
        #expect(RemainsLocator.group(forPath: home.p("Library/Mobile Documents/iCloud~com~skype~skype"), home: home.path) == "Cloud")
    }

    @Test func familiesWithAnotherInstallationAreNotReported() async throws {
        let home = FixtureHome("RemainsProbes")
        defer { home.remove() }
        try home.file(".docker/config.json", "{}")
        try home.dir("Library/Application Support/Oracle")
        let rules = Self.rules(families: ["docker", "oracle-java"])
        let docker = rules.families.first { $0.id == "docker" }!
        #expect(docker.installedIfExists?.contains("~/.orbstack") == true)
        #expect(docker.cautionPaths?.contains("~/.docker") == true)

        // Nothing else installed: Docker's dotfolder is reported, but only at caution.
        let before = Self.items(await RemainsLocator(rules: rules, home: home.path, appLookup: Self.nothingElsewhere).locate(installed: [], appLocations: []))
        #expect(before[home.p(".docker")]?.tier == .caution)
        #expect(before[home.p("Library/Application Support/Oracle")] != nil)

        // OrbStack and a JDK still use these files.
        try home.dir(".orbstack")
        try home.dir("Library/Java/JavaVirtualMachines/temurin-21.jdk")
        let after = Self.items(await RemainsLocator(rules: rules, home: home.path, appLookup: Self.nothingElsewhere).locate(installed: [], appLocations: []))
        #expect(after[home.p(".docker")] == nil)
        #expect(after[home.p("Library/Application Support/Oracle")] == nil)
    }

    @Test func familyTokensMatchWholeWordsBelowTheHomeFolder() {
        let families = Rules.bundled.families
        // The user's own folder name says nothing.
        #expect(RemainsLocator.family(for: "/Users/slack/Library/Caches/com.example.other", in: families, home: "/Users/slack") == nil)
        #expect(RemainsLocator.family(for: "/Users/slack/Library/Application Support/Slack", in: families, home: "/Users/slack")?.id == "slack")
        // Tokens inside a longer word do not count.
        #expect(RemainsLocator.family(for: "/Users/x/Library/Caches/com.example.devbox", in: families, home: "/Users/x") == nil)
        #expect(RemainsLocator.family(for: "/Users/x/Library/Caches/com.someapp.autoupdate", in: families, home: "/Users/x") == nil)
        #expect(RemainsLocator.family(for: "/Users/x/Library/Logs/VBoxSVC.log", in: families, home: "/Users/x")?.id == "virtualbox")
        #expect(NameMatcher.containsWord("ksinstallaction", in: "KSInstallAction.AnxY8JgJO6"))
        #expect(NameMatcher.containsWord("remotinghost", in: "remoting_host_uninstaller_1.plist"))
        #expect(NameMatcher.containsWord("googlesoftwareupdate", in: "GoogleSoftwareUpdateAgent.log"))
        #expect(!NameMatcher.containsWord("vbox", in: "devbox"))
        #expect(!NameMatcher.containsWord("steam", in: "steamroller"))
    }

    @Test func identifierOrphansKnownToLaunchServicesAreSkipped() async throws {
        let home = FixtureHome("RemainsLS")
        defer { home.remove() }
        try home.dir("Library/Caches/com.elsewhere.app")
        try home.dir("Library/Caches/com.offline.app.helper")
        try home.dir("Library/Caches/com.gone.app")
        let lookup: @Sendable (String) -> LaunchServicesLookup.Resolution = { id in
            switch id.lowercased() {
            case "com.elsewhere.app": .present
            case "com.offline.app": .onUnmountedVolume
            default: .notRegistered
            }
        }
        let result = await RemainsLocator(rules: Self.rules(families: []), home: home.path, appLookup: lookup).locate(installed: [], appLocations: [])
        let items = Self.items(result)
        #expect(items[home.p("Library/Caches/com.gone.app")] != nil)
        #expect(items[home.p("Library/Caches/com.elsewhere.app")] == nil)
        #expect(items[home.p("Library/Caches/com.offline.app.helper")] == nil)

        #expect(LaunchServicesLookup.classify(["/Volumes/Gone Disk/Applications/X.app"], fileExists: { _ in false }) == .onUnmountedVolume)
        #expect(LaunchServicesLookup.classify(["/Applications/X.app"], fileExists: { _ in false }) == .stale)
        #expect(LaunchServicesLookup.classify(["/Applications/X.app"], fileExists: { $0 == "/Applications/X.app" }) == .present)
        #expect(RemainsLocator.bundleIDCandidates("com.vendor.app.helper") == ["com.vendor.app.helper", "com.vendor.app"])
    }

    @Test func launchServicesHandlersAreIdentifiedByContent() async throws {
        let home = FixtureHome("RemainsHandlers")
        defer { home.remove() }
        let reader = StubReader(handlers: [
            ["LSHandlerURLScheme": "gonescheme", "LSHandlerRoleAll": "com.gone.app"],
            ["LSHandlerContentType": "public.gone-document", "LSHandlerRoleViewer": "com.gone.app"],
            ["LSHandlerContentTag": "gone", "LSHandlerContentTagClass": "public.filename-extension", "LSHandlerRoleAll": "com.gone.app"],
            ["LSHandlerRoleAll": "com.gone.app"],                                              // nothing to match on: skipped
            ["LSHandlerURLScheme": "https", "LSHandlerRoleAll": "com.apple.safari"],
        ])
        let result = await RemainsLocator(rules: Self.rules(families: []), home: home.path, registrations: reader, appLookup: Self.nothingElsewhere)
            .locate(installed: [], appLocations: [])
        let handlers = result.groups.flatMap(\.children).filter { $0.payload["type"] == "lsHandler" }
        #expect(handlers.count == 3)
        let scheme = handlers.first { $0.payload["matchValue"] == "gonescheme" }
        #expect(scheme?.id == "registration:ls:LSHandlerURLScheme:gonescheme:com.gone.app")
        #expect(scheme?.payload == ["type": "lsHandler", "subject": "URL scheme gonescheme://", "role": "com.gone.app",
                                    "matchKey": "LSHandlerURLScheme", "matchValue": "gonescheme", "confidence": "high"])
        #expect(handlers.contains { $0.payload["matchKey"] == "LSHandlerContentType" && $0.payload["matchValue"] == "public.gone-document" })
        #expect(handlers.contains { $0.payload["matchKey"] == "LSHandlerContentTag" && $0.payload["matchValue"] == "gone" })
        #expect(handlers.allSatisfy { $0.payload["index"] == nil })

        // The URL scheme wins over the content type when a handler has both.
        let both = RemainsLocator.launchServicesHandlerItem(["LSHandlerContentType": "public.x", "LSHandlerURLScheme": "x", "LSHandlerRoleAll": "com.gone.app"],
                                                            missingBundleID: "com.gone.app")
        #expect(both?.payload["matchKey"] == "LSHandlerURLScheme")
    }

    @Test func safeStorageKeysOfInstalledBrowsersAreKept() async throws {
        let home = FixtureHome("RemainsKeychain")
        defer { home.remove() }
        func key(_ name: String, _ ref: UInt8) -> KeychainItem {
            KeychainItem(itemClass: "genp", service: name, account: name.replacingOccurrences(of: " Safe Storage", with: ""), label: name,
                         accessGroup: nil, server: nil, persistentRef: Data([ref]))
        }
        let reader = StubReader(keychain: [key("Chrome Safe Storage", 1), key("Brave Safe Storage", 2), key("Electron Safe Storage", 3),
                                           key("Gone Safe Storage", 4), key("Vivaldi Safe Storage", 5)])
        let chrome = InstalledApp(url: home.url.appending(path: "Applications/Google Chrome.app"), name: "Google Chrome", bundleID: "com.google.Chrome",
                                  version: nil, build: nil, isSystem: false, modificationDate: nil, creationDate: nil, lastOpenedDate: nil,
                                  identity: AppIdentity(bundleID: "com.google.Chrome", name: "Google Chrome", fileName: "Google Chrome", executable: "Google Chrome"))
        let lookup: @Sendable (String) -> LaunchServicesLookup.Resolution = { $0.lowercased() == "com.brave.browser" ? .present : .notRegistered }
        let result = await RemainsLocator(rules: Self.rules(families: []), home: home.path, registrations: reader, appLookup: lookup)
            .locate(installed: [chrome], appLocations: [])
        let keys = Set(result.groups.flatMap(\.children).filter { $0.payload["type"] == "keychain" }.map(\.title))
        #expect(keys == ["Gone Safe Storage", "Vivaldi Safe Storage"])
    }

    @Test func installerTempOwnersRunningKeepTheirFiles() {
        #expect(RemainsLocator.installerTempOwnerIsRunning("KSInstallAction.abc", running: ["com.google.chrome"], runningProcessNames: []))
        #expect(RemainsLocator.installerTempOwnerIsRunning("com.microsoft.autoupdate.x", running: [], runningProcessNames: ["microsoftautoupdate"]))
        #expect(RemainsLocator.installerTempOwnerIsRunning("Foo Installer.pkg", running: ["com.apple.installer"], runningProcessNames: []))
        #expect(!RemainsLocator.installerTempOwnerIsRunning("KSInstallAction.abc", running: ["com.adobe.acrobat"], runningProcessNames: []))
    }
}
