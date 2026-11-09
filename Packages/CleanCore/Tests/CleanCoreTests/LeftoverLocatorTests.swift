import Foundation
import Testing
@testable import CleanCore

/// Builds a throwaway home folder laid out like the leftovers of a fake app, in the shape the Homebrew cask
/// `zap` stanzas describe for Dropbox / Zoom / Docker / 1Password, then runs the deep dive on it.
@Suite struct LeftoverLocatorTests {
    struct Fixture {
        let home: URL
        let app: InstalledApp
        let other: InstalledApp
        let expected: [String: (group: String, tier: RiskTier)]
        let decoys: [String]
    }

    static func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "LeftoverHome-\(UUID().uuidString)")
        func dir(_ relative: String) throws -> URL {
            let url = home.appending(path: relative)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func file(_ relative: String, _ contents: String = "x") throws -> URL {
            let url = home.appending(path: relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            return url
        }

        // The fake app bundle with a helper app inside.
        let appURL = try dir("Applications/Fake App.app/Contents/MacOS").deletingLastPathComponent().deletingLastPathComponent()
        try file("Applications/Fake App.app/Contents/Info.plist", plist([
            "CFBundleIdentifier": "com.example.fakeapp", "CFBundleName": "Fake App", "CFBundleExecutable": "FakeApp",
            "CFBundleShortVersionString": "2.1", "CFBundleVersion": "210",
        ]))
        try file("Applications/Fake App.app/Contents/MacOS/FakeApp", "#!/bin/sh\n")
        try file("Applications/Fake App.app/Contents/Library/LoginItems/Fake Helper.app/Contents/Info.plist", plist([
            "CFBundleIdentifier": "com.example.fakeapp.helper", "CFBundleName": "Fake Helper", "CFBundleExecutable": "FakeHelper",
        ]))
        try file("Applications/Fake App.app/Contents/Library/LaunchDaemons/com.example.fakeapp.daemon.plist", plist(["Label": "com.example.fakeapp.daemon"]))

        var expected: [String: (String, RiskTier)] = [:]
        func expect(_ relative: String, _ group: String, _ tier: RiskTier, dir isDir: Bool = true, contents: String = "x") throws {
            let url = isDir ? try dir(relative) : try file(relative, contents)
            expected[url.standardizedFileURL.path] = (group, tier)
        }
        try expect("Library/Application Support/Fake App", "Application Support", .normal)
        try expect("Library/Application Support/com.example.fakeapp", "Application Support", .normal)
        try expect("Library/Application Support/CrashReporter/FakeApp_6267A852-EB3D-52B1-9D45-5FE846726B7D.plist", "Crash Reports", .safe, dir: false)
        try expect("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.example.fakeapp.sfl3", "Traces", .safe, dir: false)
        try expect("Library/Caches/com.example.fakeapp", "Caches", .safe)
        try expect("Library/Caches/com.example.fakeapp.helper", "Caches", .safe)
        try expect("Library/Caches/SentryCrash/FakeApp", "Crash Reports", .safe)
        try expect("Library/Caches/Example/Fake App", "Caches", .safe)   // vendor folder with one product inside (not promoted)
        try dir("Library/Caches/Example/Other Product")
        try expect("Library/Preferences/com.example.fakeapp.plist", "Preferences", .normal, dir: false)
        try expect("Library/Preferences/ByHost/com.example.fakeapp.6267A852-EB3D-52B1-9D45-5FE846726B7D.plist", "Preferences", .normal, dir: false)
        try expect("Library/Containers/com.example.fakeapp", "Containers", .normal)
        try expect("Library/Containers/com.example.fakeapp.share", "Containers", .normal)
        try expect("Library/Group Containers/ABCDE12345.com.example.fakeapp", "Group Containers", .normal)
        try expect("Library/Application Scripts/com.example.fakeapp.share", "Containers", .normal)
        try expect("Library/HTTPStorages/com.example.fakeapp.binarycookies", "Web Storage", .normal, dir: false)
        try expect("Library/WebKit/com.example.fakeapp", "Web Storage", .normal)
        try expect("Library/Saved Application State/com.example.fakeapp.savedState", "Saved State", .safe)
        try expect("Library/Logs/Fake App", "Logs", .safe)
        try expect("Library/Logs/DiagnosticReports/FakeApp-2026-01-01-120000.ips", "Crash Reports", .safe, dir: false)
        try expect("Library/LaunchAgents/com.example.fakeapp.agent.plist", "Login Items", .normal, dir: false,
                   contents: plist(["Label": "com.example.fakeapp.agent", "Program": "/bin/true"]))
        try expect("Library/LaunchAgents/org.unrelated.label.plist", "Login Items", .normal, dir: false,
                   contents: plist(["Label": "org.unrelated.label", "ProgramArguments": [appURL.path + "/Contents/MacOS/FakeApp", "--agent"]]))
        try expect("Library/Mobile Documents/ABCDE12345~com~example~fakeapp", "Cloud", .caution)
        try expect(".fakeapp", "Dotfiles", .normal)
        try expect(".config/fakeapp", "Dotfiles", .normal)
        try expect("Documents/Fake App", "User Data", .caution)
        try expect("Library/Application Support/Google/Chrome/NativeMessagingHosts/org.unrelated.host.json", "Browser Integration", .normal, dir: false,
                   contents: "{\"name\":\"org.unrelated.host\",\"path\":\"\(appURL.path)/Contents/MacOS/FakeApp\",\"type\":\"stdio\"}")
        try file(".zshrc", "export PATH=\"$PATH:/usr/local/bin\"\nalias fake='\(appURL.path)/Contents/MacOS/FakeApp'\n")

        // A symlink in ~/Applications pointing at the app.
        try fm.createDirectory(at: home.appending(path: "Applications"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appending(path: "Applications/Fake App link"), withDestinationURL: appURL)
        expected[home.appending(path: "Applications/Fake App link").standardizedFileURL.path] = ("Executables", .normal)

        // Decoys that must not be attributed to the app.
        var decoys: [String] = []
        for relative in ["Library/Application Support/Fake Appliance", "Library/Caches/com.example.other", "Library/Caches/Example/Other Product",
                         "Library/Preferences/com.apple.finder.plist", "Library/Containers/com.example.fakeapppro", "Library/Logs/Other",
                         "Documents/Important", ".config/other", "Library/Application Support/Code"] {
            let url = relative.hasSuffix(".plist") ? try file(relative) : try dir(relative)
            decoys.append(url.standardizedFileURL.path)
        }
        try file("Library/LaunchAgents/com.example.fakeapppro.plist", plist(["Label": "com.example.fakeapppro", "Program": "/bin/true"]))
        decoys.append(home.appending(path: "Library/LaunchAgents/com.example.fakeapppro.plist").standardizedFileURL.path)

        var identity = AppInspector.inspect(bundleURL: appURL, shared: Rules.bundled.shared)!
        identity.groupIDs = ["ABCDE12345.com.example.fakeapp"]
        identity.teamID = "ABCDE12345"
        identity.extensionIDs = ["com.example.fakeapp.share"]
        identity.iCloudContainerIDs = ["iCloud.com.example.fakeapp"]
        let app = InstalledApp(url: appURL, name: "Fake App", bundleID: "com.example.fakeapp", version: "2.1", build: "210", isSystem: false,
                               modificationDate: nil, creationDate: nil, lastOpenedDate: nil, identity: identity)
        let otherIdentity = AppIdentity(bundleID: "com.example.fakeapppro", name: "Fake App Pro", fileName: "Fake App Pro", executable: "FakeAppPro")
        let other = InstalledApp(url: home.appending(path: "Applications/Fake App Pro.app"), name: "Fake App Pro", bundleID: "com.example.fakeapppro",
                                 version: nil, build: nil, isSystem: false, modificationDate: nil, creationDate: nil, lastOpenedDate: nil, identity: otherIdentity)
        return Fixture(home: home, app: app, other: other, expected: expected, decoys: decoys)
    }

    static func plist(_ dict: [String: Any]) throws -> String {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }

    @Test func identityInspectionReadsNestedBundlesAndLabels() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let identity = fixture.app.identity
        #expect(identity.bundleID == "com.example.fakeapp")
        #expect(identity.subBundleIDs.contains("com.example.fakeapp.helper"))
        #expect(identity.launchdLabels.contains("com.example.fakeapp.daemon"))
        #expect(identity.launchdLabels.contains("com.example.fakeapp.helper"))
        #expect(identity.processNames.contains("FakeHelper"))
        #expect(identity.vendor == "example")
        #expect(identity.normalizedNames.contains("fakeapp"))
    }

    @Test func deepDiveFindsEveryExpectedPathAndNoDecoy() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let locator = LeftoverLocator(rules: .bundled, home: fixture.home.path)
        let result = await locator.locate(app: fixture.app, otherApps: [fixture.other])
        let found = Dictionary(uniqueKeysWithValues: result.allItems.map { ($0.url!.standardizedFileURL.path, $0) })

        var missing: [String] = []
        for (path, expectation) in fixture.expected {
            guard let item = found[path] else { missing.append(path); continue }
            #expect(item.group == expectation.group, "group for \(path): \(item.group)")
            #expect(item.tier == expectation.tier, "tier for \(path): \(item.tier) matched by \(item.matchedBy)")
        }
        #expect(missing.isEmpty, "missing: \(missing)")

        let foundDecoys = fixture.decoys.filter { found[$0] != nil }
        #expect(foundDecoys.isEmpty, "decoys attributed: \(foundDecoys)")

        // The app bundle itself leads the Executables group.
        #expect(result.groups.first?.title == "Executables")
        #expect(found[fixture.app.url.standardizedFileURL.path]?.kind == .bundle)

        // Content signals.
        let unrelatedAgent = found[fixture.home.appending(path: "Library/LaunchAgents/org.unrelated.label.plist").standardizedFileURL.path]
        #expect(unrelatedAgent?.matchedBy.contains("launchd program inside the app") == true)
        let link = found[fixture.home.appending(path: "Applications/Fake App link").standardizedFileURL.path]
        #expect(link?.matchedBy.contains("symlink to the app") == true)
        let host = found[fixture.home.appending(path: "Library/Application Support/Google/Chrome/NativeMessagingHosts/org.unrelated.host.json").standardizedFileURL.path]
        #expect(host?.matchedBy.contains("native messaging host points into the app") == true)

        // The shell profile line is reported as a registration, never the whole file.
        let shell = result.allItems.filter { $0.group == "Shell Integration" }
        #expect(shell.count == 1)
        #expect(shell.first?.kind == .registration)
        #expect(shell.first?.subtitle?.contains("alias fake") == true)
        #expect(found[fixture.home.appending(path: ".zshrc").standardizedFileURL.path] == nil || found[fixture.home.appending(path: ".zshrc").standardizedFileURL.path]?.kind == .registration)

        // Every file item has a size and the groups roll up.
        #expect(result.totalSize > 0)
        #expect(result.groups.allSatisfy { $0.size == $0.children.reduce(0) { $0 + $1.size } })
    }

    @Test func removalPlanPartitionsAndDryRunExecutes() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let locator = LeftoverLocator(rules: .bundled, home: fixture.home.path)
        let result = await locator.locate(app: fixture.app, otherApps: [], includeExecutable: false)
        // The deep dive also reads real system folders (plug-ins, launch daemons), so what it finds outside the
        // fixture depends on the host: GitHub's macOS runners ship a `com.example…` audio driver that the
        // same-developer rule rightly matches. Keep the plan to the fixture; items without a URL (registrations) stay in.
        let marker = fixture.home.lastPathComponent
        let selection = result.defaultSelection.filter { item in item.url.map { $0.path.contains(marker) } ?? true }
        #expect(!selection.isEmpty)
        let plan = RemovalPlan(selected: selection, permanently: false)
        #expect(plan.rootItems.isEmpty)
        #expect(plan.registrations.isEmpty)                 // caution-tier shell line is not selected by default
        #expect(plan.userItems.count == selection.count)
        #expect(!result.allItems.filter { $0.tier == .caution }.isEmpty)

        setenv("CLEANOS_DRY_RUN", "1", 1)
        defer { unsetenv("CLEANOS_DRY_RUN") }
        let journal = RemovalJournal(directory: fixture.home.appending(path: "Journal"))
        let executor = RemovalExecutor(journal: journal)
        let outcome = await executor.execute(plan, title: "Fake App", appVersion: "test")
        #expect(outcome.isDryRun)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.succeeded.count == plan.userItems.count)
        // Nothing was touched.
        #expect(FileManager.default.fileExists(atPath: fixture.home.appending(path: "Library/Caches/com.example.fakeapp").path))
        let sessions = try await journal.allSessions()
        #expect(sessions.first?.entries.count == plan.userItems.count)
    }
}

