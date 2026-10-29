import Foundation
import Testing
@testable import CleanCore

@Suite struct CleanupTests {
    static func makeHome() throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "CleanupHome-\(UUID().uuidString)")
        func dir(_ p: String) throws { try fm.createDirectory(at: home.appending(path: p), withIntermediateDirectories: true) }
        func file(_ p: String, size: Int = 10) throws {
            try fm.createDirectory(at: home.appending(path: p).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0, count: size).write(to: home.appending(path: p))
        }
        try file("Downloads/Installer.dmg", size: 5000)
        try file("Downloads/notes.txt")
        try file("Desktop/Screenshot 2026-10-13 at 09.00.00.png", size: 2000)
        try file("Desktop/photo.png")
        try file("Documents/deep/Tool.pkg", size: 3000)
        try file(".Trash/old.zip", size: 4000)
        try file("Library/Caches/com.example.fakeapp/blob", size: 1000)
        try file("Library/Caches/com.other.thing/blob", size: 500)
        try file("Library/Logs/Fake App/log.txt", size: 100)
        try file("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/attachment.pdf", size: 700)
        try file("Library/Developer/Xcode/DerivedData/Proj-abc/Build/x.o", size: 800)
        try file("Applications/Fake App.app/Contents/Resources/de.lproj/Localizable.strings")
        try file("Applications/Fake App.app/Contents/Resources/en.lproj/Localizable.strings")
        try file("Applications/Fake App.app/Contents/Resources/fr.lproj/Localizable.strings")
        return home
    }

    static func fakeApp(home: URL) -> InstalledApp {
        InstalledApp(url: home.appending(path: "Applications/Fake App.app"), name: "Fake App", bundleID: "com.example.fakeapp", version: "1", build: "1",
                     isSystem: false, modificationDate: nil, creationDate: nil, lastOpenedDate: nil,
                     identity: AppIdentity(bundleID: "com.example.fakeapp", name: "Fake App", fileName: "Fake App", executable: "FakeApp"))
    }

    @Test func scannersFindTheirCategories() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let context = CleanupContext(home: home.path, volumes: [], enabledVolumeIDs: [], installedApps: [Self.fakeApp(home: home)],
                                     runningBundleIDs: [], rules: .bundled, preferredLanguages: ["en-GB"])
        let engine = CleanupEngine()

        let installers = await engine.scan(categoryID: "installers", context: context)!
        #expect(Set(installers.items.map(\.title)) == ["Installer.dmg", "Tool.pkg"])
        #expect(installers.items.allSatisfy { $0.tier == .normal })

        let screenshots = await engine.scan(categoryID: "screenshots", context: context)!
        #expect(screenshots.items.map(\.title) == ["Screenshot 2026-10-13 at 09.00.00.png"])

        let downloads = await engine.scan(categoryID: "downloads", context: context)!
        #expect(downloads.items.count == 2 && downloads.items.allSatisfy { $0.tier == .caution })

        let mail = await engine.scan(categoryID: "mail", context: context)!
        #expect(mail.items.map(\.title) == ["attachment.pdf"])

        let xcode = await engine.scan(categoryID: "xcode", context: context)!
        #expect(xcode.items.first?.title == "Derived data")
        #expect(xcode.items.first?.children.first?.title == "Proj-abc")

        let languages = await engine.scan(categoryID: "languages", context: context)!
        #expect(languages.items.count == 1)
        #expect(Set(languages.items[0].children.map(\.title)) == ["de.lproj", "fr.lproj"])
        #expect(languages.items[0].children.allSatisfy { $0.tier == .caution })

        let caches = await engine.scan(categoryID: "caches", context: context)!
        let titles = caches.items.map(\.title)
        #expect(titles.contains("Fake App cache files"))
        #expect(titles.contains("Applications' caches"))
        #expect(titles.contains("Applications' logs"))
        let fake = caches.items.first { $0.title == "Fake App cache files" }
        #expect(fake?.payload["iconPath"]?.hasSuffix("Fake App.app") == true)
        #expect(fake?.children.first?.url?.lastPathComponent == "com.example.fakeapp")
        #expect(caches.totalSize > 0)
    }

    @Test func trashScannerUsesVolumeScope() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = VolumeInfo(id: "root", url: URL(filePath: "/"), name: "Macintosh HD", format: "APFS", isInternal: true, isRemovable: false,
                              isEjectable: false, isLocal: true, isRoot: true, totalCapacity: 100, availableCapacity: 50, availableForImportantUsage: 60)
        let context = CleanupContext(home: home.path, volumes: [root], enabledVolumeIDs: [], installedApps: [], rules: .bundled)
        let trash = await CleanupEngine().scan(categoryID: "trash", context: context)!
        #expect(trash.items.count == 1)
        #expect(trash.items[0].children.map(\.title) == ["old.zip"])
        #expect(trash.items[0].children[0].payload["permanent"] == "1")
        let plan = RemovalPlan(selected: trash.items, permanently: false)
        #expect(plan.userItems.count == 1)

        let purgeable = await CleanupEngine().scan(categoryID: "purgeable", context: context)!
        #expect(purgeable.items.first?.children.isEmpty == true)            // 10 bytes is below the 50 MB threshold for a reclaim action
        #expect(purgeable.items.first?.subtitle?.contains("purgeable") == true)
    }

    @Test func memoryStatsAreSane() {
        let stats = MemoryStats.current()
        #expect(stats != nil)
        #expect((stats?.total ?? 0) > 1_000_000_000)
        #expect((stats?.usedFraction ?? 0) > 0 && (stats?.usedFraction ?? 2) <= 1)
    }
}

