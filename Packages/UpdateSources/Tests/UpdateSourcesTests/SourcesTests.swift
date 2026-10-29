import Foundation
import Testing
@testable import UpdateSources

@Suite struct SourcesTests {
    let app = UpdatableApp(bundleID: "com.example.app", name: "Example", appURL: URL(filePath: "/Applications/Example.app"),
                           shortVersion: "2.3.0", buildVersion: "230", sparkleFeedURL: URL(string: "https://example.com/appcast.xml"), hasMASReceipt: true)

    @Test func sparkleAppcastPicksNewestCompatibleItem() {
        let xml = """
        <?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
        <item><title>Version 2.4.0</title><sparkle:releaseNotesLink>https://example.com/notes/2.4</sparkle:releaseNotesLink>
          <enclosure url="https://example.com/Example-2.4.0.zip" sparkle:version="240" sparkle:shortVersionString="2.4.0"/></item>
        <item><title>Version 3.0.0</title><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/Example-3.0.0.zip" sparkle:version="300" sparkle:shortVersionString="3.0.0"/></item>
        <item><title>Version 2.3.0</title><enclosure url="https://example.com/Example-2.3.0.zip" sparkle:version="230" sparkle:shortVersionString="2.3.0"/></item>
        </channel></rss>
        """
        let update = SparkleSource.newestUpdate(for: app, appcast: Data(xml.utf8))
        #expect(update?.latestVersion == "2.4.0")
        #expect(update?.downloadURL?.lastPathComponent == "Example-2.4.0.zip")
        #expect(update?.releaseNotesURL?.path == "/notes/2.4")
        let upToDate = UpdatableApp(bundleID: "x", name: "x", appURL: app.appURL, shortVersion: "2.4.0", buildVersion: "240", sparkleFeedURL: nil, hasMASReceipt: false)
        #expect(SparkleSource.newestUpdate(for: upToDate, appcast: Data(xml.utf8)) == nil)
    }

    @Test func homebrewOutdatedParsing() {
        let json = #"{"formulae":[{"name":"git","installed_versions":["2.56.0"],"current_version":"2.56.0_1","pinned":false}],"casks":[{"name":"rectangle","installed_versions":["0.80"],"current_version":"0.85"}]}"#
        let updates = HomebrewSource.parseOutdated(json)
        #expect(updates.count == 2)
        #expect(updates[0].origin == .homebrewFormula && updates[0].latestVersion == "2.56.0_1")
        #expect(updates[1].origin == .homebrewCask && updates[1].displayName == "rectangle")
    }

    @Test func appStoreLookupParsing() {
        let json = #"{"resultCount":1,"results":[{"version":"2.5.1","trackViewUrl":"https://apps.apple.com/app/id1"}]}"#
        let update = AppStoreSource.update(for: app, lookup: Data(json.utf8))
        #expect(update?.latestVersion == "2.5.1" && update?.origin == .appStore)
        let older = #"{"resultCount":1,"results":[{"version":"2.3.0"}]}"#
        #expect(AppStoreSource.update(for: app, lookup: Data(older.utf8)) == nil)
    }
}
