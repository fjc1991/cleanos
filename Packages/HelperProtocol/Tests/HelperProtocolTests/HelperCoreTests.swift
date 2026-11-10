import Testing
import Foundation
@testable import HelperProtocol

@Suite struct ProtectedPathsTests {
    let home = NSHomeDirectory()

    @Test(arguments: [
        "/", "/System", "/System/Library/CoreServices/Finder.app", "/usr", "/usr/bin/ls", "/usr/lib/libz.dylib", "/bin/sh",
        "/private/etc/hosts", "/etc/hosts", "/var/db/receipts/x.bom", "/private/var/db/x", "/tmp", "/private/tmp", "/var",
        "/Applications", "/Applications/Utilities", "/Library", "/Library/Application Support", "/Library/LaunchDaemons",
        "/Library/Keychains/System.keychain", "/Library/Security/SecurityAgentPlugins/x.bundle", "/Users", "/Users/Shared",
        "/usr/local", "/usr/local/bin", "/opt", "/opt/homebrew", "/Volumes", "/Volumes/Backup", "/Volumes/Backup/.Trashes",
        "/Library/Apple/System/Library/x", "/Library/LaunchDaemons/com.apple.foo.plist", "/LIBRARY/application support",
    ])
    func systemLocationsAreRefused(_ path: String) {
        #expect(ProtectedPaths.refusal(for: ProtectedPaths.canonical(path)) != nil, "\(path) should be refused")
    }

    @Test func homeFoldersAreRefused() {
        for name in ["", "/Documents", "/Desktop", "/Library", "/Library/Caches", "/Library/Application Support", "/.ssh", "/.config",
                     "/Projects", "/Library/Mail/V10", "/Library/Mobile Documents/com~apple~CloudDocs", "/Pictures/Photos Library.photoslibrary/database"] {
            #expect(ProtectedPaths.refusal(for: ProtectedPaths.canonical(home + name)) != nil, "~\(name) should be refused")
        }
    }

    @Test(arguments: [
        "/Applications/Zoom.app", "/Library/Application Support/Zoom", "/Library/LaunchDaemons/us.zoom.ZoomDaemon.plist",
        "/Library/PrivilegedHelperTools/us.zoom.ZoomDaemon", "/Library/Caches/com.apple.amsengagementd", "/usr/local/bin/docker",
        "/Library/DropboxHelperTools", "/opt/cisco", "/private/tmp/KSInstallAction.abc", "/Volumes/Backup/.Trashes/502",
        "/Volumes/Backup/Users/me/Library/Caches/x", "/Library/Google/GoogleSoftwareUpdate",
        "/Users/Shared/Adobe", "/Users/Shared/Parallels/Backups", "/Users/Shared/Library/Application Support/Example",
    ])
    func appLeftoversAreAllowed(_ path: String) {
        #expect(ProtectedPaths.refusal(for: path) == nil, "\(path) should be allowed")
    }

    @Test func homeLeftoversAreAllowed() {
        for name in ["/Library/Caches/com.example.app", "/Library/Application Support/Example", "/Library/Dropbox", "/.dropbox",
                     "/Applications/Example.app", "/Downloads/Example.dmg", "/Pictures/Photos Library.photoslibrary"] {
            #expect(ProtectedPaths.refusal(for: home + name) == nil, "~\(name) should be allowed")
        }
    }

    @Test func sharedUsersFolderKeepsItsLibrary() {
        for path in ["/Users/Shared", "/Users/Shared/Library", "/Users/Shared/Library/Application Support", "/Users/Shared/Library/Caches"] {
            #expect(ProtectedPaths.refusal(for: path) != nil, "\(path) should be refused")
        }
    }

    /// A folder directly in a home folder is the user's own; a single file or an app there is not.
    @Test func filesAndAppsDirectlyInHomeAreAllowed() throws {
        let file = home + "/cleanos-test-\(UUID().uuidString).iso"
        let folder = home + "/cleanos-test-\(UUID().uuidString)"
        #expect(FileManager.default.createFile(atPath: file, contents: Data("x".utf8)))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(atPath: file)
            try? FileManager.default.removeItem(atPath: folder)
        }
        #expect(ProtectedPaths.refusal(for: file) == nil, "a file in the home folder should be allowed")
        #expect(ProtectedPaths.refusal(for: home + "/Example.app") == nil, "an app in the home folder should be allowed")
        #expect(ProtectedPaths.refusal(for: folder) != nil, "a folder in the home folder should be refused")
        #expect(ProtectedPaths.refusal(for: home + "/cleanos-test-missing") != nil, "something that is not there should be refused")
    }

    @Test func traversalAndSymlinkedParentsAreResolved() throws {
        #expect(ProtectedPaths.refusal(for: ProtectedPaths.canonical("/Library/Caches/../Keychains/x")) != nil)
        #expect(ProtectedPaths.refusal(for: "/Library/Caches/../Keychains/x") != nil)
        let dir = FileManager.default.temporaryDirectory.appending(path: "pp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appending(path: "sys")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/System/Library")
        #expect(ProtectedPaths.refusal(for: ProtectedPaths.canonical(link.path + "/CoreServices")) != nil)
        // Removing the link itself is fine only when it does not point into the system.
        #expect(ProtectedPaths.refusal(for: ProtectedPaths.canonical(link.path)) != nil)
    }
}