@Suite struct PurgeableTests {
    @Test func dryRunReclaimDoesNotWrite() throws {
        do {
            let report = try PurgeableReclaimer.reclaim(mount: "/", dryRun: true)
            #expect(report.written == 0)
            #expect(report.purgeableBefore == report.purgeableAfter)
        } catch PurgeableReclaimer.ReclaimError.nothingToReclaim {
            // A volume without purgeable space is a valid outcome.
        }
    }

    @Test func scannerOffersReclaimActionWhenPurgeable() async {
        let root = VolumeInfo(id: "root", url: URL(filePath: "/"), name: "Macintosh HD", format: "APFS", isInternal: true, isRemovable: false,
                              isEjectable: false, isLocal: true, isRoot: true, totalCapacity: 1_000_000_000_000, availableCapacity: 10_000_000_000,
                              availableForImportantUsage: 13_000_000_000)
        let context = CleanupContext(volumes: [root], enabledVolumeIDs: [], installedApps: [], rules: .bundled)
        let result = await CleanupEngine().scan(categoryID: "purgeable", context: context)!
        let action = result.items.first?.children.first { $0.payload["type"] == "purge" }
        #expect(action != nil)
        #expect(action?.size == 3_000_000_000)
        #expect(action?.tier == .normal && action?.needsRoot == false)
        let plan = RemovalPlan(selected: result.items, permanently: false)
        #expect(plan.registrations.contains { $0.payload["type"] == "purge" })
    }
}

@Suite struct PurgeSmokeTests {
    /// Actually reclaims purgeable space on the startup disk. Enabled only with CLEANOS_SMOKE_PURGE=1 (fills the disk for a few seconds).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLEANOS_SMOKE_PURGE"] == "1"))
    func reclaimOnStartupDisk() throws {
        let report = try PurgeableReclaimer.reclaim(mount: "/") { written in if written % (1024 * 1024 * 1024) < 64 * 1024 * 1024 { print("SMOKE: wrote \(written.formattedBytes)") } }
        print("SMOKE: purge wrote \(report.written.formattedBytes) in \(String(format: "%.1f", report.duration))s; purgeable \(report.purgeableBefore.formattedBytes) → \(report.purgeableAfter.formattedBytes); available \(report.availableBefore.formattedBytes) → \(report.availableAfter.formattedBytes); purged \(report.purged.formattedBytes)")
    }
}


@Suite struct FileProtectionTests {
    @Test func immutableAndUnreadableFoldersAreProtected() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "Protect-\(UUID().uuidString)")
        let locked = base.appending(path: "locked")
        let dark = base.appending(path: "dark")
        let plain = base.appending(path: "plain")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.createDirectory(at: dark, withIntermediateDirectories: true)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { chflags(locked.path, 0); chmod(dark.path, 0o700); try? fm.removeItem(at: base) }
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(chmod(dark.path, 0) == 0)
        #expect(FileProtection.classify(locked) == .immutable)
        #expect(FileProtection.classify(dark) == .unreadable)
        #expect(FileProtection.classify(plain) == .none)
        // A plain folder holding a locked item cannot be emptied, so it is protected too; a stat that is refused counts as a vault.
        let holder = base.appending(path: "holder")
        try fm.createDirectory(at: holder.appending(path: "inner"), withIntermediateDirectories: true)
        defer { chflags(holder.appending(path: "inner").path, 0) }
        chflags(holder.appending(path: "inner").path, UInt32(UF_IMMUTABLE))
        #expect(FileProtection.classify(holder) == .containsProtected)
        #expect(FileProtection.classify(dark.appending(path: "ghost")) == .dataVault)
        #expect(!FileRemover.isUserRemovable(locked))
        #expect(FileRemover.isUserRemovable(plain))
    }

    @Test func removalRefusesProtectedItems() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "ProtectRemove-\(UUID().uuidString)")
        let locked = base.appending(path: "locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        defer { chflags(locked.path, 0); try? fm.removeItem(at: base) }
        chflags(locked.path, UInt32(UF_IMMUTABLE))
        let item = ScanItem(url: locked, title: "locked", kind: .directory, group: "Caches", size: 0, tier: .safe)
        let result = await RemovalExecutor(journal: RemovalJournal(directory: base.appending(path: "Journal"))).execute(RemovalPlan(selected: [item], permanently: false), title: "t", appVersion: "t")
        #expect(result.failed.count == 1 && result.succeeded.isEmpty)
        #expect(fm.fileExists(atPath: locked.path))
    }

    @Test func appleSystemCachesAreCautionOrSkipped() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "AppleCaches-\(UUID().uuidString)")
        for name in ["com.apple.quicklook.ThumbnailsAgent", "com.apple.akd", "com.apple.Safari", "com.apple.somethingelse", "com.vendor.app"] {
            try fm.createDirectory(at: home.appending(path: "Library/Caches/\(name)"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: home.appending(path: "Library/Caches/\(name)/blob"))
        }
        defer { try? fm.removeItem(at: home) }
        let result = await CleanupEngine().scan(categoryID: "caches", context: CleanupContext(home: home.path, volumes: [], rules: .bundled))!
        let leaves = result.items.flatMap(\.leaves)
        #expect(!leaves.contains { $0.title == "com.apple.quicklook.ThumbnailsAgent" })
        #expect(!leaves.contains { $0.title == "com.apple.akd" })
        #expect(leaves.first { $0.title == "com.apple.Safari" }?.tier == .safe)
        #expect(leaves.first { $0.title == "com.apple.somethingelse" }?.tier == .caution)
        #expect(leaves.first { $0.title == "com.vendor.app" }?.tier == .safe)
    }
}
