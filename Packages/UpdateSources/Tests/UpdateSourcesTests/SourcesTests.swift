import Foundation
import Testing
@testable import UpdateSources

@Suite struct SourcesTests {
    let app = UpdatableApp(bundleID: "com.example.app", name: "Example", appURL: URL(filePath: "/Applications/Example.app"),
                           shortVersion: "2.3.0", buildVersion: "230", sparkleFeedURL: URL(string: "https://example.com/appcast.xml"), hasMASReceipt: true)

    func appcast(_ items: String) -> Data {
        Data("""
        <?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
        \(items)
        </channel></rss>
        """.utf8)
    }

    // MARK: Sparkle

    @Test func sparkleAppcastPicksNewestCompatibleItem() {
        let xml = appcast("""
        <item><title>Version 2.4.0</title><sparkle:releaseNotesLink>https://example.com/notes/2.4</sparkle:releaseNotesLink>
          <enclosure url="https://example.com/Example-2.4.0.zip" sparkle:version="240" sparkle:shortVersionString="2.4.0"/></item>
        <item><title>Version 3.0.0</title><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/Example-3.0.0.zip" sparkle:version="300" sparkle:shortVersionString="3.0.0"/></item>
        <item><title>Version 2.3.0</title><enclosure url="https://example.com/Example-2.3.0.zip" sparkle:version="230" sparkle:shortVersionString="2.3.0"/></item>
        """)
        let update = SparkleSource.newestUpdate(for: app, appcast: xml)
        #expect(update?.latestVersion == "2.4.0")
        #expect(update?.downloadURL?.lastPathComponent == "Example-2.4.0.zip")
        #expect(update?.releaseNotesURL?.path == "/notes/2.4")
        let upToDate = UpdatableApp(bundleID: "x", name: "x", appURL: app.appURL, shortVersion: "2.4.0", buildVersion: "240", sparkleFeedURL: nil, hasMASReceipt: false)
        #expect(SparkleSource.newestUpdate(for: upToDate, appcast: xml) == nil)
    }

    @Test func sparkleHonoursSystemVersionBoundsAndOS() {
        let xml = appcast("""
        <item><sparkle:maximumSystemVersion>10.15</sparkle:maximumSystemVersion><enclosure url="https://example.com/old.zip" sparkle:version="400"/></item>
        <item><enclosure url="https://example.com/win.exe" sparkle:version="500" sparkle:os="windows"/></item>
        <item><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><enclosure url="https://example.com/ok.zip" sparkle:version="250" sparkle:os="macos"/></item>
        """)
        #expect(SparkleSource.newestUpdate(for: app, appcast: xml, systemVersion: "15.1")?.downloadURL?.lastPathComponent == "ok.zip")
        #expect(SparkleSource.newestUpdate(for: app, appcast: xml, systemVersion: "13.6") == nil)
    }

