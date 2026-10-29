import Foundation
import Testing
@testable import CleanCore

@Suite struct StartupExtensionsTests {
    @Test func parsesLaunchctlOutputs() {
        let list = "PID\tStatus\tLabel\n123\t0\tcom.example.agent\n-\t0\tcom.example.idle\n"
        let parsed = StartupScanner.parseLaunchctlList(list)
        #expect(parsed["com.example.agent"] == 123)
        #expect(parsed.keys.contains("com.example.idle") && parsed["com.example.idle"]! == nil)
        let disabled = "disabled services = {\n\t\"com.example.off\" => disabled\n\t\"com.example.on\" => enabled\n\t\"com.apple.x\" => true\n}\n"
        #expect(StartupScanner.parseDisabled(disabled) == ["com.example.off", "com.apple.x"])
        #expect(StartupScanner.title(for: "com.x", program: "/Applications/Foo.app/Contents/MacOS/foo") == "Foo")
        #expect(StartupScanner.title(for: "com.x", program: "/usr/local/bin/tool") == "tool")
    }

    @Test func parsesPluginkit() {
        let output = "+    com.example.widget(1.2)\tABCD\t2026-01-01 00:00:00 +0000\t/Applications/Example.app/Contents/PlugIns/W.appex\n-    com.other.ext(3)\tEFGH\t2026-01-01 00:00:00 +0000\t/Applications/Other.app/Contents/PlugIns/E.appex\n     com.default.ext(1)\tIJKL\t2026-01-01 00:00:00 +0000\t/Applications/D.app/Contents/PlugIns/D.appex\n"
        let entries = ExtensionsScanner.parsePluginkit(output)
        #expect(entries.count == 3)
        #expect(entries[2].enabled && entries[2].identifier == "com.default.ext")
        #expect(entries[0].enabled && entries[0].identifier == "com.example.widget" && entries[0].version == "1.2" && entries[0].path.hasSuffix("W.appex"))
        #expect(!entries[1].enabled && entries[1].identifier == "com.other.ext")
    }

    @Test func readsChromiumExtensions() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "ExtHome-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let profile = home.appending(path: "Library/Application Support/BraveSoftware/Brave-Browser/Default")
        let ext = profile.appending(path: "Extensions/abcdefghijklmnop/2.0_0")
        try fm.createDirectory(at: ext.appending(path: "_locales/en"), withIntermediateDirectories: true)
        try Data(#"{"name":"__MSG_appName__","version":"2.0","default_locale":"en"}"#.utf8).write(to: ext.appending(path: "manifest.json"))
        try Data(#"{"appName":{"message":"Shields Up"}}"#.utf8).write(to: ext.appending(path: "_locales/en/messages.json"))
        try Data(#"{"extensions":{"settings":{"abcdefghijklmnop":{"state":0}}}}"#.utf8).write(to: profile.appending(path: "Preferences"))
        let scanner = ExtensionsScanner(home: home.path)
        let groups = await scanner.scan(groupID: "browser", context: CleanupContext(home: home.path, volumes: [], rules: .bundled))
        let brave = groups.first { $0.title == "Brave Browser" }
        #expect(brave != nil)
        #expect(brave?.children.first?.title == "Shields Up")
        #expect(brave?.children.first?.payload["enabled"] == "0")
        #expect(brave?.children.first?.tier == .caution)
    }

    @Test func startupScannerListsRealAgents() async {
        let items = await StartupScanner().scan(installedApps: [])
        #expect(items.contains { $0.kind == .systemDaemon } || items.contains { $0.kind == .launchAgent } || items.isEmpty)
        #expect(items.allSatisfy { !$0.label.isEmpty })
    }
}
