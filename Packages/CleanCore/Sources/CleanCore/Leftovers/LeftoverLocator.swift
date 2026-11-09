import Foundation

/// Result of a deep dive on one app.
public struct LeftoverScanResult: Sendable {
    public let app: InstalledApp
    /// Group nodes (Executables, Application Support, …) with the matched items as children.
    public let groups: [ScanItem]
    public let totalSize: Int64
    public let itemCount: Int
    public let duration: TimeInterval
    /// True when the search was cancelled before every location was checked.
    public var isPartial: Bool = false

    public var allItems: [ScanItem] { groups.flatMap(\.children) }
    public var selectableItems: [ScanItem] { allItems.filter { $0.tier.isSelectable } }
    public var defaultSelection: [ScanItem] { allItems.filter { $0.tier.isSelectableByDefault } }
}

/// Order in which Expert Mode shows the groups.
public enum LeftoverGroups {
    public static let order = [
        "Executables", "Application Support", "Containers", "Group Containers", "Preferences", "Caches", "Logs", "Crash Reports",
        "Saved State", "Web Storage", "Login Items", "Extensions", "Kernel & System Extensions", "Drivers", "Runtime", "CLI Tools",
        "Dotfiles", "Shell Integration", "Browser Integration", "Cloud", "Traces", "Indexes", "Temporary Files", "Receipts", "Shared", "User Data",
        "Permissions", "Keychain", "Launch Services", "Dock", "Notifications", "Running Jobs", "Firewall",
    ]
    public static func rank(_ group: String) -> Int { order.firstIndex(of: group) ?? order.count }
}