    @Test func sparkleComparesBuildBeforeShortVersion() {
        // Same marketing version, newer build: an update, shown with both builds.
        let rebuild = appcast(#"<item><enclosure url="https://example.com/a.zip" sparkle:version="231" sparkle:shortVersionString="2.3.0"/></item>"#)
        let update = SparkleSource.newestUpdate(for: app, appcast: rebuild)
        #expect(update?.installedVersion == "2.3.0 (230)" && update?.latestVersion == "2.3.0 (231)")
        // Marketing version moved on but the build did not: Sparkle would not offer it, so neither do we.
        let relabelled = appcast(#"<item><enclosure url="https://example.com/a.zip" sparkle:version="230" sparkle:shortVersionString="2.4"/></item>"#)
        #expect(SparkleSource.newestUpdate(for: app, appcast: relabelled) == nil)
        // Without an installed build, short versions are the fallback.
        let noBuild = UpdatableApp(bundleID: "x", name: "x", appURL: app.appURL, shortVersion: "2.3.0", buildVersion: nil, sparkleFeedURL: nil, hasMASReceipt: false)
        #expect(SparkleSource.newestUpdate(for: noBuild, appcast: relabelled)?.latestVersion == "2.4")
    }

    @Test func sparkleBuildOnlyFeed() {
        let xml = appcast("""
        <item><sparkle:version>241</sparkle:version><enclosure url="https://example.com/241.zip"/></item>
        <item><enclosure url="https://example.com/239.zip" sparkle:version="239"/></item>
        """)
        let update = SparkleSource.newestUpdate(for: app, appcast: xml)
        #expect(update?.installedVersion == "230" && update?.latestVersion == "241")
        #expect(update?.downloadURL?.lastPathComponent == "241.zip")
        let current = UpdatableApp(bundleID: "x", name: "x", appURL: app.appURL, shortVersion: "2.4.1", buildVersion: "241", sparkleFeedURL: nil, hasMASReceipt: false)
        #expect(SparkleSource.newestUpdate(for: current, appcast: xml) == nil)
    }

    @Test func sparkleIgnoresDeltaEnclosures() {
        let xml = appcast("""
        <item><enclosure url="https://example.com/Example-2.4.0.zip" sparkle:version="240" sparkle:shortVersionString="2.4.0"/>
          <sparkle:deltas>
            <enclosure url="https://example.com/240-230.delta" sparkle:version="240" sparkle:deltaFrom="230"/>
            <enclosure url="https://example.com/240-220.delta" sparkle:version="240" sparkle:deltaFrom="220"/>
          </sparkle:deltas></item>
        <item><enclosure url="https://example.com/stray.delta" sparkle:version="999" sparkle:deltaFrom="230"/></item>
        """)
        let items = SparkleSource.parse(xml)
        #expect(items.count == 2 && items[1].version == nil && items[1].url == nil)
        let update = SparkleSource.newestUpdate(for: app, appcast: xml)
        #expect(update?.latestVersion == "2.4.0" && update?.downloadURL?.lastPathComponent == "Example-2.4.0.zip")
    }

    @Test func sparkleSkipsChannelItems() {
        let xml = appcast("""
        <item><sparkle:channel>beta</sparkle:channel><enclosure url="https://example.com/3.0b1.zip" sparkle:version="300" sparkle:shortVersionString="3.0b1"/></item>
        <item><enclosure url="https://example.com/2.4.0.zip" sparkle:version="240" sparkle:shortVersionString="2.4.0"/></item>
        """)
        #expect(SparkleSource.newestUpdate(for: app, appcast: xml)?.latestVersion == "2.4.0")
    }

    @Test func onlyHTTPSLinksAreKept() {
        #expect(UpdateHTTP.secureURL("https://example.com/a.zip") != nil)
        #expect(UpdateHTTP.secureURL(" HTTPS://example.com/a.zip ") != nil)
        #expect(UpdateHTTP.secureURL("http://example.com/a.zip") == nil)
        #expect(UpdateHTTP.secureURL("file:///Applications/Calculator.app") == nil)
        #expect(UpdateHTTP.secureURL("javascript:alert(1)") == nil)
        #expect(UpdateHTTP.secureURL("https:///no-host") == nil)
        let xml = appcast("""
        <item><sparkle:releaseNotesLink>file:///etc/hosts</sparkle:releaseNotesLink><link>http://example.com/notes</link>
          <enclosure url="http://example.com/Example-2.4.0.zip" sparkle:version="240" sparkle:shortVersionString="2.4.0"/></item>
        """)
        let update = SparkleSource.newestUpdate(for: app, appcast: xml)
        #expect(update?.latestVersion == "2.4.0")
        #expect(update?.downloadURL == nil && update?.releaseNotesURL == nil)
    }

    @Test func notAFeedIsAFailure() {
        #expect(SparkleSource.parseFeed(Data("<!DOCTYPE html><html><head><meta charset=utf-8></head><body>Not found".utf8)) == nil)
        #expect(SparkleSource.parseFeed(appcast("")) == [])
    }

    // MARK: Homebrew

    @Test func homebrewOutdatedParsing() throws {
        let json = #"""
        {"formulae":[{"name":"git","installed_versions":["2.56.0"],"current_version":"2.56.0_1","pinned":false},
                     {"name":"node","installed_versions":["20.1"],"current_version":"22.0","pinned":true}],
         "casks":[{"name":"rectangle","installed_versions":["0.80"],"current_version":"0.85"}]}
        """#
        let updates = try #require(HomebrewSource.parseOutdated(json))
        #expect(updates.count == 2)
        #expect(updates[0].origin == .homebrewFormula && updates[0].latestVersion == "2.56.0_1")
        #expect(updates[1].origin == .homebrewCask && updates[1].displayName == "rectangle")
        #expect(HomebrewSource.parseOutdated("Error: something broke") == nil)

        let info = #"""
        {"formulae":[],"casks":[{"token":"rectangle","full_token":"rectangle","name":["Rectangle"],
          "artifacts":[{"uninstall":[{"quit":"com.knollsoft.Rectangle"}]},{"app":["Rectangle.app"],"target":"/Applications/Rectangle.app"}]}]}
        """#
        let enriched = try #require(HomebrewSource.parseOutdated(json, casks: HomebrewSource.parseCaskInfo(info)))
        #expect(enriched[1].displayName == "Rectangle" && enriched[1].appURL?.path == "/Applications/Rectangle.app")
        #expect(enriched[1].identifier == "rectangle")
    }

    @Test func homebrewFailuresAreReported() async {
        #expect(await HomebrewSource(brewPath: "/usr/bin/false").checkForUpdates().failed == ["Homebrew"])
        #expect(await HomebrewSource(brewPath: "/bin/echo").checkForUpdates().failed == ["Homebrew"])   // not JSON
        #expect(await HomebrewSource(brewPath: nil).checkForUpdates().failed.isEmpty)                   // not installed
    }

    @Test func homebrewUpgradeIsJudgedByExitStatus() async {
        let cask = AvailableUpdate(identifier: "Error:", displayName: "x", installedVersion: "1", latestVersion: "2", origin: .homebrewCask)
        #expect(await HomebrewSource(brewPath: "/bin/echo").upgrade(cask).0)        // prints "Error:" but exits 0
        #expect(await !HomebrewSource(brewPath: "/usr/bin/false").upgrade(cask).0)
    }

    @Test func hungProcessIsStopped() async throws {
        let start = ContinuousClock.now
        let run = try #require(await HomebrewSource.run("/bin/sleep", ["30"], timeout: .milliseconds(300)))
        #expect(run.killed && run.status != 0)
        #expect(ContinuousClock.now - start < .seconds(10))
        let echo = try #require(await HomebrewSource.run("/bin/echo", ["hello"], timeout: .seconds(10)))
        #expect(echo.status == 0 && !echo.killed && echo.output == "hello\n")
    }

    // MARK: App Store

    @Test func appStoreLookupParsing() {
        let json = #"""
        {"resultCount":2,"results":[{"bundleId":"com.other.app","version":"9.9"},
                                    {"bundleId":"com.example.app","version":"2.5.1","trackViewUrl":"https://apps.apple.com/app/id1"}]}
        """#
        let update = AppStoreSource.update(for: app, lookup: Data(json.utf8))
        #expect(update?.latestVersion == "2.5.1" && update?.origin == .appStore)
        #expect(update?.releaseNotesURL?.host() == "apps.apple.com" && update?.downloadURL == nil)
        let older = #"{"resultCount":1,"results":[{"bundleId":"com.example.app","version":"2.3.0"}]}"#
        #expect(AppStoreSource.update(for: app, lookup: Data(older.utf8)) == nil)
        let otherApp = #"{"resultCount":1,"results":[{"bundleId":"com.other.app","version":"9.9"}]}"#
        #expect(AppStoreSource.update(for: app, lookup: Data(otherApp.utf8)) == nil)
    }

    @Test func appStoreLookupURL() throws {
        let url = AppStoreSource.lookupURL(bundleID: "com.example.a&b=c d", country: "gb")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.scheme == "https" && url.host() == "itunes.apple.com" && url.path == "/lookup")
        #expect(items.first { $0.name == "bundleId" }?.value == "com.example.a&b=c d")
        #expect(items.first { $0.name == "entity" }?.value == "macSoftware")
        #expect(items.first { $0.name == "country" }?.value == "gb")
    }

    // MARK: De-duplication

    @Test func oneRowPerApp() {
        let path = URL(filePath: "/Applications/Example.app")
        let updates = [
            AvailableUpdate(identifier: "com.example.app", displayName: "Example", installedVersion: "1", latestVersion: "2", origin: .sparkle, appURL: path),
            AvailableUpdate(identifier: "com.example.app", displayName: "Example", installedVersion: "1", latestVersion: "2", origin: .sparkle, appURL: path),
            AvailableUpdate(identifier: "example", displayName: "Example Pro", installedVersion: "1", latestVersion: "2", origin: .homebrewCask, appURL: path),
            AvailableUpdate(identifier: "visual-studio-code", displayName: "Microsoft Visual Studio Code", installedVersion: "1", latestVersion: "2", origin: .homebrewCask),
            AvailableUpdate(identifier: "com.microsoft.VSCode", displayName: "Visual Studio Code", installedVersion: "1", latestVersion: "2", origin: .sparkle,
                            appURL: URL(filePath: "/Applications/Visual Studio Code.app")),
            AvailableUpdate(identifier: "com.store.app", displayName: "Store", installedVersion: "1", latestVersion: "2", origin: .sparkle),
            AvailableUpdate(identifier: "com.store.app", displayName: "Store", installedVersion: "1", latestVersion: "2", origin: .appStore),
            AvailableUpdate(identifier: "rectangle", displayName: "Rectangle", installedVersion: "1", latestVersion: "2", origin: .homebrewCask),
            AvailableUpdate(identifier: "git", displayName: "git", installedVersion: "1", latestVersion: "2", origin: .homebrewFormula),
        ]
        let kept = UpdateManager.deduplicated(updates).map(\.id)
        #expect(kept == ["sparkle:com.example.app", "sparkle:com.microsoft.VSCode", "appStore:com.store.app", "homebrewCask:rectangle", "homebrewFormula:git"])
    }
}
