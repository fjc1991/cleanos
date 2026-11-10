import Foundation
import Testing
@testable import CleanCore

/// Pre-selection and scope rules of the Clean Up scanners, on temporary fixtures only.
@Suite struct ScannerSafetyTests {
    static let gb: Int64 = 1024 * 1024 * 1024

    /// A temporary folder with symlinks resolved, so paths the scanners build and paths the tests build compare equal.
    static func makeDir(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    static func file(_ base: URL, _ path: String, size: Int = 10, fill: UInt8 = 0) throws {
        let url = base.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: size).write(to: url)
    }

    static func root(available: Int64, important: Int64) -> VolumeInfo {
        VolumeInfo(id: "root", url: URL(filePath: "/"), name: "Macintosh HD", format: "APFS", isInternal: true, isRemovable: false,
                   isEjectable: false, isLocal: true, isRoot: true, totalCapacity: 1000 * gb, availableCapacity: available,
                   availableForImportantUsage: important)
    }

    static func external(_ url: URL, id: String = "usb", format: String = "ExFAT", readOnly: Bool = false) -> VolumeInfo {
        VolumeInfo(id: id, url: url, name: "USB \(id)", format: format, isInternal: false, isRemovable: true, isEjectable: true, isLocal: true,
                   isRoot: false, totalCapacity: 100 * gb, availableCapacity: 50 * gb, availableForImportantUsage: 50 * gb, isReadOnly: readOnly)
    }

    // MARK: - Default selection invariant

