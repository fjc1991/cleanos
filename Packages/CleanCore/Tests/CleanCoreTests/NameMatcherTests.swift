import Foundation
import Testing
@testable import CleanCore

@Suite struct NameMatcherTests {
    @Test func normalizeStripsVersionsAndPunctuation() {
        #expect(NameMatcher.normalize("Bartender 6") == "bartender")
        #expect(NameMatcher.normalize("App Cleaner 10.app") == "appcleaner")
        #expect(NameMatcher.normalize("zoom.us") == "zoomus")
        #expect(NameMatcher.normalize("Docker Desktop") == "dockerdesktop")
        #expect(NameMatcher.normalizeDeveloper("Nektony LLC") == "nektony")
        #expect(NameMatcher.normalizeDeveloper("Paragon Software GmbH") == "paragon")
    }

    @Test func reductions() {
        #expect(NameMatcher.reduce("com.anthropic.claudefordesktop.ShipIt.6267A852-EB3D-52B1-9D45-5FE846726B7D.plist", style: .byHostPlist) == ["com.anthropic.claudefordesktop.shipit"])
        #expect(NameMatcher.reduce("zoom.us-2026-10-12-142357.ips", style: .crashReport) == ["zoom.us"])
        #expect(NameMatcher.reduce("Bionic_6267A852-EB3D-52B1-9D45-5FE846726B7D.plist", style: .crashReport) == ["bionic"])
        #expect(NameMatcher.reduce("ExcUserFault_Safari-2026-10-12-142357.ips", style: .crashReport) == ["excuserfault_safari"])
        #expect(NameMatcher.reduce("59GAB85EFG~com~apple~dt~Xcode", style: .mobileDocuments) == ["com.apple.dt.xcode", "59gab85efg"])
        #expect(NameMatcher.reduce(".parallels_settings", style: .dotfile) == ["parallels"])
        #expect(NameMatcher.reduce(".claude.json", style: .dotfile) == ["claude"])
        #expect(NameMatcher.reduce("com.google.Chrome.savedState", style: .savedState) == ["com.google.chrome"])
        #expect(NameMatcher.reduce("com.docker.helper.sfl3", style: .sfl) == ["com.docker.helper"])
        #expect(NameMatcher.reduce("iCloud.us.zoom.videomeetings.plist", style: .iCloudContainer) == ["us.zoom.videomeetings"])
        #expect(NameMatcher.reduce("OneDrive-NovaSBE", style: .cloudStorage) == ["onedrive"])
        #expect(NameMatcher.reduce("ufsd_NTFS.kext", style: .bundleName) == ["ufsd_ntfs"])
        #expect(NameMatcher.reduce("us.zoom.pkg.videomeeting.bom", style: .receipt) == ["us.zoom.pkg.videomeeting"])
    }

    @Test func matchingSignals() {
        let identity = AppIdentity(bundleID: "us.zoom.xos", name: "zoom.us", bundleName: "zoom.us", fileName: "zoom.us", executable: "zoom.us",
                                   subBundleIDs: ["us.zoom.ZoomClips", "us.zoom.updater"], extensionIDs: ["us.zoom.share"],
                                   groupIDs: ["BJ4HAAB9B3.ZoomClient3rd"], teamID: "BJ4HAAB9B3", developerName: "Zoom Video Communications, Inc.",
                                   vendor: "zoom", launchdLabels: ["us.zoom.ZoomDaemon"], processNames: ["zoom.us", "caphost"])
        let shared = Rules.bundled.shared
        func m(_ name: String, _ style: NameStyle, _ allowed: Set<String>) -> [String] {
            NameMatcher.match(reduced: NameMatcher.reduce(name, style: style), identity: identity, allowed: allowed, shared: shared)
        }
        #expect(m("us.zoom.xos.plist", .plist, ["bundleID"]) == ["bundle ID"])
        #expect(m("us.zoom.xos.Hotkey.plist", .plist, ["bundleID"]) == ["bundle ID"])
        #expect(m("us.zoom.ZoomClips.plist", .plist, ["bundleID", "subBundleID"]) == ["helper bundle ID us.zoom.ZoomClips"])
        #expect(m("BJ4HAAB9B3.ZoomClient3rd", .folder, ["groupID"]) == ["app group BJ4HAAB9B3.ZoomClient3rd"])
        #expect(m("BJ4HAAB9B3.Something", .folder, ["teamGroup"]) == ["team ID BJ4HAAB9B3"])
        #expect(m("zoom.us", .folder, ["name"]) == ["app name"])
        #expect(m("Zoom", .folder, ["name"]) == [])                       // 4-char name only matches raw "zoom"
        #expect(m("zoom", .folder, ["name"]) == [])                       // identity names are "zoom.us"/"zoomus", not "zoom"
        #expect(m("zoom.us-2026-10-12.ips", .crashReport, ["processName"]) == ["process name"])
        #expect(m("us.zoom.ZoomDaemon", .folder, ["label"]) == ["launchd label"])
        #expect(m("us.zoomus.other", .folder, ["bundleID", "subBundleID", "name"]) == [])
        #expect(m("com.apple.finder.plist", .plist, ["bundleID", "name", "vendor"]) == [])
    }

    @Test func genericNamesNeverMatchAlone() {
        let identity = AppIdentity(bundleID: "com.example.cache", name: "Cache", fileName: "Cache", executable: "Cache")
        let reasons = NameMatcher.match(reduced: ["cache"], identity: identity, allowed: ["name", "executable"], shared: Rules.bundled.shared)
        #expect(reasons.isEmpty)
    }
}
