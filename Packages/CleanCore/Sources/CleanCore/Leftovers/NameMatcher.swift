import Foundation

/// How a child name is reduced to an identifier before matching.
public enum NameStyle: String, Codable, Sendable {
    case folder, plist, byHostPlist, savedState, sfl, binarycookies, crashReport, helpCache, container, iCloudContainer,
         mobileDocuments, cloudStorage, autosave, log, dotfile, bundleName, receipt, json
}

/// Name normalisation and the string-matching half of the identity rules.
public enum NameMatcher {
    static let bundleExtensions: Set<String> = [
        "app", "plugin", "kext", "prefpane", "qlgenerator", "mdimporter", "saver", "component", "vst", "vst3", "clap", "driver",
        "framework", "bundle", "fs", "service", "workflow", "appex", "systemextension", "dext", "xpc", "mailbundle", "wdgt",
        "action", "colorpicker", "dictionary", "inputplugin", "keylayout", "menu", "osax", "scpt", "ppd", "ds", "plugin", "otf", "ttf",
        "jdk", "safariextz", "lproj"
    ]

    static let developerSuffixes: Set<String> = ["llc", "inc", "ltd", "gmbh", "corp", "corporation", "co", "limited", "pbc", "software",
                                                 "labs", "technologies", "technology", "sa", "srl", "ag", "bv", "oy", "ab", "pty", "plc", "lp", "the"]

    /// Lowercase, drop `.app`, remove everything that is not a letter or digit, strip a trailing version (`bartender 6` → `bartender`).
    public static func normalize(_ string: String) -> String {
        var s = string.lowercased()
        if s.hasSuffix(".app") { s.removeLast(4) }
        s = stripVersion(s)
        return s.filter { $0.isLetter || $0.isNumber }
    }