    @Test func nothingRiskyIsPreselected() async throws {
        let fm = FileManager.default
        let home = try Self.makeDir("SafetyHome")
        let disk = try Self.makeDir("SafetyDisk")
        defer { try? fm.removeItem(at: home); try? fm.removeItem(at: disk) }
        try Self.file(home, "Desktop/Screenshot 2026-11-09 at 10.00.00.png", size: 2000)
        try Self.file(home, "Downloads/Installer.dmg", size: 5000)
        try Self.file(home, "Downloads/ubuntu.iso", size: 5000)
        try Self.file(home, "Documents/backup.sparseimage", size: 5000)   // a user's disk image: never offered
        try Self.file(home, "Documents/old.iso", size: 5000)
        try Self.file(home, "Documents/report.pdf", size: 3000)
        try Self.file(home, ".ssh/id_ed25519", size: 400)
        try Self.file(disk, "photo.jpg", size: 3000)
        try Self.file(disk, "._photo.jpg", size: 4096)                     // holds photo.jpg's metadata: never offered
        try Self.file(disk, "._gone.jpg", size: 4096)                      // its file is gone: offered, not pre-selected
        try Self.file(disk, ".DS_Store", size: 600)
        try Self.file(disk, ".DocumentRevisions-V100/store/1.db", size: 5000)
        try Self.file(disk, "disk.iso", size: 5000)
        try Self.file(disk, "Setup.dmg", size: 5000)
        try Self.file(disk, "$RECYCLE.BIN/S-1-5-21-1/$Rabc.txt", size: 700)

        let volumes = [Self.root(available: 10 * Self.gb, important: 13 * Self.gb), Self.external(disk)]
        let context = CleanupContext(home: home.path, volumes: volumes, enabledVolumeIDs: ["usb"], installedApps: [], rules: .bundled, preferredLanguages: ["en"])
        let engine = CleanupEngine()
        var preselected: [(category: String, item: ScanItem)] = []
        var results: [String: CleanupResult] = [:]
        for id in ["installers", "screenshots", "purgeable", "externalJunk", "trash"] {
            let result = try #require(await engine.scan(categoryID: id, context: context))
            results[id] = result
            preselected += result.items.flatMap(\.leaves).filter { $0.tier.isSelectableByDefault }.map { (id, $0) }
        }
        let homeFolders = await FileCategoriesScanner().scan(home: home, includeSystem: false).homeFolders
        preselected += homeFolders.filter { $0.tier.isSelectableByDefault }.map { ("home", $0) }

        // The invariant: no pre-selected item comes from the purge, screenshots, installers, home folders,
        // an AppleDouble file whose file still exists, or a saved-versions store.
        for (category, item) in preselected {
            let name = item.url?.lastPathComponent ?? item.title
            #expect(!["installers", "screenshots", "purgeable", "home"].contains(category), "pre-selected \(category): \(item.title)")
            #expect(item.payload["type"] != "purge", "pre-selected purge: \(item.title)")
            #expect(name != "._photo.jpg" && name != ".DocumentRevisions-V100", "pre-selected \(name)")
            #expect(!(name.hasPrefix("._")), "pre-selected AppleDouble \(name)")
        }

        // Installers: .iso and .sparseimage only from Downloads, never from Documents or a disk's root.
        let installers = try #require(results["installers"])
        #expect(Set(installers.items.map(\.title)) == ["Installer.dmg", "ubuntu.iso", "Setup.dmg"])
        #expect(installers.items.allSatisfy { $0.tier == .caution })
        #expect(installers.category.tier == .caution)

        // Purge: offered on the startup disk with an honest subtitle, never pre-selected.
        let purge = try #require(results["purgeable"]?.items.flatMap(\.leaves).first { $0.payload["type"] == "purge" })
        #expect(purge.tier == .caution)
        #expect(purge.subtitle?.contains("Writes about 10") == true)

        // External junk: the AppleDouble with a companion is not listed, the orphan is Caution, the versions store is Caution,
        // and the Windows Recycle Bin is listed once, under Bin.
        let junk = try #require(results["externalJunk"]).items.flatMap(\.leaves)
        let names = junk.compactMap { $0.url?.lastPathComponent }
        #expect(!names.contains("._photo.jpg"))
        #expect(junk.first { $0.url?.lastPathComponent == "._gone.jpg" }?.tier == .caution)
        #expect(junk.first { $0.url?.lastPathComponent == "._gone.jpg" }?.subtitle?.contains("gone.jpg") == true)
        #expect(junk.first { $0.url?.lastPathComponent == ".DS_Store" }?.tier == .safe)
        #expect(junk.first { $0.url?.lastPathComponent == ".DocumentRevisions-V100" }?.tier == .caution)
        #expect(junk.first { $0.url?.lastPathComponent == ".DocumentRevisions-V100" }?.subtitle?.contains("Browse All Versions") == true)
        #expect(!names.contains("$RECYCLE.BIN") && !junk.contains { $0.url?.path.contains("$RECYCLE.BIN") == true })
        let trash = try #require(results["trash"]).items.flatMap(\.leaves)
        #expect(trash.contains { $0.url?.lastPathComponent == "S-1-5-21-1" })

        // Manage Files home rows are display only.
        #expect(!homeFolders.isEmpty && homeFolders.allSatisfy { $0.tier == .protected })
        #expect(homeFolders.contains { $0.title == ".ssh" })
        #expect(RemovalPlan(selected: homeFolders, permanently: false).isEmpty)
    }

    // MARK: - AppleDouble

    @Test func appleDoubleIsOfferedOnlyWithoutItsFile() throws {
        let fm = FileManager.default
        let disk = try Self.makeDir("AppleDouble")
        defer { try? fm.removeItem(at: disk) }
        try Self.file(disk, "keep.txt")
        try Self.file(disk, "._keep.txt")
        try Self.file(disk, "Folder/inner.txt")
        try Self.file(disk, "._Folder")
        try Self.file(disk, "._orphan.txt")
        try Self.file(disk, "sub/._lost.mov")
        try Self.file(disk, "._")
        try Self.file(disk, ".Spotlight-V100/._store")   // inside a folder that is listed as a whole
        try fm.createSymbolicLink(at: disk.appending(path: "dangling"), withDestinationURL: disk.appending(path: "nowhere"))
        try Self.file(disk, "._dangling")                 // its companion is a (broken) link that still exists

        #expect(!ExternalDiskJunkScanner.isOrphanAppleDouble(disk.appending(path: "._keep.txt")))
        #expect(!ExternalDiskJunkScanner.isOrphanAppleDouble(disk.appending(path: "._Folder")))
        #expect(!ExternalDiskJunkScanner.isOrphanAppleDouble(disk.appending(path: "._dangling")))
        #expect(!ExternalDiskJunkScanner.isOrphanAppleDouble(disk.appending(path: "._")))
        #expect(ExternalDiskJunkScanner.isOrphanAppleDouble(disk.appending(path: "._orphan.txt")))

        let found = ExternalDiskJunkScanner.findAppleDoubles(on: disk)
        #expect(Set(found.orphans.map(\.lastPathComponent)) == ["._orphan.txt", "._lost.mov"])
        #expect(found.dsStores.isEmpty && !found.partial)
    }

