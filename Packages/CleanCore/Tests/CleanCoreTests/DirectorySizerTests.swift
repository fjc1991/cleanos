import Foundation
import Testing
@testable import CleanCore

@Suite struct DirectorySizerTests {
    func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "CleanCoreTests-\(UUID().uuidString)")
        let nested = root.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: root.appending(path: "a.bin"))
        try Data(repeating: 2, count: 20_000).write(to: nested.appending(path: "b.bin"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: nested)
        return root
    }

    @Test func countsFilesAndFoldersWithoutFollowingSymlinks() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = DirectorySizer.size(of: root)
        #expect(result.directoryCount == 2)          // root + nested
        #expect(result.fileCount == 3)               // a.bin, b.bin, the symlink itself
        #expect(result.bytes >= 30_000)
        #expect(result.bytes < 30_000 + 3 * 8_192)   // allocated size rounds up per file
    }

    @Test func singleFile() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = DirectorySizer.size(of: root.appending(path: "a.bin"))
        #expect(result.fileCount == 1 && result.directoryCount == 0 && result.bytes >= 10_000)
    }

    @Test func concurrentSizes() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = [root.appending(path: "a.bin"), root.appending(path: "nested"), root]
        let sizes = await DirectorySizer.sizes(of: urls, maxConcurrency: 2)
        #expect(sizes.count == 3)
        #expect(sizes[root]!.bytes >= sizes[root.appending(path: "nested")]!.bytes)
    }

    @Test func sizeCacheReturnsSameResult() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SizeCache()
        let first = await cache.size(of: root)
        let second = await cache.size(of: root)
        #expect(first == second)
        #expect(await cache.cached(root) == first)
    }

    @Test func sizeCacheExpiresCachedEntriesLikeSize() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SizeCache(maxAge: 0)
        _ = await cache.size(of: root)
        #expect(await cache.cached(root) == nil)   // older than maxAge: size(of:) would measure again, so cached() has nothing
    }

    @Test func hardLinkedFilesCountOnce() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "HardLinks-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appending(path: "other"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let original = root.appending(path: "a.bin")
        try Data(repeating: 1, count: 100_000).write(to: original)
        try fm.linkItem(at: original, to: root.appending(path: "other/a-link.bin"))
        try fm.linkItem(at: original, to: root.appending(path: "a-link2.bin"))
        let single = DirectorySizer.size(of: original)
        let result = DirectorySizer.size(of: root)
        #expect(result.fileCount == 1)
        #expect(result.bytes == single.bytes)
        #expect(result.directoryCount == 2)
    }

    @Test func unreadableFoldersAreCounted() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "Denied-\(UUID().uuidString)")
        let locked = root.appending(path: "locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000).write(to: locked.appending(path: "hidden.bin"))
        try Data(repeating: 1, count: 1000).write(to: root.appending(path: "visible.bin"))
        #expect(chmod(locked.path, 0) == 0)
        defer { chmod(locked.path, 0o700); try? fm.removeItem(at: root) }
        let result = DirectorySizer.size(of: root)
        #expect(result.deniedDirectoryCount == 1)
        #expect(result.fileCount == 1)
        #expect(DirectorySizer.size(of: root.appending(path: "visible.bin")).deniedDirectoryCount == 0)
    }

    @Test func walkStopsAtMountBoundaries() {
        // Same device: always entered, unless excluded.
        #expect(DirectorySizer.mayDescend(into: "/System/Library", device: 1, rootDevice: 1, mountPoint: nil, excluded: []))
        #expect(!DirectorySizer.mayDescend(into: "/System/Volumes", device: 1, rootDevice: 1, mountPoint: nil, excluded: ["/System/Volumes"]))
        // Another device whose mount point is this folder: a mounted volume, never entered.
        #expect(!DirectorySizer.mayDescend(into: "/System/Volumes/Data", device: 2, rootDevice: 1, mountPoint: "/System/Volumes/Data", excluded: []))
        #expect(!DirectorySizer.mayDescend(into: "/Users/me/mnt", device: 3, rootDevice: 1, mountPoint: "/Users/me/mnt", excluded: []))
        // Another device mounted elsewhere: a firmlink into a sibling volume (/usr/local), followed.
        #expect(DirectorySizer.mayDescend(into: "/usr/local", device: 2, rootDevice: 1, mountPoint: "/System/Volumes/Data", excluded: []))
        // Unknown mount point on another device: treated as a boundary.
        #expect(!DirectorySizer.mayDescend(into: "/Volumes/X", device: 4, rootDevice: 1, mountPoint: nil, excluded: []))
        #expect(DirectorySizer.mountPoint(of: "/") == "/")
    }

    @Test func sizeResultDecodesWithoutDeniedCount() throws {
        let old = #"{"bytes":10,"fileCount":1,"directoryCount":0}"#
        let decoded = try JSONDecoder().decode(SizeResult.self, from: Data(old.utf8))
        #expect(decoded == SizeResult(bytes: 10, fileCount: 1, directoryCount: 0))
    }
}
