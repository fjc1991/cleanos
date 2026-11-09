import Foundation
import Testing
@testable import CleanCore

/// A throwaway home folder with helpers to lay out files and fake apps.
struct FixtureHome {
    let url: URL
    var path: String { url.standardizedFileURL.path }

    init(_ name: String) {
        url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult func dir(_ relative: String) throws -> URL {
        let target = url.appending(path: relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult func file(_ relative: String, _ contents: String = "x") throws -> URL {
        let target = url.appending(path: relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: target)
        return target
    }

    func p(_ relative: String) -> String { url.appending(path: relative).standardizedFileURL.path }

    func app(_ relative: String, _ identity: AppIdentity) throws -> InstalledApp {
        let bundle = try dir(relative)
        return InstalledApp(url: bundle, name: identity.name, bundleID: identity.bundleID, version: nil, build: nil, isSystem: false,
                            modificationDate: nil, creationDate: nil, lastOpenedDate: nil, identity: identity)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

extension LeftoverScanResult {
    /// Items keyed by standardized path.
    var byPath: [String: ScanItem] {
        Dictionary(allItems.compactMap { item in item.url.map { ($0.standardizedFileURL.path, item) } }, uniquingKeysWith: { first, _ in first })
    }
}

@Suite struct VendorOverrideMatchingTests {
    @Test func overridesMatchExactlyOrByNamespace() {
        let overrides = Rules.bundled.overrides
        func paths(_ bundleID: String) -> Set<String> {
            Set(overrides.matching(bundleID: bundleID).flatMap { $0.include ?? [] }.map(\.path))
        }
        let chrome = paths("com.google.Chrome")
        #expect(chrome.contains("~/Library/Application Support/Google/Chrome"))
        #expect(!chrome.contains("~/Library/Application Support/Google/Chrome Canary"))
        let canary = paths("com.google.Chrome.canary")
        #expect(canary.contains("~/Library/Application Support/Google/Chrome Canary"))
        #expect(!canary.contains("~/Library/Application Support/Google/Chrome"))
        #expect(canary.contains("~/Library/Google/GoogleSoftwareUpdate"))          // the shared Keystone rule names every channel
        // A Chrome web-app shim gets none of Chrome's rules.
        #expect(paths("com.google.Chrome.app.abcdefghijklmnopabcdefghijklmnop").isEmpty)
        let insiders = paths("com.microsoft.VSCodeInsiders")
        #expect(insiders.contains("~/Library/Application Support/Code - Insiders"))
        #expect(!insiders.contains("~/Library/Application Support/Code"))
        #expect(insiders.contains("~/Library/Application Support/Microsoft"))      // the `com.microsoft.` namespace rule
        #expect(!paths("com.brave.Browser.beta").contains("~/Library/Application Support/BraveSoftware/Brave-Browser"))
        #expect(paths("org.mozilla.firefox").contains("~/Library/Application Support/Firefox"))
        #expect(!paths("org.mozilla.firefoxdeveloperedition").contains("~/Library/Application Support/Firefox"))
        #expect(BundleIDPattern.matches("com.microsoft.", "com.microsoft.Word"))
        #expect(!BundleIDPattern.matches("com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"))
        #expect(BundleIDPattern.matches("COM.Google.Chrome", "com.google.chrome"))
    }

    @Test func vendorPrefixIgnoresHostingNamespaces() {
        #expect(AppIdentity.vendorPrefix(of: "com.microsoft.Word") == "com.microsoft")
        #expect(AppIdentity.vendorPrefix(of: "io.github.alice.Tool") == "io.github.alice")
        #expect(AppIdentity.vendorPrefix(of: "io.github.Tool") == nil)
        #expect(AppIdentity.vendorPrefix(of: "net.sourceforge.foo.App") == "net.sourceforge.foo")
        #expect(AppIdentity.vendorPrefix(of: "uk.co.example.App") == "uk.co.example")
        #expect(AppInspector.vendorSegment(of: "io.github.alice.Tool") == "alice")
        #expect(AppInspector.vendorSegment(of: "com.github.Tool") == nil)
    }
}

@Suite struct LeftoverPrecisionTests {
    static let chromeTeam = "EQHXZ8M8AV"
    static let shimID = "com.google.Chrome.app.abcdefghijklmnopabcdefghijklmnop"

    @Test func chromeCanaryAndWebAppShimKeepTheirOwnData() async throws {
        let home = FixtureHome("ChromeChannels")
        defer { home.remove() }
        for folder in ["Library/Application Support/Google/Chrome", "Library/Application Support/Google/Chrome Canary",
                       "Library/Caches/Google/Chrome", "Library/Caches/Google/Chrome Canary", "Library/Google/GoogleSoftwareUpdate",
                       "Library/Caches/\(Self.shimID)"] {
            try home.dir(folder)
        }
        try home.file("Library/Preferences/com.google.Chrome.plist")
        try home.file("Library/Preferences/com.google.Chrome.canary.plist")
        let chrome = try home.app("Applications/Google Chrome.app", AppIdentity(
            bundleID: "com.google.Chrome", name: "Google Chrome", bundleName: "Chrome", fileName: "Google Chrome", executable: "Google Chrome", teamID: Self.chromeTeam))
        let canary = try home.app("Applications/Google Chrome Canary.app", AppIdentity(
            bundleID: "com.google.Chrome.canary", name: "Google Chrome Canary", bundleName: "Chrome Canary", fileName: "Google Chrome Canary",
            executable: "Google Chrome Canary", teamID: Self.chromeTeam))
        let shim = try home.app("Applications/Chrome Apps.localized/YouTube.app", AppIdentity(
            bundleID: Self.shimID, name: "YouTube", fileName: "YouTube", executable: "app_mode_loader"))
        let locator = LeftoverLocator(rules: .bundled, home: home.path)

        // Chrome, with Canary and a web-app shim still installed.
        let chromeItems = await locator.locate(app: chrome, otherApps: [canary, shim]).byPath
        #expect(chromeItems[home.p("Library/Application Support/Google/Chrome")]?.tier == .normal)
        #expect(chromeItems[home.p("Library/Caches/Google/Chrome")]?.tier == .safe)
        #expect(chromeItems[home.p("Library/Preferences/com.google.Chrome.plist")]?.tier == .normal)
        for foreign in ["Library/Application Support/Google/Chrome Canary", "Library/Caches/Google/Chrome Canary",
                        "Library/Preferences/com.google.Chrome.canary.plist", "Library/Caches/\(Self.shimID)",
                        "Library/Google/GoogleSoftwareUpdate"] {   // Keystone still serves Canary
            #expect(chromeItems[home.p(foreign)] == nil, "Chrome claimed \(foreign)")
        }

        // Canary, with Chrome still installed.
        let canaryItems = await locator.locate(app: canary, otherApps: [chrome, shim]).byPath
        #expect(canaryItems[home.p("Library/Application Support/Google/Chrome Canary")]?.tier == .normal)
        #expect(canaryItems[home.p("Library/Caches/Google/Chrome Canary")] != nil)
        #expect(canaryItems[home.p("Library/Preferences/com.google.Chrome.canary.plist")] != nil)
        for foreign in ["Library/Application Support/Google/Chrome", "Library/Caches/Google/Chrome",
                        "Library/Preferences/com.google.Chrome.plist", "Library/Google/GoogleSoftwareUpdate"] {
            #expect(canaryItems[home.p(foreign)] == nil, "Canary claimed \(foreign)")
        }

        // The web-app shim owns only its own traces.
        let shimItems = await locator.locate(app: shim, otherApps: [chrome, canary]).byPath
        #expect(shimItems[home.p("Library/Caches/\(Self.shimID)")] != nil)
        for foreign in ["Library/Application Support/Google/Chrome", "Library/Application Support/Google/Chrome Canary",
                        "Library/Caches/Google/Chrome", "Library/Preferences/com.google.Chrome.plist", "Library/Google/GoogleSoftwareUpdate"] {
            #expect(shimItems[home.p(foreign)] == nil, "the shim claimed \(foreign)")
        }

        // Chrome alone: the shared Keystone updater is offered, but never pre-selected.
        let alone = await locator.locate(app: chrome, otherApps: []).byPath
        #expect(alone[home.p("Library/Google/GoogleSoftwareUpdate")]?.tier == .caution)
    }

    @Test func vsCodeAndInsidersKeepTheirOwnData() async throws {
        let home = FixtureHome("VSCode")
        defer { home.remove() }
        for folder in ["Library/Application Support/Code", "Library/Application Support/Code - Insiders", ".vscode", ".vscode-insiders",
                       ".vscode-shared", "Library/Caches/com.microsoft.VSCode", "Library/Caches/com.microsoft.VSCodeInsiders",
                       "Library/Group Containers/UBF8T346G9.Office"] {
            try home.dir(folder)
        }
        let code = try home.app("Applications/Visual Studio Code.app", AppIdentity(
            bundleID: "com.microsoft.VSCode", name: "Code", bundleName: "Code", fileName: "Visual Studio Code", executable: "Electron", teamID: "UBF8T346G9"))
        let insiders = try home.app("Applications/Visual Studio Code - Insiders.app", AppIdentity(
            bundleID: "com.microsoft.VSCodeInsiders", name: "Code - Insiders", bundleName: "Code - Insiders", fileName: "Visual Studio Code - Insiders",
            executable: "Electron", teamID: "UBF8T346G9"))
        let locator = LeftoverLocator(rules: .bundled, home: home.path)

        let items = await locator.locate(app: code, otherApps: [insiders]).byPath
        #expect(items[home.p("Library/Application Support/Code")]?.tier == .normal)
        #expect(items[home.p(".vscode")]?.tier == .normal)
        #expect(items[home.p("Library/Caches/com.microsoft.VSCode")]?.tier == .safe)
        let shared = items[home.p(".vscode-shared")]
        #expect(shared?.tier == .caution)
        #expect(shared?.subtitle?.contains("Code - Insiders") == true)
        // Another app of the same team is installed: a container that only carries the Team ID is not pre-selected.
        #expect(items[home.p("Library/Group Containers/UBF8T346G9.Office")]?.tier == .caution)
        for foreign in ["Library/Application Support/Code - Insiders", ".vscode-insiders", "Library/Caches/com.microsoft.VSCodeInsiders"] {
            #expect(items[home.p(foreign)] == nil, "VS Code claimed \(foreign)")
        }

        let insidersItems = await locator.locate(app: insiders, otherApps: [code]).byPath
        #expect(insidersItems[home.p("Library/Application Support/Code - Insiders")]?.tier == .normal)
        #expect(insidersItems[home.p(".vscode-insiders")] != nil)
        #expect(insidersItems[home.p("Library/Application Support/Code")] == nil)
        #expect(insidersItems[home.p(".vscode")] == nil)
    }

    @Test func teamGroupContainersAreCautiousWhenTheTeamHasAnotherApp() async throws {
        let home = FixtureHome("TeamGroups")
        defer { home.remove() }
        for folder in ["Library/Group Containers/TEAMID1234.com.dev.shared", "Library/Group Containers/TEAMID1234.com.dev.alpha",
                       "Library/Group Containers/group.com.dev.alpha", "Library/Group Containers/group.com.dev.beta.data",
                       "Library/Group Containers/TEAMID1234.com.dev.beta"] {
            try home.dir(folder)
        }
        let alpha = try home.app("Applications/Alpha.app", AppIdentity(bundleID: "com.dev.alpha", name: "Alpha", fileName: "Alpha", teamID: "TEAMID1234"))
        let beta = try home.app("Applications/Beta.app", AppIdentity(bundleID: "com.dev.beta", name: "Beta", fileName: "Beta", teamID: "TEAMID1234"))
        let locator = LeftoverLocator(rules: .bundled, home: home.path)

        let items = await locator.locate(app: alpha, otherApps: [beta]).byPath
        let shared = items[home.p("Library/Group Containers/TEAMID1234.com.dev.shared")]
        #expect(shared?.tier == .caution)
        #expect(shared?.subtitle?.contains("Beta") == true)
        // Containers that name the app itself (behind the team prefix or `group.`) stay pre-selected.
        #expect(items[home.p("Library/Group Containers/TEAMID1234.com.dev.alpha")]?.tier == .normal)
        #expect(items[home.p("Library/Group Containers/group.com.dev.alpha")]?.tier == .normal)
        #expect(items[home.p("Library/Group Containers/group.com.dev.beta.data")] == nil)
        #expect(items[home.p("Library/Group Containers/TEAMID1234.com.dev.beta")]?.tier != .normal)

        // Alone, the team's containers are this app's leftovers.
        let alone = await locator.locate(app: alpha, otherApps: []).byPath
        #expect(alone[home.p("Library/Group Containers/TEAMID1234.com.dev.shared")]?.tier == .normal)
    }

    @Test func pluginsNeedTheSameSignerNotJustThePrefix() async throws {
        let home = FixtureHome("Plugins")
        defer { home.remove() }
        try home.file("Library/Internet Plug-Ins/Other.plugin/Contents/Info.plist", try LeftoverLocatorTests.plist(["CFBundleIdentifier": "com.example.otherplugin"]))
        try home.file("Library/Internet Plug-Ins/Bob.plugin/Contents/Info.plist", try LeftoverLocatorTests.plist(["CFBundleIdentifier": "io.github.bob.plugin"]))
        let app = try home.app("Applications/Fake.app", AppIdentity(bundleID: "com.example.fake", name: "Fake", fileName: "Fake", teamID: "ABCDE12345"))
        let alice = try home.app("Applications/AliceTool.app", AppIdentity(bundleID: "io.github.alice.tool", name: "Alice Tool", fileName: "AliceTool"))
        let locator = LeftoverLocator(rules: .bundled, home: home.path)

        // Unsigned plug-in with the developer's prefix: offered, not pre-selected.
        let items = await locator.locate(app: app, otherApps: []).byPath
        let other = items[home.p("Library/Internet Plug-Ins/Other.plugin")]
        #expect(other?.tier == .caution)
        #expect(other?.matchedBy.contains { $0.contains("signer not verified") } == true)
        // `io.github.` names a hosting service, not a developer.
        let aliceItems = await locator.locate(app: alice, otherApps: []).byPath
        #expect(aliceItems[home.p("Library/Internet Plug-Ins/Bob.plugin")] == nil)
    }

    @Test func emptiedVendorFolderOnlyWhenNothingElseIsInside() async throws {
        let home = FixtureHome("Brave")
        defer { home.remove() }
        try home.file("Library/Caches/BraveSoftware/Brave-Browser/cache.bin")
        try home.file("Library/Application Support/BraveSoftware/Brave-Browser/Default/Preferences")
        let brave = try home.app("Applications/Brave Browser.app", AppIdentity(bundleID: "com.brave.Browser", name: "Brave Browser", fileName: "Brave Browser"))
        let locator = LeftoverLocator(rules: .bundled, home: home.path)

        let alone = await locator.locate(app: brave, otherApps: []).byPath
        #expect(alone[home.p("Library/Caches/BraveSoftware")]?.tier == .safe)
        #expect(alone[home.p("Library/Application Support/BraveSoftware")]?.tier == .normal)
        #expect(alone[home.p("Library/Caches/BraveSoftware/Brave-Browser")] == nil)        // folded into its parent

        // Brave Beta's data shares the vendor folders: only Brave's own subfolders are listed.
        try home.dir("Library/Caches/BraveSoftware/Brave-Browser-Beta")
        try home.dir("Library/Application Support/BraveSoftware/Brave-Browser-Beta")
        let beta = try home.app("Applications/Brave Browser Beta.app", AppIdentity(bundleID: "com.brave.Browser.beta", name: "Brave Browser Beta", fileName: "Brave Browser Beta"))
        let items = await locator.locate(app: brave, otherApps: [beta]).byPath
        #expect(items[home.p("Library/Caches/BraveSoftware")] == nil)
        #expect(items[home.p("Library/Application Support/BraveSoftware")] == nil)
        #expect(items[home.p("Library/Caches/BraveSoftware/Brave-Browser")] != nil)
        #expect(items[home.p("Library/Caches/BraveSoftware/Brave-Browser-Beta")] == nil)
        #expect(items[home.p("Library/Application Support/BraveSoftware/Brave-Browser-Beta")] == nil)
    }

    @Test func firefoxProfilesAreCautiousWhileAnotherEditionIsInstalled() async throws {
        let home = FixtureHome("Firefox")
        defer { home.remove() }
        try home.dir("Library/Application Support/Firefox/Profiles/abc.default-release")
        try home.dir("Library/Caches/Firefox/Profiles/abc.default-release")
        let firefox = try home.app("Applications/Firefox.app", AppIdentity(bundleID: "org.mozilla.firefox", name: "Firefox", fileName: "Firefox", executable: "firefox"))
        let devEdition = try home.app("Applications/Firefox Developer Edition.app", AppIdentity(
            bundleID: "org.mozilla.firefoxdeveloperedition", name: "Firefox Developer Edition", fileName: "Firefox Developer Edition", executable: "firefox"))
        let locator = LeftoverLocator(rules: .bundled, home: home.path)

        let alone = await locator.locate(app: firefox, otherApps: []).byPath
        #expect(alone[home.p("Library/Application Support/Firefox")]?.tier == .normal)
        #expect(alone[home.p("Library/Caches/Firefox")]?.tier == .safe)

        let shared = await locator.locate(app: firefox, otherApps: [devEdition]).byPath
        #expect(shared[home.p("Library/Application Support/Firefox")]?.tier == .caution)
        #expect(shared[home.p("Library/Caches/Firefox")]?.tier == .caution)
        #expect(shared[home.p("Library/Application Support/Firefox")]?.subtitle?.contains("Firefox Developer Edition") == true)
        // The Developer Edition gets nothing of Firefox's rule.
        let dev = await locator.locate(app: devEdition, otherApps: [firefox]).byPath
        #expect(dev[home.p("Library/Application Support/Firefox")] == nil)
    }

    @Test func secondCopyOfTheSameAppIsSkippedAndSymlinkedDuplicateIsIgnored() async throws {
        let home = FixtureHome("Duplicates")
        defer { home.remove() }
        try home.dir("Library/Caches/com.example.real")
        try home.dir("Library/Application Support/Zoomy")
        let identity = AppIdentity(bundleID: "com.example.real", name: "Real", fileName: "Real")
        let real = try home.app("Applications/Real.app", identity)
        try home.dir("Elsewhere")
        try FileManager.default.createSymbolicLink(at: home.url.appending(path: "Elsewhere/Real.app"), withDestinationURL: real.url)
        let viaLink = InstalledApp(url: home.url.appending(path: "Elsewhere/Real.app"), name: "Real", bundleID: "com.example.real", version: nil, build: nil,
                                   isSystem: false, modificationDate: nil, creationDate: nil, lastOpenedDate: nil, identity: identity)
        let locator = LeftoverLocator(rules: .bundled, home: home.path)
        let items = await locator.locate(app: real, otherApps: [viaLink]).byPath
        let cache = items[home.p("Library/Caches/com.example.real")]
        #expect(cache?.tier == .safe)
        #expect(cache?.subtitle?.hasPrefix("Shared with") != true)
    }

    @Test func needsRootIsDecidedPerItem() throws {
        let home = FixtureHome("NeedsRoot")
        defer { home.remove() }
        let mine = try home.dir("Owned")
        let systemRule = Rules.bundled.catalogue.roots.first { $0.id == "local-app-support" }!
        let userRule = Rules.bundled.catalogue.roots.first { $0.id == "user-caches" }!
        #expect(systemRule.requiresRoot)
        #expect(!LeftoverLocator.needsRoot(systemRule, mine))                       // the user can remove it
        #expect(LeftoverLocator.needsRoot(systemRule, URL(filePath: "/usr/bin/true"))) // root-owned, in a root-owned folder
        #expect(!LeftoverLocator.needsRoot(userRule, URL(filePath: "/usr/bin/true")))  // a user-location rule never asks for root
    }
}

@Suite struct PackagePayloadTests {
    @Test func payloadNeverCollapsesToSharedParents() throws {
        let root = FixtureHome("Payload")
        defer { root.remove() }
        try root.file("usr/local/bin/tool")
        try root.file("usr/local/bin/othertool")                                    // another package's
        try root.file("usr/local/share/foo/data.txt")
        try root.file("usr/local/lib/pkgconfig/tool.pc")
        try root.file("usr/local/lib/pkgconfig/other.pc")                           // another package's
        try root.file("Library/Application Support/Vendor/Product/settings.plist")
        try root.file("Library/Application Support/Vendor/OtherProduct/settings.plist")
        try root.file("Library/Application Support/Solo/a.txt")
        try root.file("Library/Application Support/Solo/runtime-cache.db")          // created after installation
        let manifest = [".", "usr", "usr/local", "usr/local/bin", "usr/local/bin/tool", "usr/local/share", "usr/local/share/foo",
                        "usr/local/share/foo/data.txt", "usr/local/lib", "usr/local/lib/pkgconfig", "usr/local/lib/pkgconfig/tool.pc",
                        "Library", "Library/Application Support", "Library/Application Support/Vendor", "Library/Application Support/Vendor/Product",
                        "Library/Application Support/Vendor/Product/settings.plist", "Library/Application Support/Solo",
                        "Library/Application Support/Solo/a.txt", "usr/local/bin/gone"]
        let shared = Set(PackageReceipts.sharedParents.map { root.path + $0 })
        let owned = Set(PackageReceipts.ownedPayloadPaths(manifest: manifest, base: root.url, sharedParents: shared))
        #expect(owned == [root.p("usr/local/bin/tool"), root.p("usr/local/share/foo"), root.p("usr/local/lib/pkgconfig/tool.pc"),
                          root.p("Library/Application Support/Vendor/Product"), root.p("Library/Application Support/Solo/a.txt")])
        for parent in ["", "usr", "usr/local", "usr/local/bin", "usr/local/lib/pkgconfig", "Library/Application Support",
                       "Library/Application Support/Vendor", "Library/Application Support/Solo"] {
            #expect(!owned.contains(root.p(parent)), "emitted \(parent)")
        }
    }
}