    /// Removes a trailing ` 6`, ` 10.0.1`, ` v2` or `-2024`.
    public static func stripVersion(_ string: String) -> String {
        let pattern = #"[\s_\-]+v?\d+(\.\d+)*\s*$"#
        return string.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    /// Normalises a developer name: `Nektony LLC` → `nektony`, `Paragon Software GmbH` → `paragon`.
    public static func normalizeDeveloper(_ name: String) -> String {
        let words = name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            .filter { !developerSuffixes.contains($0) }
        return words.joined()
    }

    static let uuidSuffix = try! NSRegularExpression(pattern: #"\.[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"#)
    static let hex32 = try! NSRegularExpression(pattern: #"^[0-9a-fA-F]{32}$"#)

    /// Candidate identifier strings (lowercased) a child name may represent under the given style.
    public static func reduce(_ fileName: String, style: NameStyle) -> [String] {
        var name = fileName
        switch style {
        case .folder:
            break
        case .plist:
            name = strip(name, suffixes: [".plist"])
            name = strip(name, suffixes: [".LSSharedFileList"])
        case .byHostPlist:
            name = strip(name, suffixes: [".plist"])
            name = uuidSuffix.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "")
        case .savedState:
            name = strip(name, suffixes: [".savedState"])
        case .sfl:
            name = strip(name, suffixes: [".sfl3", ".sfl2", ".sfl"])
        case .binarycookies:
            name = strip(name, suffixes: [".binarycookies"])
        case .crashReport:
            name = strip(name, suffixes: [".ips", ".crash", ".diag", ".plist", ".hang", ".spin", ".panic"])
            if let range = name.range(of: #"[_-]\d{4}-\d{2}-\d{2}.*$"#, options: .regularExpression) { name = String(name[..<range.lowerBound]) }
            if let range = name.range(of: #"_[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27,}$"#, options: .regularExpression) { name = String(name[..<range.lowerBound]) }
            if let range = name.range(of: #"_\d{4}-\d{2}-\d{2}.*$"#, options: .regularExpression) { name = String(name[..<range.lowerBound]) }
        case .helpCache:
            if let range = name.range(of: ".help") { name = String(name[..<range.lowerBound]) }
        case .container:
            break
        case .iCloudContainer:
            name = strip(name, suffixes: [".plist"])
            if name.lowercased().hasPrefix("icloud.") { name = String(name.dropFirst(7)) }
        case .mobileDocuments:
            let parts = name.split(separator: "~").map(String.init)
            guard parts.count >= 2 else { return [name.lowercased()] }
            let team = parts[0]
            let bundle = parts.dropFirst().joined(separator: ".")
            return [bundle.lowercased(), team.lowercased()]
        case .cloudStorage:
            if let dash = name.firstIndex(of: "-") { name = String(name[..<dash]) }
        case .autosave:
            name = name.replacingOccurrences(of: #"^Unsaved\s+"#, with: "", options: .regularExpression)
            name = name.replacingOccurrences(of: #"\s+Document.*$"#, with: "", options: .regularExpression)
        case .log:
            name = strip(name, suffixes: [".log", ".txt", ".gz", ".bz2", ".out", ".err"])
            name = name.replacingOccurrences(of: #"[_.-](debug|install|service|agent|daemon|\d+)$"#, with: "", options: .regularExpression)
        case .dotfile:
            guard name.hasPrefix(".") else { return [] }
            name = String(name.dropFirst())
            name = strip(name, suffixes: [".json", ".yaml", ".yml", ".toml", ".ini", ".conf", ".cfg", ".plist", "-home-pointer"])
            name = name.replacingOccurrences(of: #"[_-](settings|config|rc|history|cache|data)$"#, with: "", options: .regularExpression)
        case .bundleName:
            let ext = (name as NSString).pathExtension.lowercased()
            if bundleExtensions.contains(ext) { name = (name as NSString).deletingPathExtension }
        case .receipt:
            name = strip(name, suffixes: [".bom", ".plist"])
        case .json:
            name = strip(name, suffixes: [".json"])
        }
        return [name.lowercased()]
    }

    static func strip(_ name: String, suffixes: [String]) -> String {
        for suffix in suffixes where name.lowercased().hasSuffix(suffix.lowercased()) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// The identity signals the catalogue can name.
    public enum Signal: String, Sendable {
        case bundleID, subBundleID, extensionID, groupID, teamGroup, iCloudID, name, executable, processName, vendor, label
        // content-based signals resolved by the locator, listed here so the catalogue can name them
        case launchdProgram, symlinkIntoApp, aliasIntoApp, jsonPathIntoApp, fileContentIntoApp, pluginBundleID, pkgReceipt
    }

    /// Tests the reduced child names against the identity. Returns the human-readable reasons, empty when nothing matched.
    public static func match(reduced: [String], identity: AppIdentity, allowed: Set<String>, shared: SharedIdentifiers) -> [String] {
        var reasons: [String] = []
        let bundleID = identity.bundleID.lowercased()
        for candidate in reduced {
            let c = candidate.lowercased()
            if c.isEmpty { continue }
            if allowed.contains(Signal.bundleID.rawValue), idMatches(c, bundleID) {
                reasons.append("bundle ID")
            }
            if allowed.contains(Signal.subBundleID.rawValue) {
                for sub in identity.subBundleIDs where !shared.isShared(bundleID: sub) && idMatches(c, sub.lowercased()) && sub.lowercased() != bundleID {
                    reasons.append("helper bundle ID \(sub)")
                    break
                }
            }
            if allowed.contains(Signal.extensionID.rawValue) {
                for ext in identity.extensionIDs where idMatches(c, ext.lowercased()) {
                    reasons.append("extension ID \(ext)")
                    break
                }
            }
            if allowed.contains(Signal.groupID.rawValue) {
                for group in identity.groupIDs where c == group.lowercased() || c.hasPrefix(group.lowercased() + ".") {
                    reasons.append("app group \(group)")
                    break
                }
            }
            if allowed.contains(Signal.teamGroup.rawValue), let team = identity.teamID?.lowercased(), !team.isEmpty,
               c.hasPrefix(team + ".") || c == team {
                reasons.append("team ID \(identity.teamID ?? "")")
            }
            if allowed.contains(Signal.iCloudID.rawValue) {
                for container in identity.iCloudContainerIDs where idMatches(c, container.lowercased()) {
                    reasons.append("iCloud container \(container)")
                    break
                }
            }
            if allowed.contains(Signal.name.rawValue), nameMatches(c, identity: identity, shared: shared) {
                reasons.append("app name")
            }
            if allowed.contains(Signal.executable.rawValue), let exe = identity.executable {
                let n = normalize(exe)
                if n.count >= 5, !shared.isGenericName(n), normalize(c) == n { reasons.append("executable name") }
            }
            if allowed.contains(Signal.processName.rawValue) {
                let n = normalize(c)
                if n.count >= 4, !shared.isGenericName(n),
                   identity.processNames.contains(where: { normalize($0) == n }) || normalize(identity.name) == n {
                    reasons.append("process name")
                }
            }
            if allowed.contains(Signal.vendor.rawValue), let vendor = identity.vendorNormalized, vendor.count >= 4,
               !shared.isGenericName(vendor), normalize(c) == vendor {
                reasons.append("vendor folder")
            }
            if allowed.contains(Signal.label.rawValue) {
                for label in identity.launchdLabels where c == label.lowercased() {
                    reasons.append("launchd label")
                    break
                }
            }
        }
        return Array(NSOrderedSet(array: reasons)) as? [String] ?? reasons
    }

    static func idMatches(_ candidate: String, _ id: String) -> Bool {
        guard !id.isEmpty, id.contains(".") else { return candidate == id }
        return candidate == id || candidate.hasPrefix(id + ".") || candidate.hasPrefix(id + "-") || candidate.hasPrefix(id + "_")
    }

    static func nameMatches(_ candidate: String, identity: AppIdentity, shared: SharedIdentifiers) -> Bool {
        let normalizedCandidate = normalize(candidate)
        guard !normalizedCandidate.isEmpty, !shared.isGenericName(normalizedCandidate) else { return false }
        for name in identity.normalizedNames {
            if name.count >= 5, normalizedCandidate == name { return true }
            if name.count == 4, candidate == name { return true }   // "zoom" → exact raw match only
        }
        return false
    }
}
