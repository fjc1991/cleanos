import Foundation
import Security

/// Everything we know about an app that can be used to attribute files to it.
public struct AppIdentity: Hashable, Sendable, Codable {
    public var bundleID: String
    public var name: String
    public var bundleName: String?
    public var fileName: String
    public var executable: String?
    public var subBundleIDs: Set<String>
    public var extensionIDs: Set<String>
    public var groupIDs: Set<String>
    public var iCloudContainerIDs: Set<String>
    public var teamID: String?
    public var developerName: String?
    public var vendor: String?
    public var launchdLabels: Set<String>
    public var processNames: Set<String>
    public var isElectron: Bool
    public var sparkleFeedURL: String?
    public var hasMASReceipt: Bool
    public var urlSchemes: [String]
    public var isNotarized: Bool?

    /// Normalised name variants used for folder matching.
    public var normalizedNames: Set<String> {
        var set: Set<String> = []
        for candidate in [name, bundleName, fileName, executable].compactMap({ $0 }) {
            let n = NameMatcher.normalize(candidate)
            if !n.isEmpty { set.insert(n) }
            let lower = candidate.lowercased()
            if !lower.isEmpty { set.insert(lower) }
        }
        return set
    }

    /// `nektony` for `com.nektony.App-Cleaner-SIII`; falls back to the developer name.
    public var vendorNormalized: String? {
        if let vendor, !vendor.isEmpty { return NameMatcher.normalize(vendor) }
        if let developerName { return NameMatcher.normalizeDeveloper(developerName) }
        return nil
    }

    /// First two components of the bundle ID (`com.microsoft`), used for pkg receipts and plug-in IDs from the same vendor.
    public var vendorPrefix: String? {
        let parts = bundleID.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts.prefix(2).joined(separator: ".").lowercased()
    }

    public init(bundleID: String, name: String, bundleName: String? = nil, fileName: String, executable: String? = nil,
                subBundleIDs: Set<String> = [], extensionIDs: Set<String> = [], groupIDs: Set<String> = [],
                iCloudContainerIDs: Set<String> = [], teamID: String? = nil, developerName: String? = nil, vendor: String? = nil,
                launchdLabels: Set<String> = [], processNames: Set<String> = [], isElectron: Bool = false,
                sparkleFeedURL: String? = nil, hasMASReceipt: Bool = false, urlSchemes: [String] = [], isNotarized: Bool? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.bundleName = bundleName
        self.fileName = fileName
        self.executable = executable
        self.subBundleIDs = subBundleIDs
        self.extensionIDs = extensionIDs
        self.groupIDs = groupIDs
        self.iCloudContainerIDs = iCloudContainerIDs
        self.teamID = teamID
        self.developerName = developerName
        self.vendor = vendor
        self.launchdLabels = launchdLabels
        self.processNames = processNames
        self.isElectron = isElectron
        self.sparkleFeedURL = sparkleFeedURL
        self.hasMASReceipt = hasMASReceipt
        self.urlSchemes = urlSchemes
        self.isNotarized = isNotarized
    }
}

/// Builds an `AppIdentity` by reading the bundle, its nested bundles, its code signature and entitlements.
public enum AppInspector {
    static let nestedBundleExtensions: Set<String> = ["app", "xpc", "framework", "bundle", "appex", "plugin", "kext", "systemextension",
                                                      "dext", "prefpane", "qlgenerator", "mdimporter", "driver", "component"]
    static let genericVendors: Set<String> = ["com", "org", "net", "io", "co", "app", "dev", "me", "us", "uk", "de", "fr", "jp", "cn", "kr", "ru"]

