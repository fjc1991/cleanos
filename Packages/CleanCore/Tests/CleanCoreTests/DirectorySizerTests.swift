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
}