/// Runs the catalogue, the content/pointer scans and the vendor overrides for one app.
public actor LeftoverLocator {
    public let rules: Rules
    private let home: String
    private let registrations: RegistrationScanner?

    /// - Parameter registrations: scanner for non-file traces; nil skips them (tests, Trash watcher).
    public init(rules: Rules = .bundled, home: String = NSHomeDirectory(), registrations: RegistrationScanner? = nil) {
        self.rules = rules
        self.home = home
        self.registrations = registrations
    }

    struct Candidate {
        var url: URL
        var group: String
        var tier: RiskTier
        var needsRoot: Bool
        var matchedBy: [String]
        var subtitle: String?
        var kind: ItemKind = .directory
    }

    /// What one deep dive knows about the app, computed once and shared by every root.
    struct ScanContext {
        var identity: AppIdentity
        var normalizedNames: Set<String>
        var appPath: String
        /// Matching package receipts, lowercased identifier → identifier as stored.
        var receiptIDs: [String: String]
        /// Payload paths that belong to those packages alone (see `PackageReceipts.ownedPayloadPaths`).
        var packagePaths: Set<String>
        /// Another installed app signed by the same Team ID, if any.
        var teamSibling: String?
        /// Bundle IDs of installed apps that extend this app's ID (`com.google.Chrome.canary` for `com.google.Chrome`).
        var moreSpecificIDs: [String]

        /// True when a child's identifier names a more specific installed app, which owns it (Chrome Canary's preferences
        /// are not Chrome's, nor are the caches of an installed Chrome web-app shim).
        func belongsToMoreSpecificApp(_ reduced: [String]) -> Bool {
            guard !moreSpecificIDs.isEmpty else { return false }
            return reduced.contains { name in
                let c = name.lowercased()
                return moreSpecificIDs.contains { NameMatcher.idMatches(c, $0) }
            }
        }
    }

    /// Suffix of the plug-in reason when the plug-in's signer could not be compared with the app's.
    static let unverifiedPluginSuffix = "signer not verified"

    /// Finds everything that belongs to `app`. `otherApps` are the remaining installed apps, used to flag shared items.
    public func locate(app: InstalledApp, otherApps: [InstalledApp], includeExecutable: Bool = true,
                       skipList: [String] = []) async -> LeftoverScanResult {
        let start = Date()
        var identity = app.identity
        // The same bundle reached through a symlink, or listed twice, is not another app.
        let appResolved = Self.resolvedPath(app.url)
        let others = otherApps.filter { Self.resolvedPath($0.url) != appResolved }
        let otherIdentities = others.map(\.identity)
        let overrides = rules.overrides.matching(bundleID: identity.bundleID)
        // A rule that another installed app also matches (a second copy, a sibling channel, a vendor-wide rule)
        // describes paths that are still in use: its paths, labels and receipts are left alone.
        let ownOverrides = overrides.filter { override in !others.contains { override.matches(bundleID: $0.bundleID) } }
        for override in ownOverrides {
            identity.launchdLabels.formUnion(override.launchdLabels ?? [])
        }
        let appPath = app.url.standardizedFileURL.path
        var candidates: [Candidate] = []
        var excludedPrefixes: [String] = overrides.flatMap { $0.exclude ?? [] }.map { PathExpander.expand($0, home: home) }

        if includeExecutable {
            candidates.append(Candidate(url: app.url, group: "Executables", tier: .normal, needsRoot: !FileRemover.isUserRemovable(app.url),
                                        matchedBy: ["application bundle"], kind: .bundle))
        }

        // Receipts first so manifest paths can confirm items elsewhere.
        let receiptIDs = matchingReceipts(identity: identity, overrides: ownOverrides)
        let ownID = identity.bundleID.lowercased()
        let teamSibling: String? = {
            guard let team = identity.teamID, !team.isEmpty else { return nil }
            return otherIdentities.first { $0.teamID?.caseInsensitiveCompare(team) == .orderedSame }?.name
        }()
        let context = ScanContext(
            identity: identity, normalizedNames: identity.normalizedNames, appPath: appPath, receiptIDs: receiptIDs,
            packagePaths: receiptPayloadPaths(for: receiptIDs), teamSibling: teamSibling,
            moreSpecificIDs: otherIdentities.map { $0.bundleID.lowercased() }.filter { $0 != ownID && NameMatcher.idMatches($0, ownID) })

        var cancelled = false
        for root in rules.catalogue.roots {
            if Task.isCancelled { cancelled = true; break }
            for rootPath in root.allRoots {
                let expanded = PathExpander.expand(rootPath, home: home)
                guard !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded) else { continue }
                candidates.append(contentsOf: scanRoot(URL(filePath: expanded), rule: root, context: context))
            }
        }

        if !cancelled {
            candidates.append(contentsOf: overrideCandidates(ownOverrides, others: others))
            candidates.append(contentsOf: manifestCandidates(context.packagePaths, candidates: candidates, others: others))
            candidates.append(contentsOf: shellRCCandidates(identity: identity, overrides: ownOverrides, appPath: appPath, candidates: candidates))
        }
        cancelled = cancelled || Task.isCancelled

        // Dedupe, drop children of included parents, apply protection and skip list.
        var byPath: [String: Candidate] = [:]
        for candidate in candidates {
            let path = candidate.url.standardizedFileURL.path
            if excludedPrefixes.contains(where: { path.hasPrefix($0) }) { continue }
            if var existing = byPath[path] {
                existing.matchedBy = Array(NSOrderedSet(array: existing.matchedBy + candidate.matchedBy)) as? [String] ?? existing.matchedBy
                // Keep the more cautious tier when two rules disagree (a vendor rule may know a folder is shared).
                if candidate.tier > existing.tier { existing.tier = candidate.tier; existing.subtitle = candidate.subtitle ?? existing.subtitle }
                if existing.subtitle == nil { existing.subtitle = candidate.subtitle }
                existing.needsRoot = existing.needsRoot || candidate.needsRoot
                byPath[path] = existing
            } else {
                byPath[path] = candidate
            }
        }
        excludedPrefixes.removeAll()
        let includedPaths = Set(byPath.keys)
        var deduped = byPath.values.filter { candidate in
            let path = candidate.url.standardizedFileURL.path
            var parent = URL(filePath: path).deletingLastPathComponent().path
            while parent.count > 1 {
                if includedPaths.contains(parent) { return false }
                parent = URL(filePath: parent).deletingLastPathComponent().path
            }
            return true
        }

        for index in deduped.indices {
            let path = deduped[index].url.standardizedFileURL.path
            if rules.protectedRules.isProtected(path, home: home) {
                deduped[index].tier = .protected
                deduped[index].subtitle = "Protected location"
                continue
            }
            if deduped[index].kind != .registration, let explanation = FileProtection.classify(deduped[index].url).explanation {
                deduped[index].tier = .protected
                deduped[index].subtitle = explanation
                continue
            }
            if skipList.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                deduped[index].tier = .protected
                deduped[index].subtitle = "In Skip List"
                continue
            }
            // A folder holding something on the Skip List cannot be removed without it.
            if deduped[index].kind != .registration, skipList.contains(where: { $0.hasPrefix(path + "/") }) {
                deduped[index].tier = .protected
                deduped[index].subtitle = "Contains an item in Skip List"
                continue
            }
            if deduped[index].kind != .registration, deduped[index].group != "Executables",
               let sharer = sharedWith(deduped[index], identities: otherIdentities) {
                if deduped[index].tier < .caution { deduped[index].tier = .caution }
                deduped[index].subtitle = "Shared with \(sharer)"
            }
        }
        if !cancelled {
            deduped = applyEmptiedFolders(ownOverrides, to: deduped, skipList: skipList)
        }

        // Sizes (skipped after a cancellation so the result comes back at once; the app bundle itself is still measured).
        let fileURLs = deduped.filter { $0.kind != .registration }.map(\.url)
        let sizes: [URL: SizeResult]
        if cancelled {
            sizes = await Task.detached(priority: .userInitiated) { [app] in [app.url: DirectorySizer.size(of: app.url)] }.value
        } else {
            sizes = await DirectorySizer.sizes(of: fileURLs, maxConcurrency: 6)
        }
        var items: [ScanItem] = []
        for candidate in deduped {
            let size = sizes[candidate.url]
            var item = ScanItem(url: candidate.url, title: candidate.url.lastPathComponent, subtitle: candidate.subtitle ?? displayPath(candidate.url),
                                kind: candidate.kind, group: candidate.group, size: size?.bytes ?? 0, tier: candidate.tier,
                                matchedBy: candidate.matchedBy, needsRoot: candidate.needsRoot,
                                modificationDate: try? candidate.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            if candidate.kind == .registration { item.id = "registration:\(candidate.group):\(candidate.url.path):\(candidate.subtitle ?? "")" }
            if let size, candidate.kind != .registration, candidate.kind != .bundle {
                item.kind = size.directoryCount > 0 || candidate.kind == .directory ? candidate.kind : .file
            }
            items.append(item)
        }

        if let registrations, !cancelled {
            let traces = registrations.scan(identity: identity, appPath: appPath, shared: rules.shared)
            items.append(contentsOf: traces.filter { trace in !skipList.contains(where: { trace.subtitle?.contains($0) == true }) })
        }

        let grouped = Dictionary(grouping: items, by: \.group)
        let groups = grouped.keys.sorted { (LeftoverGroups.rank($0), $0) < (LeftoverGroups.rank($1), $1) }.map { name -> ScanItem in
            let children = grouped[name]!.sorted { $0.size > $1.size }
            return ScanItem(id: "group:\(name)", title: name, kind: .group, group: name, children: children).rollingUpSizes()
        }
        let total = groups.reduce(0) { $0 + $1.size }
        var result = LeftoverScanResult(app: app, groups: groups, totalSize: total, itemCount: items.count,
                                        duration: Date().timeIntervalSince(start))
        result.isPartial = cancelled
        return result
    }

    /// The bundle path with symlinks resolved, so one app reached two ways compares equal.
    static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Root is needed only when the rule's location is a system one *and* this item cannot be removed by the user
    /// (a user-owned folder in `/usr/local/bin` or `/Library/Application Support` is not).
    static func needsRoot(_ rule: LeftoverRoot, _ url: URL) -> Bool {
        rule.requiresRoot && !FileRemover.isUserRemovable(url)
    }

    // MARK: - Catalogue roots

    private func scanRoot(_ root: URL, rule: LeftoverRoot, context: ScanContext) -> [Candidate] {
        let identity = context.identity
        let allowed = Set(rule.match)
        let skip = Set((rule.skipChildren ?? []).map { $0.lowercased() })
        let standard = Set(rules.catalogue.standardLibrarySubdirectories.map { $0.lowercased() })
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey]
        guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys),
                                                                          options: []) else { return [] }
        var out: [Candidate] = []
        for child in children {
            let name = child.lastPathComponent
            if name == ".DS_Store" || name == ".localized" { continue }
            if skip.contains(name.lowercased()) { continue }
            if rule.onlyNonStandard == true, standard.contains(name.lowercased()) { continue }
            let values = try? child.resourceValues(forKeys: keys)
            let isDirectory = values?.isDirectory ?? false
            let reduced = reducedNames(for: child, style: rule.nameStyle)
            if context.belongsToMoreSpecificApp(reduced) { continue }
            var reasons = NameMatcher.match(reduced: reduced, identity: identity, allowed: allowed, shared: rules.shared,
                                            normalizedNames: context.normalizedNames)
            reasons.append(contentsOf: contentSignals(child, values: values, rule: rule, allowed: allowed, context: context))
            reasons = Array(NSOrderedSet(array: reasons)) as? [String] ?? reasons

            let vendorOnly = reasons == ["vendor folder"]
            if vendorOnly, rule.depth >= 2, isDirectory {
                out.append(contentsOf: scanVendorFolder(child, rule: rule, context: context))
                continue
            }
            if vendorOnly {
                // Vendor-named item at depth 1 (e.g. ~/Library/Dropbox, /Library/Google): keep but mark cautious.
                out.append(Candidate(url: child, group: rule.group, tier: max(rule.tier, .caution), needsRoot: Self.needsRoot(rule, child),
                                     matchedBy: reasons, subtitle: "Vendor folder, may be shared by other apps from \(identity.developerName ?? identity.vendor ?? "this developer")",
                                     kind: isDirectory ? .directory : .file))
                continue
            }
            guard !reasons.isEmpty else { continue }
            var tier = rule.tier
            var subtitle: String?
            if let note = weakEvidenceNote(reasons, context: context) {
                tier = max(tier, .caution)
                subtitle = note
            }
            out.append(Candidate(url: child, group: rule.group, tier: tier, needsRoot: Self.needsRoot(rule, child), matchedBy: reasons,
                                 subtitle: subtitle, kind: isDirectory ? .directory : .file))
        }
        return out
    }

    /// Evidence that alone does not prove ownership, so the item must not be pre-selected: a container that only carries the
    /// developer's Team ID while another app of that team is installed, or a plug-in whose signer could not be compared.
    private func weakEvidenceNote(_ reasons: [String], context: ScanContext) -> String? {
        let isTeam: (String) -> Bool = { $0.hasPrefix(NameMatcher.teamReasonPrefix) }
        let isUnverifiedPlugin: (String) -> Bool = { $0.hasSuffix(Self.unverifiedPluginSuffix) }
        guard !reasons.isEmpty else { return nil }
        if let sibling = context.teamSibling, reasons.allSatisfy({ isTeam($0) || isUnverifiedPlugin($0) }), reasons.contains(where: isTeam) {
            return "Same developer team as \(sibling); may belong to it"
        }
        if reasons.allSatisfy(isUnverifiedPlugin) {
            return "Same bundle ID prefix as the app, but the developer could not be confirmed from the signature"
        }
        return nil
    }

    /// Looks inside a vendor folder (`~/Library/Application Support/Google/`) for the app's product folder.
    private func scanVendorFolder(_ folder: URL, rule: LeftoverRoot, context: ScanContext) -> [Candidate] {
        let allowed: Set<String> = ["bundleID", "subBundleID", "extensionID", "name", "executable"]
        guard let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var matched: [Candidate] = []
        var claimedByOthers = false
        for child in children where child.lastPathComponent != ".DS_Store" {
            let reduced = reducedNames(for: child, style: .folder)
            if context.belongsToMoreSpecificApp(reduced) { claimedByOthers = true; continue }
            let reasons = NameMatcher.match(reduced: reduced, identity: context.identity, allowed: allowed, shared: rules.shared,
                                            normalizedNames: context.normalizedNames)
            guard !reasons.isEmpty else { continue }
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            matched.append(Candidate(url: child, group: rule.group, tier: rule.tier, needsRoot: Self.needsRoot(rule, child),
                                     matchedBy: ["vendor folder"] + reasons, kind: isDirectory ? .directory : .file))
        }
        let realChildren = children.filter { $0.lastPathComponent != ".DS_Store" }
        if !matched.isEmpty, !claimedByOthers, matched.count == realChildren.count {
            return [Candidate(url: folder, group: rule.group, tier: rule.tier, needsRoot: Self.needsRoot(rule, folder),
                              matchedBy: ["vendor folder (all contents belong to this app)"], kind: .directory)]
        }
        if matched.isEmpty, realChildren.isEmpty {
            return [Candidate(url: folder, group: rule.group, tier: .safe, needsRoot: Self.needsRoot(rule, folder),
                              matchedBy: ["empty vendor folder"], kind: .directory)]
        }
        return matched
    }

    private func reducedNames(for url: URL, style: NameStyle) -> [String] {
        var reduced = NameMatcher.reduce(url.lastPathComponent, style: style)
        if style == .container, NameMatcher.hex32.firstMatch(in: url.lastPathComponent, range: NSRange(location: 0, length: url.lastPathComponent.utf16.count)) != nil
            || url.lastPathComponent.contains("-") && url.lastPathComponent.count == 36 {
            let metadata = url.appending(path: ".com.apple.containermanagerd.metadata.plist")
            if let data = try? Data(contentsOf: metadata),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let id = plist["MCMMetadataIdentifier"] as? String {
                reduced = [id.lowercased()]
            }
        }
        return reduced
    }

    // MARK: - Content and pointer signals

    private func contentSignals(_ url: URL, values: URLResourceValues?, rule: LeftoverRoot, allowed: Set<String>, context: ScanContext) -> [String] {
        let identity = context.identity
        let appPath = context.appPath
        var reasons: [String] = []
        let fm = FileManager.default
        if allowed.contains("launchdProgram"), url.pathExtension == "plist",
           let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            if let label = plist["Label"] as? String {
                if identity.launchdLabels.contains(label) { reasons.append("launchd label") }
                else if NameMatcher.idMatches(label.lowercased(), identity.bundleID.lowercased()) { reasons.append("launchd label matches bundle ID") }
            }
            let programs = [plist["Program"] as? String, (plist["ProgramArguments"] as? [String])?.first, plist["BundleProgram"] as? String].compactMap { $0 }
            if programs.contains(where: { $0.hasPrefix(appPath + "/") || $0 == appPath }) { reasons.append("launchd program inside the app") }
        }
        if allowed.contains("symlinkIntoApp"), values?.isSymbolicLink == true,
           let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            let resolved = destination.hasPrefix("/") ? destination : url.deletingLastPathComponent().appending(path: destination).standardizedFileURL.path
            if resolved.hasPrefix(appPath + "/") || resolved == appPath { reasons.append("symlink into the app") }
        }
        if allowed.contains("aliasIntoApp") {
            if values?.isAliasFile == true, let target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]),
               target.standardizedFileURL.path == appPath { reasons.append("alias to the app") }
            if values?.isSymbolicLink == true, let destination = try? fm.destinationOfSymbolicLink(atPath: url.path),
               URL(filePath: destination).standardizedFileURL.path == appPath { reasons.append("symlink to the app") }
        }
        if allowed.contains("jsonPathIntoApp"), url.pathExtension == "json", let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let path = json["path"] as? String,
           path.hasPrefix(appPath + "/") || path == appPath {
            reasons.append("native messaging host points into the app")
        }
        if allowed.contains("fileContentIntoApp"), values?.isDirectory != true,
           let attributes = try? fm.attributesOfItem(atPath: url.path), (attributes[.size] as? Int ?? 0) < 65_536,
           let text = try? String(contentsOf: url, encoding: .utf8), text.contains(appPath) {
            reasons.append("file content references the app")
        }
        if allowed.contains("pluginBundleID"), values?.isDirectory == true, let info = AppInspector.infoPlist(at: url),
           let id = (info["CFBundleIdentifier"] as? String)?.lowercased() {
            if NameMatcher.idMatches(id, identity.bundleID.lowercased()) { reasons.append("plug-in bundle ID") }
            else if identity.subBundleIDs.contains(where: { NameMatcher.idMatches(id, $0.lowercased()) }) { reasons.append("plug-in bundle ID") }
            else if let prefix = identity.vendorPrefix, id.hasPrefix(prefix + "."), !rules.shared.isShared(bundleID: id),
                    !rules.protectedRules.isProtected(bundleID: id) {
                // The bundle-ID prefix only suggests the developer; the signature decides.
                if let appTeam = identity.teamID, !appTeam.isEmpty, let pluginTeam = AppInspector.signingTeamID(at: url) {
                    if pluginTeam.caseInsensitiveCompare(appTeam) == .orderedSame {
                        reasons.append("plug-in from the same developer (\(id), team \(appTeam))")
                    }
                } else {
                    reasons.append("plug-in with the developer's bundle ID prefix (\(id)), \(Self.unverifiedPluginSuffix)")
                }
            }
        }
        if allowed.contains("pkgReceipt") {
            if rule.nameStyle == .receipt {
                let id = NameMatcher.reduce(url.lastPathComponent, style: .receipt).first ?? ""
                if context.receiptIDs[id] != nil { reasons.append("package receipt") }
            } else if context.packagePaths.contains(url.standardizedFileURL.path) {
                reasons.append("installed by the app's package")
            }
        }
        return reasons
    }

    // MARK: - Receipts

    /// Package receipts that belong to the app: listed by a vendor override, or sharing the vendor prefix and the product name.
    /// Returns lowercased identifier → identifier as stored (pkgutil wants the original spelling).
    private func matchingReceipts(identity: AppIdentity, overrides: [VendorOverride]) -> [String: String] {
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: "/private/var/db/receipts") else { return [:] }
        var ids: [String: String] = [:]
        for file in all where file.hasSuffix(".plist") {
            let original = String(file.dropLast(6))
            ids[original.lowercased()] = original
        }
        var matched: [String: String] = [:]
        let patterns = overrides.flatMap { $0.pkgReceipts ?? [] }.map { $0.lowercased() }
        let names = identity.normalizedNames.filter { $0.count >= 4 }
        let lastComponent = identity.bundleID.split(separator: ".").last.map { NameMatcher.normalize(String($0)) } ?? ""
        let prefix = identity.vendorPrefix
        for (id, original) in ids {
            if rules.protectedRules.isProtected(bundleID: id) { continue }
            if patterns.contains(where: { fnmatch($0, id, 0) == 0 }) { matched[id] = original; continue }
            guard let prefix, id.hasPrefix(prefix + ".") else { continue }
            let normalizedID = NameMatcher.normalize(id.replacingOccurrences(of: ".", with: " "))
            if names.contains(where: { normalizedID.contains($0) }) || (lastComponent.count >= 4 && normalizedID.contains(lastComponent)) {
                matched[id] = original
            }
        }
        return matched
    }

    /// Payload paths that belong to the matching packages alone: never a shared parent such as `/usr/local/bin`, and never a
    /// folder that also holds files the package did not install.
    private func receiptPayloadPaths(for receipts: [String: String]) -> Set<String> {
        var paths: Set<String> = []
        for identifier in receipts.values {
            guard let info = PackageReceipts.info(identifier) else { continue }
            paths.formUnion(PackageReceipts.ownedPayloadPaths(manifest: PackageReceipts.manifest(identifier), base: info.base))
        }
        return paths
    }

    /// Package payload that is not already a candidate (e.g. `/Library/Frameworks/R.framework`, `/usr/local/bin/tool`).
    private func manifestCandidates(_ packagePaths: Set<String>, candidates: [Candidate], others: [InstalledApp]) -> [Candidate] {
        let existing = Set(candidates.map { $0.url.standardizedFileURL.path })
        let otherAppPaths = others.map { $0.url.standardizedFileURL.path }
        var out: [Candidate] = []
        for path in packagePaths.sorted() where !existing.contains(path) {
            if PackageReceipts.sharedParents.contains(path) || rules.protectedRules.isProtected(path, home: home) { continue }
            // Another installed app inside the payload (one package installing several apps) stays.
            if otherAppPaths.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) { continue }
            let url = URL(filePath: path)
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let group: String
            if path.hasPrefix("/usr/local/") || path.hasPrefix("/opt/") { group = "CLI Tools" }
            else if path.hasPrefix("/Library/Frameworks/") { group = "Runtime" }
            else if path.hasPrefix("/Applications/") { group = "Executables" }
            else if ["/Library/LaunchAgents/", "/Library/LaunchDaemons/", "/Library/PrivilegedHelperTools/"].contains(where: { path.hasPrefix($0) }) { group = "Login Items" }
            else { group = "Application Support" }
            out.append(Candidate(url: url, group: group, tier: group == "Runtime" ? .caution : .normal,
                                 needsRoot: !FileRemover.isUserRemovable(url), matchedBy: ["installed by the app's package"],
                                 kind: isDirectory ? .directory : .file))
        }
        return out
    }

    // MARK: - Vendor overrides

    private func overrideCandidates(_ overrides: [VendorOverride], others: [InstalledApp]) -> [Candidate] {
        var out: [Candidate] = []
        for override in overrides {
            for include in override.include ?? [] where include.onlyIfEmptyAfter != true {
                let sharer = include.sharedWith.flatMap { patterns in others.first { BundleIDPattern.matchesAny(patterns, $0.bundleID) } }
                for path in PathExpander.glob(PathExpander.expand(include.path, home: home)) {
                    let url = URL(filePath: path)
                    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    var tier = include.tier
                    var subtitle = include.sharedNote
                    if let sharer {
                        tier = max(tier, .caution)
                        subtitle = "Also used by \(sharer.name)"
                    }
                    out.append(Candidate(url: url, group: include.group, tier: tier,
                                         needsRoot: (include.needsRoot ?? true) && !FileRemover.isUserRemovable(url),
                                         matchedBy: ["vendor rule"], subtitle: subtitle, kind: isDirectory ? .directory : .file))
                }
            }
        }
        return out
    }

    /// `onlyIfEmptyAfter` folders (`~/Library/Caches/BraveSoftware`): listed in place of their contents only when every item inside
    /// is already part of this removal (after protection and shared checks), so removing the folder takes nothing else with it.
    /// The folder is never less cautious than its contents.
    private func applyEmptiedFolders(_ overrides: [VendorOverride], to items: [Candidate], skipList: [String]) -> [Candidate] {
        var items = items
        for override in overrides {
            for include in override.include ?? [] where include.onlyIfEmptyAfter == true {
                for path in PathExpander.glob(PathExpander.expand(include.path, home: home)) {
                    let url = URL(filePath: path)
                    let folder = url.standardizedFileURL.path
                    guard !items.contains(where: { $0.url.standardizedFileURL.path == folder }),
                          (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          !rules.protectedRules.isProtected(folder, home: home), FileProtection.classify(url) == .none,
                          !skipList.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") || $0.hasPrefix(folder + "/") }),
                          let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
                    var tier = include.tier
                    var subtitle = include.sharedNote
                    var childIndices: [Int] = []
                    var complete = true
                    for child in children where child != ".DS_Store" && child != ".localized" {
                        let childPath = url.appending(path: child).standardizedFileURL.path
                        guard let index = items.firstIndex(where: { $0.kind != .registration && $0.url.standardizedFileURL.path == childPath }),
                              items[index].tier != .protected else { complete = false; break }
                        if items[index].tier > tier { tier = items[index].tier; subtitle = items[index].subtitle ?? subtitle }
                        childIndices.append(index)
                    }
                    guard complete else { continue }
                    let reasons = ["vendor rule", "folder emptied by this removal"] + childIndices.flatMap { items[$0].matchedBy }
                    let folderCandidate = Candidate(url: url, group: include.group, tier: tier,
                                                    needsRoot: (include.needsRoot ?? true) && !FileRemover.isUserRemovable(url),
                                                    matchedBy: Array(NSOrderedSet(array: reasons)) as? [String] ?? reasons,
                                                    subtitle: subtitle, kind: .directory)
                    for index in childIndices.sorted(by: >) { items.remove(at: index) }
                    items.append(folderCandidate)
                }
            }
        }
        return items
    }

    // MARK: - Shell rc lines

    static let shellRCFiles = [".zshrc", ".zprofile", ".zshenv", ".bash_profile", ".bashrc", ".profile", ".tcshrc", ".xonshrc", ".config/fish/config.fish"]

    private func shellRCCandidates(identity: AppIdentity, overrides: [VendorOverride], appPath: String, candidates: [Candidate]) -> [Candidate] {
        var markers = overrides.flatMap { $0.shellRCMarkers ?? [] }
        markers.append(appPath)
        for candidate in candidates where candidate.group == "CLI Tools" || candidate.group == "Dotfiles" {
            markers.append(candidate.url.path)
        }
        var out: [Candidate] = []
        for file in Self.shellRCFiles {
            let url = URL(filePath: home).appending(path: file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, markers.contains(where: { trimmed.contains($0) }) else { continue }
                out.append(Candidate(url: url, group: "Shell Integration", tier: .caution, needsRoot: false,
                                     matchedBy: ["shell profile line references the app"],
                                     subtitle: "Line \(index + 1): \(trimmed.prefix(120))", kind: .registration))
            }
        }
        return out
    }

    // MARK: - Shared detection

    private func sharedWith(_ candidate: Candidate, identities: [AppIdentity]) -> String? {
        let name = candidate.url.lastPathComponent
        let allowed: Set<String> = ["bundleID", "subBundleID", "extensionID", "groupID", "name", "executable"]
        for other in identities {
            let reasons = NameMatcher.match(reduced: NameMatcher.reduce(name, style: .plist) + NameMatcher.reduce(name, style: .folder),
                                            identity: other, allowed: allowed, shared: rules.shared)
            if !reasons.isEmpty { return other.name }
        }
        return nil
    }

    private func displayPath(_ url: URL) -> String {
        let path = url.deletingLastPathComponent().path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