    public static func inspect(bundleURL: URL, shared: SharedIdentifiers) -> AppIdentity? {
        guard let info = infoPlist(at: bundleURL), let bundleID = info["CFBundleIdentifier"] as? String else { return nil }
        let fileName = bundleURL.deletingPathExtension().lastPathComponent
        let bundleName = info["CFBundleName"] as? String
        let displayName = info["CFBundleDisplayName"] as? String
        let executable = info["CFBundleExecutable"] as? String
        let name = displayName ?? bundleName ?? fileName

        var identity = AppIdentity(bundleID: bundleID, name: name, bundleName: bundleName, fileName: fileName, executable: executable)
        identity.sparkleFeedURL = info["SUFeedURL"] as? String
        identity.hasMASReceipt = FileManager.default.fileExists(atPath: bundleURL.appending(path: "Contents/_MASReceipt/receipt").path)
        identity.urlSchemes = ((info["CFBundleURLTypes"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        identity.vendor = vendorSegment(of: bundleID)
        if let privileged = info["SMPrivilegedExecutables"] as? [String: Any] {
            identity.launchdLabels.formUnion(privileged.keys)
        }
        if let executable { identity.processNames.insert(executable) }

        scanNestedBundles(in: bundleURL, shared: shared, identity: &identity)
        scanLaunchdPlists(in: bundleURL, identity: &identity)
        applySigningInformation(bundleURL: bundleURL, identity: &identity)
        identity.isElectron = FileManager.default.fileExists(atPath: bundleURL.appending(path: "Contents/Frameworks/Electron Framework.framework").path)
        return identity
    }

    public static func infoPlist(at bundleURL: URL) -> [String: Any]? {
        for subpath in ["Contents/Info.plist", "Resources/Info.plist", "Versions/Current/Resources/Info.plist", "Info.plist"] {
            let url = bundleURL.appending(path: subpath)
            if let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return plist
            }
        }
        return nil
    }

    static func vendorSegment(of bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return nil }
        let vendor = parts[1]
        return genericVendors.contains(vendor.lowercased()) ? nil : vendor
    }

    static func scanNestedBundles(in bundleURL: URL, shared: SharedIdentifiers, identity: inout AppIdentity) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return }
        var found = 0
        for case let url as URL in enumerator {
            if enumerator.level > 10 { enumerator.skipDescendants(); continue }
            let ext = url.pathExtension.lowercased()
            guard nestedBundleExtensions.contains(ext) else { continue }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            found += 1
            if found > 600 { break }
            guard let info = infoPlist(at: url), let id = info["CFBundleIdentifier"] as? String else { continue }
            if let exe = info["CFBundleExecutable"] as? String { identity.processNames.insert(exe) }
            if shared.isShared(bundleID: id) { continue }
            if ext == "appex" { identity.extensionIDs.insert(id) } else if id != identity.bundleID { identity.subBundleIDs.insert(id) }
            if ext == "app", let privileged = info["SMPrivilegedExecutables"] as? [String: Any] {
                identity.launchdLabels.formUnion(privileged.keys)
            }
            if ext == "framework" { enumerator.skipDescendants() }
        }
    }

    static func scanLaunchdPlists(in bundleURL: URL, identity: inout AppIdentity) {
        for folder in ["Contents/Library/LaunchAgents", "Contents/Library/LaunchDaemons", "Contents/Library/LaunchServices", "Contents/Resources"] {
            let dir = bundleURL.appending(path: folder)
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: item),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = plist["Label"] as? String else { continue }
                identity.launchdLabels.insert(label)
            }
            if folder.hasSuffix("LaunchServices") {
                for item in items where item.pathExtension.isEmpty { identity.launchdLabels.insert(item.lastPathComponent) }
            }
        }
        let loginItems = bundleURL.appending(path: "Contents/Library/LoginItems")
        if let items = try? FileManager.default.contentsOfDirectory(at: loginItems, includingPropertiesForKeys: nil) {
            for item in items where item.pathExtension == "app" {
                if let info = infoPlist(at: item), let id = info["CFBundleIdentifier"] as? String { identity.launchdLabels.insert(id) }
            }
        }
    }

    static func applySigningInformation(bundleURL: URL, identity: inout AppIdentity) {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess, let dict = info as? [String: Any] else { return }
        identity.teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        if let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            identity.developerName = developerName(fromSubject: summary)
        }
        if let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            if let groups = entitlements["com.apple.security.application-groups"] as? [String] { identity.groupIDs.formUnion(groups) }
            if let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] { identity.iCloudContainerIDs.formUnion(containers) }
            if let ubiquity = entitlements["com.apple.developer.ubiquity-container-identifiers"] as? [String] { identity.iCloudContainerIDs.formUnion(ubiquity) }
        }
        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple generic and notarized" as CFString, [], &requirement) == errSecSuccess, let requirement {
            identity.isNotarized = SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
        }
    }

    /// `Developer ID Application: Anthropic PBC (Q6L3S6S2XJ)` → `Anthropic PBC`; `Apple Mac OS Application Signing` → `Apple`.
    static func developerName(fromSubject subject: String) -> String {
        var name = subject
        if let colon = name.range(of: ": ") { name = String(name[colon.upperBound...]) }
        if let paren = name.range(of: " (", options: .backwards) { name = String(name[..<paren.lowerBound]) }
        if name.hasPrefix("Apple ") { return "Apple" }
        return name.trimmingCharacters(in: .whitespaces)
    }
}