@Suite struct CancellationAndForceStopTests {
    @Test func cancelledDeepDiveReturnsPartialResultWithTheBundle() async throws {
        let fixture = try LeftoverLocatorTests.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let locator = LeftoverLocator(rules: .bundled, home: fixture.home.path)
        let task = Task { await locator.locate(app: fixture.app, otherApps: [fixture.other]) }
        task.cancel()
        let result = await task.value
        #expect(result.isPartial)
        #expect(result.groups.first?.title == "Executables")
        #expect(result.allItems.contains { $0.kind == .bundle })
        #expect(result.duration < 5)
    }

    @Test func forceStopKillsProcessesInsideTheBundle() async throws {
        let fm = FileManager.default
        let bundle = fm.temporaryDirectory.appending(path: "ForceStop-\(UUID().uuidString)/Fake.app")
        let macos = bundle.appending(path: "Contents/MacOS")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        let executable = macos.appending(path: "sleeper")
        try fm.copyItem(at: URL(filePath: "/bin/sleep"), to: executable)
        // A copied system binary needs a fresh (ad hoc) signature to launch on Apple silicon.
        let sign = Process()
        sign.executableURL = URL(filePath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "-f", executable.path]
        try sign.run()
        sign.waitUntilExit()
        defer { try? fm.removeItem(at: bundle.deletingLastPathComponent()) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["300"]
        try process.run()
        try await Task.sleep(for: .milliseconds(300))
        #expect(ProcessMonitor.processes(inBundle: bundle.path).contains { $0.pid == process.processIdentifier })
        let survivors = await ProcessMonitor.forceStop(bundlePath: bundle.path, gracePeriod: 1)
        #expect(survivors.isEmpty)
        #expect(!process.isRunning)
    }
}
