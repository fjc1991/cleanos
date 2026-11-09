import Foundation
import Testing
@testable import CleanCore

@Suite struct DuplicateFinderTests {
    static func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "Dupes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var options: DuplicateFinder.Options {
        var o = DuplicateFinder.Options()
        o.minimumSize = 0
        return o
    }

    @Test func hardLinksAreNotDuplicates() async throws {
        let fm = FileManager.default
        let root = try Self.makeDir()
        defer { try? fm.removeItem(at: root) }
        let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try content.write(to: root.appending(path: "original.bin"))
        try fm.createDirectory(at: root.appending(path: "elsewhere"), withIntermediateDirectories: true)
        try fm.linkItem(at: root.appending(path: "original.bin"), to: root.appending(path: "elsewhere/link.bin"))
        try content.write(to: root.appending(path: "real copy.bin"))

        let finder = DuplicateFinder()
        let groups = await finder.find(roots: [root], options: Self.options)
        #expect(groups.count == 1)
        #expect(groups.first?.files.count == 2)                                  // one of the two links, plus the real copy
        #expect(groups.first?.files.contains { $0.title == "real copy.bin" } == true)
        #expect(groups.first?.wastedBytes == 300_000)
        #expect(await finder.lastStats.hardLinksCollapsed == 1)

        // Only links of one file: nothing to report.
        try fm.removeItem(at: root.appending(path: "real copy.bin"))
        #expect(await finder.find(roots: [root], options: Self.options).isEmpty)
        // The same folder given twice is one set of files, not a set of duplicates.
        #expect(await finder.find(roots: [root, root.appending(path: "elsewhere")], options: Self.options).isEmpty)
    }

    @Test func emptyFilesAreNotDuplicates() async throws {
        let fm = FileManager.default
        let root = try Self.makeDir()
        defer { try? fm.removeItem(at: root) }
        for name in ["a", "b", "c"] { try Data().write(to: root.appending(path: "\(name).txt")) }
        let finder = DuplicateFinder()
        #expect(await finder.find(roots: [root], options: Self.options).isEmpty)
        #expect(await finder.lastStats.filesConsidered == 0)
    }

    @Test func placeholdersAreNeverRead() {
        #expect(DuplicateFinder.isPlaceholder(flags: 0x4000_0000, downloadingStatus: nil))                 // SF_DATALESS
        #expect(DuplicateFinder.isPlaceholder(flags: 0x4000_0000 | 0x20, downloadingStatus: nil))
        #expect(DuplicateFinder.isPlaceholder(flags: 0, downloadingStatus: .notDownloaded))
        #expect(DuplicateFinder.isPlaceholder(flags: 0, downloadingStatus: .downloaded))                   // a newer version is in iCloud
        #expect(!DuplicateFinder.isPlaceholder(flags: 0, downloadingStatus: .current))
        #expect(!DuplicateFinder.isPlaceholder(flags: 0, downloadingStatus: nil))                          // not an iCloud item
        #expect(!DuplicateFinder.isPlaceholder(flags: UInt32(UF_HIDDEN), downloadingStatus: nil))
    }
}

@Suite struct WalkCancellationTests {
    @Test func cancellingTheCallerStopsTheWalks() async throws {
        let fm = FileManager.default
        let home = try DuplicateFinderTests.makeDir()
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home.appending(path: "Movies"), withIntermediateDirectories: true)
        try Data(repeating: 3, count: 2_000_000).write(to: home.appending(path: "Movies/big.mov"))
        try Data(repeating: 3, count: 2_000_000).write(to: home.appending(path: "Movies/big copy.mov"))
        let largeOptions = { var o = LargeFilesScanner.Options(); o.minimumSize = 1_000_000; return o }()
        let duplicateOptions = { var o = DuplicateFinder.Options(); o.minimumSize = 1000; return o }()

        // Each walk runs in a task that is already cancelled: a detached walk would not notice and return everything.
        let large = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LargeFilesScanner().scan(roots: [home], options: largeOptions)
        }.value
        #expect(large.isEmpty)
        let categories = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await FileCategoriesScanner().scan(home: home, includeSystem: false)
        }.value
        #expect(categories.total("movies") == 0)
        let finder = DuplicateFinder()
        let groups = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await finder.find(roots: [home], options: duplicateOptions)
        }.value
        #expect(groups.isEmpty)
        #expect(await finder.lastStats.filesConsidered == 0)

        // The same calls without cancellation find everything.
        #expect(await LargeFilesScanner().scan(roots: [home], options: largeOptions).count == 2)
        #expect(await FileCategoriesScanner().scan(home: home, includeSystem: false).total("movies") >= 4_000_000)
        #expect(await finder.find(roots: [home], options: duplicateOptions).count == 1)
        #expect(await finder.lastStats.filesConsidered == 2)
    }
}