@Suite struct ToolPolicyTests {
    @Test func allowedCalls() {
        #expect(ToolPolicy.refusal(tool: "tccutil", arguments: ["reset", "All", "com.example.app"]) == nil)
        #expect(ToolPolicy.refusal(tool: "tmutil", arguments: ["deletelocalsnapshots", "2026-11-09-101500"]) == nil)
        #expect(ToolPolicy.refusal(tool: "mdutil", arguments: ["-E", "/"]) == nil)
        #expect(ToolPolicy.refusal(tool: "pkgutil", arguments: ["--forget", "us.zoom.pkg.videomeeting"]) == nil)
        #expect(ToolPolicy.refusal(tool: "launchctl", arguments: ["bootout", "system/us.zoom.ZoomDaemon"]) == nil)
        #expect(ToolPolicy.refusal(tool: "launchctl", arguments: ["bootstrap", "system", "/Library/LaunchDaemons/us.zoom.ZoomDaemon.plist"]) == nil)
    }

    @Test func refusedCalls() {
        #expect(ToolPolicy.refusal(tool: "diskutil", arguments: ["eraseDisk", "APFS", "x", "disk0"]) != nil)
        #expect(ToolPolicy.refusal(tool: "rm", arguments: ["-rf", "/"]) != nil)
        #expect(ToolPolicy.refusal(tool: "tccutil", arguments: ["reset", "All"]) != nil)
        #expect(ToolPolicy.refusal(tool: "tmutil", arguments: ["delete", "/Volumes/Backup"]) != nil)
        #expect(ToolPolicy.refusal(tool: "tmutil", arguments: ["deletelocalsnapshots", "/"]) != nil)
        #expect(ToolPolicy.refusal(tool: "mdutil", arguments: ["-i", "off", "/"]) != nil)
        #expect(ToolPolicy.refusal(tool: "pkgutil", arguments: ["--forget", "com.apple.pkg.Core"]) != nil)
        #expect(ToolPolicy.refusal(tool: "launchctl", arguments: ["bootout", "system/com.apple.Finder"]) != nil)
        #expect(ToolPolicy.refusal(tool: "launchctl", arguments: ["bootstrap", "system", "/tmp/evil.plist"]) != nil)
        #expect(ToolPolicy.refusal(tool: "launchctl", arguments: ["submit", "-l", "x", "--", "/bin/sh"]) != nil)
        #expect(ToolPolicy.refusal(tool: "launchctl", arguments: ["bootout", "system/x\ny"]) != nil)
    }
}

@Suite struct HelperCoreTests {
    @Test func removeRefusesProtectedAndTrashesTheRest() throws {
        // Temporary folders (/var/folders) are refused by design, so work below the user's caches.
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/com.cleanos.tests/hc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "victim.txt")
        try Data("x".utf8).write(to: file)
        let results = HelperCore.remove([RootRemovalRequest(path: "/System", permanently: true),
                                         RootRemovalRequest(path: file.path, permanently: true),
                                         RootRemovalRequest(path: dir.appending(path: "missing").path, permanently: true)],
                                        uid: getuid(), gid: getgid())
        #expect(results[0].refused && !results[0].succeeded)
        #expect(results[1].succeeded && !FileManager.default.fileExists(atPath: file.path))
        #expect(results[2].succeeded)
        #expect(!HelperCore.remove([RootRemovalRequest(path: FileManager.default.temporaryDirectory.appending(path: "x").path, permanently: true)],
                                   uid: getuid(), gid: getgid())[0].succeeded)
    }

    @Test func requestsRoundTrip() throws {
        let request = HelperRequest.remove(items: [RootRemovalRequest(path: "/Applications/X.app", permanently: false)], uid: 501, gid: 20)
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(HelperRequest.self, from: data) == request)
        let response = HelperResponse.removed([RootRemovalResult(path: "/a", trashedPath: "/b")])
        #expect(try JSONDecoder().decode(HelperResponse.self, from: JSONEncoder().encode(response)) == response)
    }

    @Test func toolOutputIsDrainedConcurrently() {
        // 200 KB on stderr before any stdout would deadlock a sequential reader.
        let result = HelperCore.run(executable: "/bin/sh", arguments: ["-c", "head -c 200000 /dev/zero | tr '\\\\0' x >&2; echo done"])
        #expect(result.status == 0 && result.stdout == "done\n" && result.stderr.count == 200_000)
    }

    @Test func requirementPinsTheCertificate() {
        #expect(CodeIdentity.requirement(identifier: "com.cleanos.helper", pinnedTo: nil) == "identifier \"com.cleanos.helper\"")
        #expect(CodeIdentity.requirement(identifier: "a", pinnedTo: "AB12").contains("certificate leaf = H\"AB12\""))
    }
}
