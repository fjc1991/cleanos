import Foundation
import Testing
@testable import UpdateSources

/// Answers every request from a fixed script, so no test touches the network. The first part of the host (for feeds)
/// or of the bundle ID (for App Store lookups) picks the answer: `offline`, `limited` (429), `missing` (404),
/// `empty` (no results outside the US storefront) or anything else for a valid response offering version 9.0.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let log = RequestLog()

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.log.append(url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let isLookup = url.host() == "itunes.apple.com"
        let key = isLookup ? query.first { $0.name == "bundleId" }?.value ?? "" : url.host() ?? ""
        let country = query.first { $0.name == "country" }?.value
        if key.hasPrefix("offline") {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let status = key.hasPrefix("limited") ? 429 : key.hasPrefix("missing") ? 404 : 200
        let body = !isLookup ? """
            <?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
            <item><enclosure url="https://\(key)/9.0.zip" sparkle:version="900" sparkle:shortVersionString="9.0"/></item></channel></rss>
            """ : key.hasPrefix("empty") && country != "us" ? #"{"resultCount":0,"results":[]}"#
            : #"{"resultCount":1,"results":[{"bundleId":"\#(key)","version":"9.0"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) { lock.withLock { urls.append(url) } }
    func count(containing text: String) -> Int { lock.withLock { urls.filter { $0.absoluteString.contains(text) }.count } }
}

@Suite struct ManagerTests {
    func sparkleApp(_ host: String) -> UpdatableApp {
        UpdatableApp(bundleID: "com.\(host)", name: host, appURL: URL(filePath: "/Applications/\(host).app"), shortVersion: "1.0", buildVersion: "100",
                     sparkleFeedURL: URL(string: "https://\(host)/appcast.xml"), hasMASReceipt: false)
    }
    func storeApp(_ bundleID: String) -> UpdatableApp {
        UpdatableApp(bundleID: bundleID, name: bundleID, appURL: URL(filePath: "/Applications/\(bundleID).app"), shortVersion: "1.0", buildVersion: "100",
                     sparkleFeedURL: nil, hasMASReceipt: true)
    }
    func temporaryCache() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "UpdateSourcesTests-\(UUID().uuidString)/Updates.json")
    }

    @Test func offlineCheckIsReportedAndNotCached() async {
        let cache = temporaryCache()
        let manager = UpdateManager(cacheFile: cache, session: StubURLProtocol.session)
        let snapshot = await manager.check(apps: [sparkleApp("offline-feed.test"), storeApp("offline.manager.app")], includeHomebrew: false)
        #expect(snapshot.isOffline && snapshot.updates.isEmpty)
        #expect(Set(snapshot.failed) == ["offline-feed.test", "offline.manager.app"])
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(await manager.cached() == nil)
    }

    @Test func partialFailureIsCachedWithTheFailures() async throws {
        let cache = temporaryCache()
        let manager = UpdateManager(cacheFile: cache, session: StubURLProtocol.session)
        let snapshot = await manager.check(apps: [sparkleApp("missing-feed.test"), storeApp("ok.partial.app")], includeHomebrew: false)
        #expect(!snapshot.isOffline && snapshot.failed == ["missing-feed.test"])
        #expect(snapshot.updates.map(\.id) == ["appStore:ok.partial.app"])
        let cached = try #require(await manager.cached())
        #expect(cached.failed == ["missing-feed.test"] && cached.updates.count == 1)
    }

    @Test func appliedUpdateLeavesTheCache() async throws {
        let cache = temporaryCache()
        let manager = UpdateManager(cacheFile: cache, session: StubURLProtocol.session)
        let snapshot = await manager.check(apps: [sparkleApp("ok-feed.test"), storeApp("ok.applied.app")], includeHomebrew: false)
        #expect(snapshot.failed.isEmpty && snapshot.updates.count == 2)
        #expect(snapshot.updates.first { $0.origin == .sparkle }?.latestVersion == "9.0")
        await manager.remove(updateID: "appStore:ok.applied.app")
        let cached = try #require(await manager.cached())
        #expect(cached.updates.map(\.id) == ["sparkle:com.ok-feed.test"])
    }

    @Test func appStoreBacksOffWhenRateLimited() async {
        let apps = (1...8).map { storeApp("limited.backoff.\($0)") }
        let result = await AppStoreSource(apps: apps, session: StubURLProtocol.session, country: "us").checkForUpdates()
        #expect(result.failed.count == 8 && result.updates.isEmpty && !result.isOffline)
        #expect(StubURLProtocol.log.count(containing: "limited.backoff.") == 4)   // only the first batch went out
    }

    @Test func appStoreFallsBackToTheUSStorefront() async {
        let result = await AppStoreSource(apps: [storeApp("empty.retry.app")], session: StubURLProtocol.session, country: "gb").checkForUpdates()
        #expect(result.updates.map(\.latestVersion) == ["9.0"] && result.failed.isEmpty)
        #expect(StubURLProtocol.log.count(containing: "bundleId=empty.retry.app") == 2)
    }
}
