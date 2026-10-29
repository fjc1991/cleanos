import Foundation

/// Orphaned service files, registrations and installer traces of software that is no longer installed,
/// grouped by the app or software family they belonged to.
public struct RemainsScanResult: Sendable {
    public let groups: [ScanItem]
    public let duration: TimeInterval
    public var totalSize: Int64 { groups.reduce(0) { $0 + $1.size } }
}

/// How sure the engine is that a group really is a leftover.
public enum RemainsConfidence: String, Sendable, Comparable {
    case low, medium, high
    private var rank: Int { self == .high ? 2 : self == .medium ? 1 : 0 }
    public static func < (lhs: RemainsConfidence, rhs: RemainsConfidence) -> Bool { lhs.rank < rhs.rank }
    public var title: String { rawValue.capitalized + " confidence" }
}

/// Seven passes, each contributing orphans with a reason and a confidence:
/// 1. leftovers of apps that disappeared since the last catalog snapshot (precise deep dive);
/// 2. identifier-shaped names in the catalogue roots that no installed app owns;
/// 3. package receipts whose software is gone, with whatever payload still exists;
/// 4. known software families (updaters, helpers, agents) whose app is not installed;
/// 5. installer temporary folders;
/// 6. crash reports of processes that no longer exist;
/// 7. registrations (Launch Services, Dock, notifications, permissions, keychain, firewall, plug-ins) pointing at missing apps;
/// plus broken pointers (launchd plists, symlinks, native-messaging hosts whose targets are gone).
/// Orphans are then clustered by family tokens so every trace of one product lands in one group.
public actor RemainsLocator {
    public let rules: Rules
    private let home: String
    private let registrations: RegistrationReader?

    public init(rules: Rules = .bundled, home: String = NSHomeDirectory(), registrations: RegistrationReader? = nil) {
        self.rules = rules
        self.home = home
        self.registrations = registrations
    }

    struct Orphan {
        var url: URL?
        var item: ScanItem?               // pre-built registration items
        var ownerKey: String
        var ownerTitle: String
        var group: String
        var tier: RiskTier
        var needsRoot: Bool
        var matchedBy: [String]
        var subtitle: String?
        var confidence: RemainsConfidence
        var familyID: String?
        var path: String { url?.standardizedFileURL.path ?? item?.id ?? "" }
    }

    static let bundleIDPattern = try! NSRegularExpression(pattern: #"^[a-z0-9][a-z0-9_-]*(\.[a-z0-9][a-z0-9_-]*){2,}$"#, options: .caseInsensitive)
    static let teamPrefixPattern = try! NSRegularExpression(pattern: #"^[A-Z0-9]{10}\.[^/]+$"#)
    static let roots: Set<String> = ["user-app-support", "user-caches", "user-preferences", "user-preferences-byhost", "user-containers",
                                     "user-group-containers", "user-application-scripts", "user-httpstorages", "user-cookies", "user-webkit",
                                     "user-saved-state", "user-logs", "user-launch-agents", "user-recent-documents", "user-darwin-cache",
                                     "user-darwin-temp", "user-core-spotlight", "user-synced-preferences", "user-mobile-documents", "local-app-support",
                                     "local-caches", "local-preferences", "local-launch-agents", "local-launch-daemons", "local-privileged-helpers",
                                     "local-logs", "tmp"]
    static let installerTempPatterns = ["KSInstallAction.*", "KSDownloadAction.*", "KSOutOfProcessFetcher.*", "com.google.Keystone", "*.pkg", "*.dmg",
                                        "*Installer*", "*installer*", "*.mpkg", "Adobe*", "com.adobe.*", "com.microsoft.*", "msupdate*"]

    /// - Parameter appLocations: folders that hold applications, checked for broken bundles (no Info.plist, missing executable).
    public func locate(installed: [InstalledApp], previouslyInstalled: [InstalledApp] = [], runningBundleIDs: Set<String> = [],
                       skipList: [String] = [], appLocations: [URL] = [URL(filePath: "/Applications"), URL(filePath: NSHomeDirectory() + "/Applications")]) async -> RemainsScanResult {
        let start = Date()
        let identities = installed.map(\.identity)
        let installedIDs = Set(identities.flatMap { [$0.bundleID] + Array($0.subBundleIDs) + Array($0.extensionIDs) }.map { $0.lowercased() })
        let installedTeams = Set(identities.compactMap { $0.teamID?.lowercased() })
        let installedGroups = Set(identities.flatMap { $0.groupIDs }.map { $0.lowercased() })
        let installedVendorPrefixes = Set(identities.compactMap(\.vendorPrefix))
        let installedProcessNames = Set(identities.flatMap { Array($0.processNames) + [$0.name, $0.fileName] + ($0.executable.map { [$0] } ?? []) }.map { NameMatcher.normalize($0) })
        let running = Set(runningBundleIDs.map { $0.lowercased() })
        let runningProcessNames = Set(ProcessMonitor.snapshot().map { NameMatcher.normalize($0.name) })
        let absentFamilies = rules.families.filter { family in
            !family.bundleIDPrefixes.contains { prefix in installedIDs.contains { $0.hasPrefix(prefix.lowercased()) } }
        }
        // Vendor rules of installed apps claim their paths and launchd labels (Dropbox's crashpad group, Paragon's installer helper…).
        var claimedByInstalled: Set<String> = []
        var ownedLabels: Set<String> = []
        for identity in identities {
            for override in rules.overrides.matching(bundleID: identity.bundleID) {
                for include in override.include ?? [] {
                    for path in PathExpander.glob(PathExpander.expand(include.path, home: home)) {
                        claimedByInstalled.insert(URL(filePath: path).standardizedFileURL.path)
                        let name = URL(filePath: path).deletingPathExtension().lastPathComponent.lowercased()
                        if name.contains(".") { ownedLabels.insert(name) }
                    }
                    // Patterns such as ~/Library/Preferences/com.dropbox.*.plist claim every matching identifier.
                    let pattern = URL(filePath: include.path).deletingPathExtension().lastPathComponent.lowercased()
                    if pattern.contains("*"), pattern.contains(".") { ownedLabels.insert(pattern) }
                }
                ownedLabels.formUnion((override.launchdLabels ?? []).map { $0.lowercased() })
                ownedLabels.formUnion((override.pkgReceipts ?? []).map { $0.lowercased() })
            }
            ownedLabels.formUnion(identity.launchdLabels.map { $0.lowercased() })
        }
        var orphans: [Orphan] = []

        // 1. Apps that disappeared since the last snapshot.
        let installedPaths = Set(installed.map { $0.url.standardizedFileURL.path })
        let removedApps = previouslyInstalled.filter { !installedPaths.contains($0.url.standardizedFileURL.path) && !installedIDs.contains($0.bundleID.lowercased()) }
        let locator = LeftoverLocator(rules: rules, home: home)
        var claimed: Set<String> = []
        for removed in removedApps {
            let result = await locator.locate(app: removed, otherApps: installed, includeExecutable: false, skipList: skipList)
            for item in result.allItems {
                guard let url = item.url else { continue }
                claimed.insert(url.standardizedFileURL.path)
                orphans.append(Orphan(url: url, item: nil, ownerKey: "app:\(removed.bundleID.lowercased())", ownerTitle: removed.name, group: item.group, tier: item.tier,
                                      needsRoot: item.needsRoot, matchedBy: ["left by \(removed.name), uninstalled"] + item.matchedBy, subtitle: item.subtitle, confidence: .high, familyID: nil))
            }
        }

        // 3. Package receipts (before the roots so their payload is attributed to the package).
        let receiptOrphans = receiptLeftovers(identities: identities, installedAppPaths: installed.map { $0.url.standardizedFileURL.path },
                                              installedVendorPrefixes: installedVendorPrefixes, absentFamilies: absentFamilies, installedIDs: installedIDs,
                                              ownedLabelsForReceipts: ownedLabels)
        for orphan in receiptOrphans { if let url = orphan.url { claimed.insert(url.standardizedFileURL.path) } }
        orphans.append(contentsOf: receiptOrphans)

        // 4. Known families whose app is gone.
        let familyOrphans = familyLeftovers(absentFamilies)
        for orphan in familyOrphans { if let url = orphan.url { claimed.insert(url.standardizedFileURL.path) } }
        orphans.append(contentsOf: familyOrphans)

        // 2. Identifier-shaped names in the catalogue roots.
        for rule in rules.catalogue.roots where Self.roots.contains(rule.id) {
            for rootPath in rule.allRoots {
                let expanded = PathExpander.expand(rootPath, home: home)
                guard let children = try? FileManager.default.contentsOfDirectory(at: URL(filePath: expanded), includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
                let skip = Set((rule.skipChildren ?? []).map { $0.lowercased() })
                for child in children {
                    let name = child.lastPathComponent
                    if name == ".DS_Store" || name == ".localized" || skip.contains(name.lowercased()) { continue }
                    let path = child.standardizedFileURL.path
                    if claimed.contains(path) || claimedByInstalled.contains(path) { continue }
                    if rule.id == "tmp" {
                        if let orphan = installerTempOrphan(child, rule: rule) { orphans.append(orphan) }
                        continue
                    }
                    guard let candidate = NameMatcher.reduce(name, style: rule.nameStyle).first, !candidate.isEmpty else { continue }
                    guard let shape = Self.identifierShape(candidate, original: name) else { continue }
                    if rules.protectedRules.isProtected(bundleID: candidate) || rules.shared.isShared(bundleID: candidate) { continue }
                    if rules.protectedRules.isProtected(path, home: home) { continue }
                    if Self.isOwned(candidate, shape: shape, installedIDs: installedIDs, installedTeams: installedTeams, installedGroups: installedGroups, running: running) { continue }
                    if ownedLabels.contains(where: { fnmatch($0, candidate, 0) == 0 }) { continue }
                    if identities.contains(where: { !NameMatcher.match(reduced: [candidate], identity: $0, allowed: ["bundleID", "subBundleID", "extensionID", "groupID", "teamGroup", "iCloudID", "name", "label"], shared: rules.shared).isEmpty }) { continue }
                    if ["user-launch-agents", "local-launch-agents", "local-launch-daemons"].contains(rule.id), Self.launchdProgramExists(child) { continue }

                    var tier = rule.tier
                    var subtitle: String?
                    var reasons = ["no installed app owns \(candidate)"]
                    var confidence: RemainsConfidence = .medium
                    if shape == .bundleID, let vendor = Self.vendorPrefix(of: candidate), installedVendorPrefixes.contains(vendor) {
                        tier = max(tier, .caution)
                        subtitle = "Same developer as an installed app; may be a shared component"
                        reasons.append("vendor prefix \(vendor) still installed")
                        confidence = .low
                    }
                    if rule.id == "user-mobile-documents" { subtitle = "iCloud container, possibly from an iPhone or iPad app"; confidence = .low }
                    let (ownerKey, ownerTitle) = Self.owner(for: candidate, shape: shape, original: name)
                    orphans.append(Orphan(url: child, item: nil, ownerKey: ownerKey, ownerTitle: ownerTitle, group: rule.group, tier: tier,
                                          needsRoot: rule.requiresRoot, matchedBy: reasons, subtitle: subtitle, confidence: confidence, familyID: nil))
                }
            }
        }

        // 6. Crash reports of processes that no longer exist.
        orphans.append(contentsOf: crashReportLeftovers(installedProcessNames: installedProcessNames, runningProcessNames: runningProcessNames))

        // Broken pointers and broken app bundles.
        orphans.append(contentsOf: brokenPointers())
        orphans.append(contentsOf: brokenBundles(locations: appLocations, installedPaths: installedPaths))

        // 7. Registrations that point at missing apps.
        if let registrations {
            orphans.append(contentsOf: registrationLeftovers(reader: registrations, installedIDs: installedIDs, installedPaths: installedPaths,
                                                             installedProcessNames: installedProcessNames))
        }

        // Cluster by family tokens, apply the skip list, dedupe.
        var byPath: [String: Orphan] = [:]
        for var orphan in orphans {
            let path = orphan.path
            if skipList.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            if orphan.familyID == nil, let family = Self.family(for: path, in: absentFamilies) {
                orphan.familyID = family.id
                orphan.ownerKey = "family:\(family.id)"
                orphan.ownerTitle = family.displayName
                orphan.matchedBy.append("matches the \(family.displayName) family")
                if orphan.confidence < .medium, orphan.group != "Cloud" { orphan.confidence = .medium }
            }
            if var existing = byPath[path] {
                // The same trace found by several passes: keep the strongest verdict and every reason.
                existing.confidence = max(existing.confidence, orphan.confidence)
                existing.matchedBy = Array(NSOrderedSet(array: existing.matchedBy + orphan.matchedBy)) as? [String] ?? existing.matchedBy
                if existing.familyID == nil, let family = orphan.familyID { existing.familyID = family; existing.ownerKey = orphan.ownerKey; existing.ownerTitle = orphan.ownerTitle }
                if existing.subtitle == nil { existing.subtitle = orphan.subtitle }
                byPath[path] = existing
            } else {
                byPath[path] = orphan
            }
        }
        let unique = Array(byPath.values)

        // Sizes and grouping.
        let urls = unique.compactMap { $0.item == nil ? $0.url : nil }
        let sizes = await DirectorySizer.sizes(of: urls, maxConcurrency: 6)
        var byOwner: [String: (title: String, items: [ScanItem], confidence: RemainsConfidence)] = [:]
        for orphan in unique {
            let item: ScanItem
            if let prebuilt = orphan.item {
                item = prebuilt
            } else if let url = orphan.url {
                let size = sizes[url]
                item = ScanItem(url: url, title: url.lastPathComponent, subtitle: orphan.subtitle ?? displayPath(url),
                                kind: (size?.directoryCount ?? 0) > 0 ? .directory : .file, group: orphan.group, size: size?.bytes ?? 0,
                                tier: orphan.tier, matchedBy: orphan.matchedBy, needsRoot: orphan.needsRoot,
                                modificationDate: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                                payload: ["confidence": orphan.confidence.rawValue])
            } else { continue }
            var entry = byOwner[orphan.ownerKey] ?? (orphan.ownerTitle, [], orphan.confidence)
            entry.items.append(item)
            entry.confidence = max(entry.confidence, orphan.confidence)
            byOwner[orphan.ownerKey] = entry
        }
        let groups = byOwner.map { key, value -> ScanItem in
            let children = value.items.sorted { (LeftoverGroups.rank($0.group), $1.size) < (LeftoverGroups.rank($1.group), $0.size) }
            let newest = children.compactMap(\.modificationDate).max()
            let summary = [value.confidence.title, children.count == 1 ? "1 item" : "\(children.count) items", newest.map { $0.formatted(.dateTime.day().month().year()) }].compactMap { $0 }.joined(separator: " · ")
            return ScanItem(id: "remains:\(key)", title: value.title, subtitle: summary, kind: .group, group: "Remains", modificationDate: newest,
                            children: children, payload: ["confidence": value.confidence.rawValue]).rollingUpSizes()
        }
        .sorted { lhs, rhs in
            let l = RemainsConfidence(rawValue: lhs.payload["confidence"] ?? "low") ?? .low
            let r = RemainsConfidence(rawValue: rhs.payload["confidence"] ?? "low") ?? .low
            if l != r { return l > r }
            return lhs.size > rhs.size
        }
        return RemainsScanResult(groups: groups, duration: Date().timeIntervalSince(start))
    }

    // MARK: - Pass 3: package receipts

    private func receiptLeftovers(identities: [AppIdentity], installedAppPaths: [String], installedVendorPrefixes: Set<String>, absentFamilies: [LeftoverFamily], installedIDs: Set<String>, ownedLabelsForReceipts: Set<String> = []) -> [Orphan] {
        var out: [Orphan] = []
        let installedFamilies = rules.families.filter { family in !absentFamilies.contains { $0.id == family.id } }
        for identifier in PackageReceipts.identifiers() {
            let lower = identifier.lowercased()
            if rules.protectedRules.isProtected(bundleID: lower) { continue }
            // Owned by an installed app: same vendor prefix and the product name appears in the package id.
            let normalizedID = NameMatcher.normalize(lower.replacingOccurrences(of: ".", with: " "))
            let owned = identities.contains { identity in
                guard let prefix = identity.vendorPrefix, lower.hasPrefix(prefix + ".") else { return false }
                let names = identity.normalizedNames.filter { $0.count >= 4 }
                let last = identity.bundleID.split(separator: ".").last.map { NameMatcher.normalize(String($0)) } ?? ""
                return names.contains { normalizedID.contains($0) } || (last.count >= 4 && normalizedID.contains(last))
            }
            if owned { continue }
            if installedFamilies.contains(where: { $0.pkgReceipts.contains { fnmatch($0.lowercased(), lower, 0) == 0 } }) { continue }
            if installedIDs.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") }) { continue }
            // Packages that install only shared infrastructure (e.g. Rosetta, fonts) are kept unless a family claims them.
            let family = absentFamilies.first { $0.pkgReceipts.contains { fnmatch($0.lowercased(), lower, 0) == 0 } }
            guard let info = PackageReceipts.info(identifier) else { continue }
            let payload = PackageReceipts.payloadPaths(manifest: PackageReceipts.manifest(identifier), base: info.base)
            let existing = payload.filter(\.exists)
            // A payload folder that still contains an installed app (or any .app) means the software is simply pkg-installed.
            let containsInstalledApp = existing.contains { entry in
                installedAppPaths.contains { $0.hasPrefix(entry.path + "/") || entry.path.hasPrefix($0) } || Self.containsAppBundle(entry.path)
            }
            if containsInstalledApp && family == nil { continue }
            // Without a family, only receipts whose payload is mostly gone are leftovers (printer drivers, CLI tools and fonts stay).
            if family == nil, !payload.isEmpty, existing.count * 2 > payload.count { continue }
            if family == nil, let vendor = Self.vendorPrefix(of: lower), installedVendorPrefixes.contains(vendor) { continue }
            if family == nil, ownedLabelsForReceipts.contains(where: { fnmatch($0, lower, 0) == 0 }) { continue }
            let productTitle = Self.receiptTitle(identifier)
            let ownerKey = family.map { "family:\($0.id)" } ?? "receipt:\(lower)"
            let ownerTitle = family?.displayName ?? productTitle
            let detail = [info.version.map { "version \($0)" }, info.installDate.map { "installed \($0.formatted(.dateTime.day().month().year()))" },
                          "\(existing.count) of \(payload.count) installed paths still present"].compactMap { $0 }.joined(separator: " · ")
            var receiptItem = ScanItem(id: "registration:pkgReceipt:\(identifier)", title: "Package receipt \(identifier)", subtitle: detail, kind: .registration,
                                       group: "Receipts", size: 0, tier: .safe, matchedBy: ["package receipt with no installed owner"], needsRoot: true,
                                       modificationDate: info.installDate, payload: ["type": "pkgReceipt", "identifier": identifier, "confidence": family == nil ? "medium" : "high"])
            receiptItem.payload["confidence"] = family == nil ? "medium" : "high"
            out.append(Orphan(url: nil, item: receiptItem, ownerKey: ownerKey, ownerTitle: ownerTitle, group: "Receipts", tier: .safe, needsRoot: true,
                              matchedBy: receiptItem.matchedBy, subtitle: detail, confidence: family == nil ? .medium : .high, familyID: family?.id))
            for entry in existing {
                let url = URL(filePath: entry.path)
                if rules.protectedRules.isProtected(entry.path, home: home) { continue }
                if installedAppPaths.contains(where: { entry.path.hasPrefix($0) }) { continue }
                let group = entry.path.hasPrefix("/Library/LaunchAgents") || entry.path.hasPrefix("/Library/LaunchDaemons") || entry.path.hasPrefix("/Library/PrivilegedHelperTools") ? "Login Items"
                    : entry.path.hasPrefix("/Applications") ? "Executables" : entry.path.hasPrefix("/usr/local") ? "CLI Tools" : "Application Support"
                out.append(Orphan(url: url, item: nil, ownerKey: ownerKey, ownerTitle: ownerTitle, group: group, tier: .normal,
                                  needsRoot: !FileRemover.isUserRemovable(url), matchedBy: ["installed by package \(identifier)"], subtitle: nil,
                                  confidence: family == nil ? .medium : .high, familyID: family?.id))
            }
        }
        return out
    }

    /// `com.google.pkg.ChromeRemoteDesktopHostService` → `Chrome Remote Desktop Host Service (Google)`.
    static func receiptTitle(_ identifier: String) -> String {
        var parts = identifier.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return identifier }
        let vendor = parts.count >= 3 ? parts[1] : parts[0]
        if parts.count >= 3 { parts.removeFirst() }   // top-level domain
        parts.removeAll { ["pkg", "package", "packages", "installer", "pkgs", vendor].contains($0.lowercased()) }
        let product = parts.joined(separator: " ")
            .replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
        return product.isEmpty ? identifier : "\(product) (\(vendor.capitalized))"
    }

    // MARK: - Pass 4: families

    private func familyLeftovers(_ families: [LeftoverFamily]) -> [Orphan] {
        var out: [Orphan] = []
        let fm = FileManager.default
        for family in families {
            for pattern in family.paths {
                for path in PathExpander.glob(PathExpander.expand(pattern, home: home)) {
                    if rules.protectedRules.isProtected(path, home: home) { continue }
                    let url = URL(filePath: path)
                    let group = Self.group(forPath: path, home: home)
                    out.append(Orphan(url: url, item: nil, ownerKey: "family:\(family.id)", ownerTitle: family.displayName, group: group,
                                      tier: group == "User Data" ? .caution : .normal, needsRoot: !FileRemover.isUserRemovable(url),
                                      matchedBy: ["known \(family.displayName) location, app not installed"], subtitle: nil, confidence: .high, familyID: family.id))
                }
            }
            for dir in ["/Library/LaunchAgents", "/Library/LaunchDaemons", home + "/Library/LaunchAgents"] {
                for plist in (try? fm.contentsOfDirectory(at: URL(filePath: dir), includingPropertiesForKeys: nil)) ?? [] where plist.pathExtension == "plist" {
                    let label = plist.deletingPathExtension().lastPathComponent.lowercased()
                    guard family.launchdLabels.contains(where: { fnmatch($0.lowercased(), label, 0) == 0 }) else { continue }
                    out.append(Orphan(url: plist, item: nil, ownerKey: "family:\(family.id)", ownerTitle: family.displayName, group: "Login Items", tier: .normal,
                                      needsRoot: !FileRemover.isUserRemovable(plist), matchedBy: ["\(family.displayName) launchd job, app not installed"], subtitle: nil,
                                      confidence: .high, familyID: family.id))
                }
            }
        }
        return out
    }

    static func family(for path: String, in families: [LeftoverFamily]) -> LeftoverFamily? {
        let normalized = NameMatcher.normalize(path.replacingOccurrences(of: "/", with: " "))
        return families.first { family in family.normalizedTokens.contains { normalized.contains($0) } }
    }

    static func group(forPath path: String, home: String) -> String {
        let p = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        if p.contains("/LaunchAgents/") || p.contains("/LaunchDaemons/") || p.contains("/PrivilegedHelperTools/") { return "Login Items" }
        if p.hasPrefix("~/Library/Caches") || p.hasPrefix("/Library/Caches") { return "Caches" }
        if p.hasPrefix("~/Library/Preferences") || p.hasPrefix("/Library/Preferences") { return "Preferences" }
        if p.hasPrefix("~/Library/Logs") || p.hasPrefix("/Library/Logs") { return "Logs" }
        if p.hasPrefix("~/Library/Containers") || p.hasPrefix("~/Library/Group Containers") { return "Containers" }
        if p.hasPrefix("~/Library/HTTPStorages") || p.hasPrefix("~/Library/WebKit") { return "Web Storage" }
        if p.hasPrefix("~/Library/Saved Application State") { return "Saved State" }
        if p.hasPrefix("~/.") { return "Dotfiles" }
        if p.hasPrefix("~/Documents") || p.hasPrefix("~/Desktop") || p.hasPrefix("~/Creative") || p.hasPrefix("~/Applications (") { return "User Data" }
        if p.hasPrefix("/private/tmp") || p.contains("/T/") { return "Temporary Files" }
        if p.hasPrefix("/usr/local") || p.hasPrefix("/opt") { return "CLI Tools" }
        if p.hasPrefix("/Applications") { return "Executables" }
        if p.hasPrefix("/Users/Shared") { return "Shared" }
        if p.contains("/Internet Plug-Ins/") || p.contains("/PreferencePanes/") || p.contains("/Extensions/") { return "Extensions" }
        if p.contains("NativeMessagingHosts") { return "Browser Integration" }
        return "Application Support"
    }

    // MARK: - Pass 5: installer temporary folders

    private func installerTempOrphan(_ url: URL, rule: LeftoverRoot) -> Orphan? {
        let name = url.lastPathComponent
        guard Self.installerTempPatterns.contains(where: { fnmatch($0, name, 0) == 0 }) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSecurityKey]),
              let modified = values.contentModificationDate, Date().timeIntervalSince(modified) > 3600 else { return nil }
        var owner: uid_t = 0
        if let security = values.fileSecurity { CFFileSecurityGetOwner(security, &owner) }
        return Orphan(url: url, item: nil, ownerKey: "installer-temp", ownerTitle: "Installer temporary files", group: "Temporary Files", tier: .safe,
                      needsRoot: owner != getuid() || !FileRemover.isUserRemovable(url),
                      matchedBy: ["installer temporary folder older than an hour" + (owner == 0 ? ", owned by root" : "")], subtitle: nil, confidence: .medium, familyID: nil)
    }

    // MARK: - Pass 6: crash reports

    private func crashReportLeftovers(installedProcessNames: Set<String>, runningProcessNames: Set<String>) -> [Orphan] {
        var out: [Orphan] = []
        let roots = ["Library/Application Support/CrashReporter", "Library/Logs/DiagnosticReports", "Library/Logs/DiagnosticReports/Retired"]
        for relative in roots {
            let dir = URL(filePath: home).appending(path: relative)
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                guard var process = NameMatcher.reduce(file.lastPathComponent, style: .crashReport).first, !process.isEmpty else { continue }
                for prefix in ["excuserfault_", "excresource_", "jetsamevent", "sfa-", "shutdown_stall", "wakeups_", "cpu_resource", "powerlog", "diskwrites_"] where process.hasPrefix(prefix) {
                    process = String(process.dropFirst(prefix.count))
                }
                if process.isEmpty || Self.isAppleCrashReport(file) { continue }
                let normalized = NameMatcher.normalize(process)
                guard normalized.count >= 4, !installedProcessNames.contains(normalized), !runningProcessNames.contains(normalized) else { continue }
                if installedProcessNames.contains(where: { $0.count >= 5 && (normalized.hasPrefix($0) || $0.hasPrefix(normalized)) }) { continue }
                if Self.isSystemExecutable(process) { continue }
                out.append(Orphan(url: file, item: nil, ownerKey: "process:\(normalized)", ownerTitle: process, group: "Crash Reports", tier: .safe,
                                  needsRoot: false, matchedBy: ["crash report of a process that is not installed or running"], subtitle: nil, confidence: .low, familyID: nil))
            }
        }
        return out
    }

    /// True when a folder holds an app bundle within two levels (software that is still installed outside the scan locations).
    static func containsAppBundle(_ path: String) -> Bool {
        if path.hasSuffix(".app") { return FileManager.default.fileExists(atPath: path + "/Contents/Info.plist") }
        guard let enumerator = FileManager.default.enumerator(at: URL(filePath: path), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { return false }
        for case let url as URL in enumerator {
            if enumerator.level > 2 { enumerator.skipDescendants(); continue }
            if url.pathExtension == "app" { return true }
        }
        return false
    }

    /// Reads the header of an `.ips`/`.diag` report and reports true for Apple processes (procPath under /System or /usr, com.apple bundle IDs).
    static func isAppleCrashReport(_ file: URL) -> Bool {
        guard ["ips", "diag", "crash", "hang", "spin"].contains(file.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: file), let data = try? handle.read(upToCount: 16_384), let text = String(data: data, encoding: .utf8) else { return false }
        try? handle.close()
        if let range = text.range(of: #""procPath"\s*:\s*"([^"]+)""#, options: .regularExpression) {
            let path = String(text[range]).components(separatedBy: "\"").dropLast().last ?? ""
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/") || path.hasPrefix("/bin/") || path.hasPrefix("/Library/Apple/") { return true }
        }
        if text.contains("\"bundleID\":\"com.apple.") || text.contains("\"CFBundleIdentifier\":\"com.apple.") || text.contains("\"app_name\":\"com.apple.") { return true }
        return text.contains("Path:            /System/") || text.contains("Identifier:      com.apple.")
    }

    static func isSystemExecutable(_ name: String) -> Bool {
        let base = name.split(separator: " ").first.map(String.init) ?? name
        let candidates = ["/usr/libexec/\(base)", "/usr/bin/\(base)", "/usr/sbin/\(base)", "/sbin/\(base)", "/bin/\(base)",
                          "/System/Library/CoreServices/\(base)", "/System/Library/CoreServices/\(base).app", "/System/Applications/\(base).app",
                          "/System/Applications/Utilities/\(base).app", "/System/Library/PrivateFrameworks"]
        if candidates.dropLast().contains(where: { FileManager.default.fileExists(atPath: $0) }) { return true }
        return base.lowercased().hasPrefix("com.apple.") || base.hasSuffix("d") && base.count <= 12 && base.lowercased() == base   // short daemons (cfprefsd, mds…)
    }

    // MARK: - Pass 7: registrations

    private func registrationLeftovers(reader: RegistrationReader, installedIDs: Set<String>, installedPaths: Set<String>, installedProcessNames: Set<String>) -> [Orphan] {
        var out: [Orphan] = []
        func installed(_ bundleID: String) -> Bool {
            let lower = bundleID.lowercased()
            if lower.hasPrefix("com.apple.") || lower.isEmpty || lower == "-" { return true }
            if installedIDs.contains(lower) { return true }
            if installedIDs.contains(where: { lower.hasPrefix($0 + ".") }) { return true }
            // Bundle IDs that Launch Services still resolves are installed somewhere we did not scan.
            return LaunchServicesLookup.applicationExists(bundleID: bundleID)
        }
        func pathExists(_ path: String) -> Bool {
            if FileManager.default.fileExists(atPath: path) { return true }
            if let range = path.range(of: ".app/") { return FileManager.default.fileExists(atPath: String(path[..<range.upperBound].dropLast())) }
            return false
        }
        for (index, handler) in reader.launchServicesHandlers().enumerated() {
            let roles = handler.filter { $0.key.hasPrefix("LSHandlerRole") }.values
            guard let bundleID = roles.first(where: { !installed($0) }) else { continue }
            let subject = handler["LSHandlerURLScheme"].map { "URL scheme \($0)://" } ?? handler["LSHandlerContentType"].map { "file type \($0)" } ?? handler["LSHandlerContentTag"].map { "extension .\($0)" } ?? "handler"
            out.append(Orphan(url: nil, item: ScanItem(id: "registration:ls:\(index):\(subject)", title: "Default handler for \(subject)", subtitle: "Points at missing app \(bundleID)",
                                                      kind: .registration, group: "Launch Services", tier: .safe, matchedBy: ["Launch Services handler for a missing app"],
                                                      payload: ["type": "lsHandler", "index": String(index), "subject": subject, "confidence": "high"]),
                              ownerKey: "id:\(bundleID.lowercased())", ownerTitle: Self.owner(for: bundleID.lowercased(), shape: .bundleID, original: bundleID).1,
                              group: "Launch Services", tier: .safe, needsRoot: false, matchedBy: [], subtitle: nil, confidence: .high, familyID: nil))
        }
        for tile in reader.dockTiles() where !pathExists(tile.path) {
            let name = URL(filePath: tile.path).deletingPathExtension().lastPathComponent
            out.append(Orphan(url: nil, item: ScanItem(id: "registration:dock:\(tile.index)", title: "Dock tile for \(name)", subtitle: "App missing: \(tile.path)", kind: .registration,
                                                      group: "Dock", tier: .safe, matchedBy: ["Dock tile points at a missing app"], payload: ["type": "dockTile", "path": tile.path, "confidence": "high"]),
                              ownerKey: "name:\(NameMatcher.normalize(name))", ownerTitle: name, group: "Dock", tier: .safe, needsRoot: false, matchedBy: [], subtitle: nil, confidence: .high, familyID: nil))
        }
        for bundleID in reader.notificationCenterApps() where !installed(bundleID) {
            out.append(Orphan(url: nil, item: ScanItem(id: "registration:nc:\(bundleID)", title: "Notification settings for \(bundleID)", subtitle: "App not installed", kind: .registration,
                                                      group: "Notifications", tier: .safe, matchedBy: ["Notification Center entry for a missing app"], payload: ["type": "notificationCenter", "bundleID": bundleID, "confidence": "high"]),
                              ownerKey: "id:\(bundleID.lowercased())", ownerTitle: Self.owner(for: bundleID.lowercased(), shape: .bundleID, original: bundleID).1,
                              group: "Notifications", tier: .safe, needsRoot: false, matchedBy: [], subtitle: nil, confidence: .high, familyID: nil))
        }
        for row in reader.tccRows() where !installed(row.client) && row.client.contains(".") {
            out.append(Orphan(url: nil, item: ScanItem(id: "registration:tcc:\(row.service):\(row.client)", title: "\(row.serviceTitle) permission for \(row.client)",
                                                      subtitle: (row.allowed ? "Allowed" : "Denied") + " · app not installed", kind: .registration, group: "Permissions", tier: .normal,
                                                      matchedBy: ["permission granted to a missing app"], needsRoot: row.isSystemDatabase, modificationDate: row.lastModified,
                                                      payload: ["type": "tcc", "service": row.tccutilService, "bundleID": row.client, "confidence": "high"]),
                              ownerKey: "id:\(row.client.lowercased())", ownerTitle: Self.owner(for: row.client.lowercased(), shape: .bundleID, original: row.client).1,
                              group: "Permissions", tier: .normal, needsRoot: row.isSystemDatabase, matchedBy: [], subtitle: nil, confidence: .high, familyID: nil))
        }
        for item in reader.keychainItems() {
            let haystack = [item.service, item.label].compactMap { $0?.lowercased() }
            guard let safeStorage = haystack.first(where: { $0.hasSuffix(" safe storage") }) else { continue }
            let product = NameMatcher.normalize(safeStorage.replacingOccurrences(of: " safe storage", with: ""))
            guard product.count >= 4, !installedProcessNames.contains(where: { $0 == product || $0.hasPrefix(product) || product.hasPrefix($0) }) else { continue }
            var payload = ["type": "keychain", "class": item.itemClass, "confidence": "medium"]
            if let ref = item.persistentRef { payload["ref"] = ref.base64EncodedString() }
            out.append(Orphan(url: nil, item: ScanItem(id: "registration:keychain:\(item.itemClass):\(item.service ?? "")\(item.account ?? "")", title: item.displayName,
                                                      subtitle: "Encryption key of an app that is not installed", kind: .registration, group: "Keychain", tier: .caution,
                                                      matchedBy: ["\"Safe Storage\" keychain item without its app"], payload: payload),
                              ownerKey: "name:\(product)", ownerTitle: safeStorage.replacingOccurrences(of: " safe storage", with: "").capitalized,
                              group: "Keychain", tier: .caution, needsRoot: false, matchedBy: [], subtitle: nil, confidence: .medium, familyID: nil))
        }
        for path in reader.firewallApps() where !pathExists(path) && ["/Applications/", "/Users/", "/Library/Application Support/", "/opt/", "/Library/PrivilegedHelperTools/"].contains(where: { path.hasPrefix($0) }) {
            let name = URL(filePath: path).deletingPathExtension().lastPathComponent
            out.append(Orphan(url: nil, item: ScanItem(id: "registration:firewall:\(path)", title: "Firewall rule for \(name)", subtitle: "Missing: \(path)", kind: .registration,
                                                      group: "Firewall", tier: .safe, matchedBy: ["firewall allow-list entry for a missing app"], needsRoot: true,
                                                      payload: ["type": "firewall", "path": path, "confidence": "high"]),
                              ownerKey: "name:\(NameMatcher.normalize(name))", ownerTitle: name, group: "Firewall", tier: .safe, needsRoot: true, matchedBy: [], subtitle: nil, confidence: .high, familyID: nil))
        }
        let pluginkit = SystemRegistrationReader.run("/usr/bin/pluginkit", ["-m", "-A", "-v"]) ?? ""
        for entry in ExtensionsScanner.parsePluginkit(pluginkit) where !entry.path.isEmpty && !pathExists(entry.path) && !entry.identifier.hasPrefix("com.apple.") {
            out.append(Orphan(url: nil, item: ScanItem(id: "registration:pluginkit:\(entry.identifier)", title: "Extension registration \(entry.identifier)",
                                                      subtitle: "Missing: \(entry.path)", kind: .registration, group: "Extensions", tier: .safe,
                                                      matchedBy: ["pluginkit registration whose bundle is gone"], payload: ["type": "pluginkit", "identifier": entry.identifier, "path": entry.path, "confidence": "high"]),
                              ownerKey: "id:\(entry.identifier.lowercased())", ownerTitle: Self.owner(for: entry.identifier.lowercased(), shape: .bundleID, original: entry.identifier).1,
                              group: "Extensions", tier: .safe, needsRoot: false, matchedBy: [], subtitle: nil, confidence: .high, familyID: nil))
        }
        return out
    }

    // MARK: - Shapes and ownership

    enum Shape { case bundleID, teamPrefixed, groupID }

    static func identifierShape(_ candidate: String, original: String) -> Shape? {
        if candidate.hasPrefix("group.") { return .groupID }
        if teamPrefixPattern.firstMatch(in: original, range: NSRange(location: 0, length: original.utf16.count)) != nil { return .teamPrefixed }
        let segments = candidate.split(separator: ".")
        let fileSuffixes = ["txt", "log", "json", "lock", "db", "sqlite", "tmp", "dat", "xml", "pid", "sock", "plist", "csv", "html"]
        if bundleIDPattern.firstMatch(in: candidate, range: NSRange(location: 0, length: candidate.utf16.count)) != nil,
           segments.allSatisfy({ !$0.isEmpty }), let first = segments.first, first.count <= 6,
           !fileSuffixes.contains(String(segments.last ?? "")) { return .bundleID }
        return nil
    }

    static func vendorPrefix(of id: String) -> String? {
        let parts = id.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts.prefix(2).joined(separator: ".").lowercased()
    }

    static func isOwned(_ candidate: String, shape: Shape, installedIDs: Set<String>, installedTeams: Set<String>, installedGroups: Set<String>, running: Set<String>) -> Bool {
        let lower = candidate.lowercased()
        for id in installedIDs where lower == id || lower.hasPrefix(id + ".") || lower.hasPrefix(id + "-") || lower.hasPrefix(id + "_") { return true }
        for id in running where lower == id || lower.hasPrefix(id + ".") { return true }
        switch shape {
        case .teamPrefixed:
            let team = lower.split(separator: ".").first.map(String.init) ?? ""
            return installedTeams.contains(team)
        case .groupID:
            if installedGroups.contains(lower) || installedGroups.contains(where: { $0.hasSuffix("." + lower) }) { return true }
            let stripped = String(lower.dropFirst("group.".count))
            return installedIDs.contains { stripped == $0 || stripped.hasPrefix($0 + ".") }
        case .bundleID:
            return installedGroups.contains { $0.hasSuffix("." + lower) }
        }
    }

    /// Groups orphans by their first three identifier components; `com.microsoft.teams2.agent` → `microsoft.teams2.agent`.
    static func owner(for candidate: String, shape: Shape, original: String) -> (String, String) {
        switch shape {
        case .teamPrefixed:
            let rest = original.split(separator: ".").dropFirst().joined(separator: ".")
            if bundleIDPattern.firstMatch(in: rest, range: NSRange(location: 0, length: rest.utf16.count)) != nil {
                return owner(for: rest.lowercased(), shape: .bundleID, original: rest)
            }
            return ("team:\(original.split(separator: ".").first ?? "")", rest.isEmpty ? original : rest)
        case .groupID:
            let parts = candidate.split(separator: ".").dropFirst()
            return ("group:\(parts.prefix(3).joined(separator: "."))", parts.dropFirst().prefix(2).joined(separator: "."))
        case .bundleID:
            let parts = candidate.split(separator: ".")
            let key = parts.prefix(3).joined(separator: ".")
            let title = parts.dropFirst().prefix(2).joined(separator: ".")
            return ("id:\(key)", title.isEmpty ? candidate : title)
        }
    }

    static func launchdProgramExists(_ plistURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        let programs = [plist["Program"] as? String, (plist["ProgramArguments"] as? [String])?.first, plist["BundleProgram"] as? String].compactMap { $0 }
        return programs.contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Broken pointers

    private func brokenPointers() -> [Orphan] {
        var out: [Orphan] = []
        let fm = FileManager.default
        for dir in ["Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            let url = dir.hasPrefix("/") ? URL(filePath: dir) : URL(filePath: home).appending(path: dir)
            guard let plists = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { continue }
            for plist in plists where plist.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: plist),
                      let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                let programs = [dict["Program"] as? String, (dict["ProgramArguments"] as? [String])?.first].compactMap { $0 }
                guard let program = programs.first, program.hasPrefix("/"), !fm.fileExists(atPath: program) else { continue }
                let label = dict["Label"] as? String ?? plist.deletingPathExtension().lastPathComponent
                out.append(Orphan(url: plist, item: nil, ownerKey: "id:\(label.lowercased().split(separator: ".").prefix(3).joined(separator: "."))", ownerTitle: Self.owner(for: label.lowercased(), shape: .bundleID, original: label).1,
                                  group: "Login Items", tier: .normal, needsRoot: dir.hasPrefix("/"), matchedBy: ["launchd program missing: \(program)"],
                                  subtitle: "Program no longer exists: \(program)", confidence: .high, familyID: nil))
            }
        }
        for dir in ["/usr/local/bin", "/usr/local/sbin", "/opt/homebrew/bin"] {
            guard let entries = try? fm.contentsOfDirectory(at: URL(filePath: dir), includingPropertiesForKeys: [.isSymbolicLinkKey]) else { continue }
            for entry in entries {
                guard (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                      let destination = try? fm.destinationOfSymbolicLink(atPath: entry.path) else { continue }
                let resolved = destination.hasPrefix("/") ? destination : entry.deletingLastPathComponent().appending(path: destination).standardizedFileURL.path
                guard !fm.fileExists(atPath: resolved) else { continue }
                out.append(Orphan(url: entry, item: nil, ownerKey: "broken:symlink:\(entry.lastPathComponent)", ownerTitle: entry.lastPathComponent, group: "CLI Tools",
                                  tier: .safe, needsRoot: !FileRemover.isUserRemovable(entry), matchedBy: ["dangling symlink → \(resolved)"], subtitle: "Points to a missing \(resolved)",
                                  confidence: .high, familyID: nil))
            }
        }
        for rule in rules.catalogue.roots where rule.id == "native-messaging-hosts" {
            for rootPath in rule.allRoots {
                let dir = URL(filePath: PathExpander.expand(rootPath, home: home))
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                for file in files where file.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let path = json["path"] as? String, !fm.fileExists(atPath: path) else { continue }
                    let name = file.deletingPathExtension().lastPathComponent
                    out.append(Orphan(url: file, item: nil, ownerKey: "id:\(name.lowercased().split(separator: ".").prefix(3).joined(separator: "."))", ownerTitle: Self.owner(for: name.lowercased(), shape: .bundleID, original: name).1,
                                      group: "Browser Integration", tier: .safe, needsRoot: rule.requiresRoot, matchedBy: ["native messaging host target missing"],
                                      subtitle: "Host binary missing: \(path)", confidence: .high, familyID: nil))
                }
            }
        }
        return out
    }

    /// `.app` folders that are not valid bundles any more: no Info.plist, or an executable that is gone.
    private func brokenBundles(locations: [URL], installedPaths: Set<String>) -> [Orphan] {
        var out: [Orphan] = []
        let fm = FileManager.default
        for location in locations {
            guard let enumerator = fm.enumerator(at: location, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                if enumerator.level > 3 { enumerator.skipDescendants(); continue }
                guard url.pathExtension == "app" else { continue }
                enumerator.skipDescendants()
                let path = url.standardizedFileURL.path
                if installedPaths.contains(path) { continue }
                let info = AppInspector.infoPlist(at: url)
                var problem: String?
                if info == nil {
                    problem = "no Info.plist; the bundle is incomplete"
                } else if let executable = info?["CFBundleExecutable"] as? String,
                          !fm.fileExists(atPath: url.appending(path: "Contents/MacOS/\(executable)").path) {
                    problem = "executable \(executable) is missing"
                }
                guard let problem else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                out.append(Orphan(url: url, item: nil, ownerKey: "broken-app:\(NameMatcher.normalize(name))", ownerTitle: name, group: "Executables", tier: .normal,
                                  needsRoot: !FileRemover.isUserRemovable(url), matchedBy: ["broken application bundle: \(problem)"],
                                  subtitle: "Broken app: \(problem)", confidence: .high, familyID: nil))
            }
        }
        return out
    }

    private func displayPath(_ url: URL) -> String {
        let path = url.deletingLastPathComponent().path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Asks Launch Services whether any app with the bundle ID is registered (apps outside the scanned folders).
enum LaunchServicesLookup {
    static func applicationExists(bundleID: String) -> Bool {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] else { return false }
        return urls.contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}
