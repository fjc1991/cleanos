import Foundation
import Testing
@testable import CleanCore

/// The catalog lists every bundle once, however many ways it can be reached.
@Suite struct AppCatalogDedupeTests {
    @Test func symlinkedBundleIsListedOnceUnderItsRealPath() throws {
        let home = FixtureHome("CatalogDedupe")
        defer { home.remove() }
        try home.file("Apps/Real.app/Contents/Info.plist", try LeftoverLocatorTests.plist(["CFBundleIdentifier": "com.example.real"]))
        try home.dir("Links")
        try FileManager.default.createSymbolicLink(at: home.url.appending(path: "Links/Real.app"), withDestinationURL: home.url.appending(path: "Apps/Real.app"))
        // The link's folder is scanned first; the real path still wins.
        let found = AppCatalog.findAppBundles(in: [home.url.appending(path: "Links"), home.url.appending(path: "Apps")], skipList: [])
        #expect(found.count == 1)
        #expect(found.first?.standardizedFileURL.path == home.p("Apps/Real.app"))
        // Only the link: listed once, as found.
        let linkOnly = AppCatalog.findAppBundles(in: [home.url.appending(path: "Links"), home.url.appending(path: "Links")], skipList: [])
        #expect(linkOnly.count == 1)
    }

    @Test func skipListMatchesWholePathComponents() throws {
        let home = FixtureHome("CatalogSkip")
        defer { home.remove() }
        try home.dir("Apps/Foobar.app/Contents")
        try home.dir("Apps/Foo/Inner.app/Contents")
        let apps = home.url.appending(path: "Apps")
        let notSkipped = AppCatalog.findAppBundles(in: [apps], skipList: [home.p("Apps/Foo")]).map { $0.standardizedFileURL.path }
        #expect(notSkipped == [home.p("Apps/Foobar.app")])
        #expect(AppCatalog.findAppBundles(in: [apps], skipList: [home.p("Apps/Foobar.app") + "/"]).map { $0.standardizedFileURL.path } == [home.p("Apps/Foo/Inner.app")])
    }
}