    // MARK: - Local snapshots

    @Test func snapshotDatesAreParsed() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-11-09-101500.local
        com.apple.TimeMachine.2019-10-13-083012
          com.apple.TimeMachine.2026-11-08-235959.local\u{20}\u{20}
        com.apple.TimeMachine.local
        com.apple.os.update-2026-11-09-101500
        garbage 2026-11-09-101500

        """
        let snapshots = PurgeableSpaceScanner.parseLocalSnapshots(output)
        #expect(snapshots.map(\.date) == ["2026-11-09-101500", "2019-10-13-083012", "2026-11-08-235959"])
        #expect(snapshots.first?.name == "com.apple.TimeMachine.2026-11-09-101500.local")
        #expect(PurgeableSpaceScanner.parseLocalSnapshots("No local snapshots\n").isEmpty)
    }

    // MARK: - Purgeable space

    @Test func purgeWriteMustBeInProportion() {
        let gb = Self.gb
        #expect(PurgeableReclaimer.plannedWrite(available: 10 * gb, purgeable: 3 * gb) == 13 * gb + 256 * 1024 * 1024)
        #expect(PurgeableReclaimer.plannedWrite(available: 30 * gb, purgeable: 20 * gb) != nil)    // ≤ 2 × purgeable
        #expect(PurgeableReclaimer.plannedWrite(available: 20 * gb, purgeable: 1 * gb) != nil)     // ≤ 20 GB
        #expect(PurgeableReclaimer.plannedWrite(available: 300 * gb, purgeable: 5 * gb) == nil)    // would write ~300 GB for 5 GB
        #expect(PurgeableReclaimer.plannedWrite(available: 21 * gb, purgeable: 10 * gb) == nil)
        #expect(PurgeableReclaimer.plannedWrite(available: 1 * gb, purgeable: 0) == nil)
        // The write stops once (nearly) all of the purgeable space is gone.
        #expect(!PurgeableReclaimer.hasReleased(purgeableBefore: 5 * gb, purgeableNow: 4 * gb))
        #expect(PurgeableReclaimer.hasReleased(purgeableBefore: 5 * gb, purgeableNow: 100 * 1024 * 1024))
        #expect(PurgeableReclaimer.hasReleased(purgeableBefore: 5 * gb, purgeableNow: 0))
        #expect(PurgeableReclaimer.hasReleased(purgeableBefore: 500 * 1024 * 1024, purgeableNow: 60 * 1024 * 1024))
    }

    @Test func purgeOnRoomyDiskIsInformationOnly() async throws {
        let disk = try Self.makeDir("PurgeExternal")
        defer { try? FileManager.default.removeItem(at: disk) }
        var apfs = Self.external(disk, id: "apfs", format: "APFS")
        apfs.availableForImportantUsage = apfs.availableCapacity + 4 * Self.gb
        let context = CleanupContext(volumes: [Self.root(available: 300 * Self.gb, important: 305 * Self.gb), apfs], enabledVolumeIDs: ["apfs"],
                                     installedApps: [], rules: .bundled)
        let result = try #require(await CleanupEngine().scan(categoryID: "purgeable", context: context))
        let leaves = result.items.flatMap(\.leaves)
        #expect(!leaves.contains { $0.payload["type"] == "purge" })
        // The explanation sits in the disk's own row, or in a row beside the snapshots when this Mac has some.
        let info = try #require(leaves.first { $0.payload["type"] == "purgeInfo" } ?? result.items.first { $0.children.isEmpty && $0.id == "purgeable:root" })
        #expect(info.tier == .protected)
        #expect(info.subtitle?.contains("macOS frees this by itself") == true)
        #expect(!RemovalPlan(selected: result.items, permanently: false).registrations.contains { $0.payload["type"]?.hasPrefix("purge") == true })
        // Never offered for an external disk, whatever its free space.
        #expect(!leaves.contains { $0.id.hasPrefix("purge:apfs") })
        #expect(result.category.tier == .caution)
    }

    // MARK: - Caches

    @Test func claimedCacheFoldersAreNotListedTwice() async throws {
        let home = try Self.makeDir("ClaimedHome")
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.file(home, "Library/Caches/Google/Chrome/Default/Cache/blob", size: 1000)
        try Self.file(home, "Library/Caches/Google/Other/blob", size: 1000)
        try Self.file(home, "Library/Caches/com.apple.dt.Xcode/blob", size: 1000)
        try Self.file(home, "Library/Caches/com.vendor.tool/blob", size: 1000)
        let result = try #require(await CleanupEngine().scan(categoryID: "caches", context: CleanupContext(home: home.path, volumes: [], rules: .bundled)))
        let paths = result.items.flatMap(\.leaves).compactMap { $0.url?.standardizedFileURL.path }
        let caches = home.appending(path: "Library/Caches").path
        #expect(paths.filter { $0 == caches + "/Google/Chrome" }.count == 1)       // once, as Chrome's cache
        #expect(!paths.contains(caches + "/Google"))                                 // the parent is not listed again
        #expect(!paths.contains(caches + "/com.apple.dt.Xcode"))                     // Xcode junk lists it
        #expect(paths.contains(caches + "/com.vendor.tool"))

        let claimed: Set<String> = ["/c/Google/Chrome"]
        #expect(CachesScanner.isClaimed("/c/Google/Chrome", by: claimed))
        #expect(CachesScanner.isClaimed("/c/Google", by: claimed))
        #expect(CachesScanner.isClaimed("/c/Google/Chrome/Default", by: claimed))
        #expect(!CachesScanner.isClaimed("/c/Goog", by: claimed))
        #expect(!CachesScanner.isClaimed("/c/Google/ChromeBeta", by: claimed))
    }

    // MARK: - Unreadable folders

    @Test func unreadableFolderAddsANote() async throws {
        let home = try Self.makeDir("DeniedHome")
        let downloads = home.appending(path: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        try Self.file(home, "Library/Containers/com.apple.mail/Data/Library/Mail Downloads/a.pdf")
        #expect(chmod(downloads.path, 0) == 0)
        defer { chmod(downloads.path, 0o700); try? FileManager.default.removeItem(at: home) }
        let result = try #require(await CleanupEngine().scan(categoryID: "mail", context: CleanupContext(home: home.path, volumes: [], rules: .bundled)))
        let note = try #require(result.items.first { $0.payload["type"] == "note" })
        #expect(note.tier == .protected)
        #expect(note.title == "1 folder could not be read")
        #expect(note.subtitle?.contains("Mail Downloads") == true)
        #expect(RemovalPlan(selected: result.items, permanently: false).isEmpty)

        // Once the folder is readable the note is gone.
        chmod(downloads.path, 0o700)
        let readable = try #require(await CleanupEngine().scan(categoryID: "mail", context: CleanupContext(home: home.path, volumes: [], rules: .bundled)))
        #expect(!readable.items.contains { $0.payload["type"] == "note" })

        let privacy = CleanupSupport.unreadableNote([("/Users/me/Desktop", EPERM)], category: MailAttachmentsScanner().info, home: "/Users/me")
        #expect(privacy?.subtitle == "Full Disk Access is required to read ~/Desktop")
    }

    // MARK: - Language files

    @Test func languageFilesKeepDevelopmentRegionAndSkipAppStoreApps() async throws {
        let home = try Self.makeDir("LangHome")
        defer { try? FileManager.default.removeItem(at: home) }
        func app(_ name: String, region: String?, lprojs: [String], appStore: Bool = false) throws -> InstalledApp {
            let url = home.appending(path: "Applications/\(name).app")
            for lproj in lprojs { try Self.file(url, "Contents/Resources/\(lproj).lproj/Localizable.strings") }
            if let region {
                let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleDevelopmentRegion": region], format: .xml, options: 0)
                try plist.write(to: url.appending(path: "Contents/Info.plist"))
            }
            if appStore { try Self.file(url, "Contents/_MASReceipt/receipt") }
            let id = "com.example.\(name.lowercased())"
            return InstalledApp(url: url, name: name, bundleID: id, version: "1", build: "1", isSystem: false, modificationDate: nil, creationDate: nil,
                                lastOpenedDate: nil, identity: AppIdentity(bundleID: id, name: name, fileName: name, executable: name))
        }
        let german = try app("German", region: "de", lprojs: ["de", "fr", "en", "Base"])
        let legacy = try app("Legacy", region: "Japanese", lprojs: ["Japanese", "ja", "fr"])
        let store = try app("Store", region: "en", lprojs: ["en", "fr"], appStore: true)
        let context = CleanupContext(home: home.path, volumes: [], installedApps: [german, legacy, store], rules: .bundled, preferredLanguages: ["it-IT"])
        let result = try #require(await CleanupEngine().scan(categoryID: "languages", context: context))
        let byApp = Dictionary(uniqueKeysWithValues: result.items.filter { $0.kind == .group }.map { ($0.title, Set($0.children.map(\.title))) })
        #expect(byApp["German"] == ["fr.lproj"])          // de is the development region; en and Base are always kept
        #expect(byApp["Legacy"] == ["fr.lproj"])          // "Japanese" and "ja" both hold the development region
        #expect(byApp["Store"] == nil)                     // App Store apps are never touched
        #expect(result.items.flatMap(\.leaves).allSatisfy { $0.tier == .caution })
    }

    // MARK: - Volumes

    @Test func readOnlyVolumesAreOutOfScope() throws {
        let rw = Self.external(URL(filePath: "/Volumes/RW"), id: "rw")
        let ro = Self.external(URL(filePath: "/Volumes/RO"), id: "ro", readOnly: true)
        let context = CleanupContext(volumes: [Self.root(available: 1, important: 1), rw, ro], enabledVolumeIDs: ["rw", "ro"], rules: .bundled)
        #expect(context.scopedVolumes.map(\.id) == ["root", "rw"])

        // Values encoded before isReadOnly existed still decode.
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ro)) as? [String: Any])
        #expect(object["isReadOnly"] as? Bool == true)
        object["isReadOnly"] = nil
        let decoded = try JSONDecoder().decode(VolumeInfo.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!decoded.isReadOnly && decoded.id == "ro")
        #expect(VolumeCatalog.mountedVolumes().first { $0.isRoot }?.isReadOnly == false)
    }

    // MARK: - Reclaim loop (no data is written)

    @Test func cancelledReclaimWritesNothingAndLeavesNoFile() throws {
        let fm = FileManager.default
        let disk = try Self.makeDir("ReclaimCancel")
        defer { try? fm.removeItem(at: disk) }
        let outcome = try PurgeableReclaimer.writeUntilPurged(volumeURL: disk, before: (available: Self.gb, purgeable: Self.gb), target: 64 * 1024 * 1024,
                                                              progress: nil, isCancelled: { true })
        #expect(outcome.written == 0 && outcome.cancelled)
        #expect(try fm.contentsOfDirectory(atPath: disk.path).isEmpty)   // the scratch file is gone and its descriptor closed once
        let nothing = try PurgeableReclaimer.writeUntilPurged(volumeURL: disk, before: (available: Self.gb, purgeable: Self.gb), target: 0,
                                                              progress: nil, isCancelled: { false })
        #expect(nothing.written == 0 && !nothing.cancelled)
        #expect(try fm.contentsOfDirectory(atPath: disk.path).isEmpty)
    }
}
