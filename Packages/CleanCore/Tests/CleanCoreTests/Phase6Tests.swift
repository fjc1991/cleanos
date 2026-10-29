import Foundation
import Testing
@testable import CleanCore

@Suite struct Phase6Tests {
    @Test func processSnapshotIncludesThisProcess() {
        let processes = ProcessMonitor.snapshot()
        #expect(processes.contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
        let grouped = ProcessMonitor.groupByApp(processes, includeOthers: true)
        #expect(!grouped.isEmpty)
        #expect(grouped.contains { $0.name == "System processes" })
    }

    @Test func largeFilesAndCategoriesAndDuplicates() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "P6Home-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        func file(_ p: String, bytes: Int, fill: UInt8 = 7) throws {
            try fm.createDirectory(at: home.appending(path: p).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: fill, count: bytes).write(to: home.appending(path: p))
        }
        try file("Movies/big.mov", bytes: 3_000_000)
        try file("Documents/report.pdf", bytes: 200_000)
        try file("Documents/copy of report.pdf", bytes: 200_000)         // duplicate
        try file("Music/track.mp3", bytes: 200_000, fill: 9)              // same size, different content
        try file("Pictures/photo.jpg", bytes: 150_000)
        try file("Downloads/archive.zip", bytes: 120_000)
        try file("Desktop/tiny.txt", bytes: 10)

        let large = await LargeFilesScanner().scan(roots: [home], options: { var o = LargeFilesScanner.Options(); o.minimumSize = 1_000_000; return o }())
        #expect(large.map(\.title) == ["big.mov"])
        #expect(large.first?.payload["kind"] != nil)

        let categories = await FileCategoriesScanner().scan(home: home, includeSystem: false)
        #expect(categories.total("movies") >= 3_000_000)
        #expect(categories.total("documents") >= 400_000)
        #expect(categories.total("music") >= 200_000)
        #expect(categories.total("pictures") >= 150_000)
        #expect(categories.total("archives") >= 120_000)
                #expect(categories.homeFolders.first?.title == "Movies")
        #expect(categories.categories.first { $0.id == "documents" }?.items.count == 3)   // two PDFs + tiny.txt

        let groups = await DuplicateFinder().find(roots: [home], options: { var o = DuplicateFinder.Options(); o.minimumSize = 1000; return o }())
        #expect(groups.count == 1)
        #expect(Set(groups[0].files.map(\.title)) == ["report.pdf", "copy of report.pdf"])
        #expect(groups[0].wastedBytes == 200_000)
        let selection = DuplicateFinder.smartSelection(groups)
        #expect(selection.count == 1)
    }

    @Test func maintenanceWithoutHelperReportsNeedForPrivileges() async {
        let runner = MaintenanceRunner()
        #expect(await runner.run(.optimizeRAM) != nil || FileRemover.isDryRun)
    }
}
