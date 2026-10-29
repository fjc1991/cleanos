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

    /// Finds everything that belongs to `app`. `otherApps` are the remaining installed apps, used to flag shared items.
    public func locate(app: InstalledApp, otherApps: [InstalledApp], includeExecutable: Bool = true,
                       skipList: [String] = []) async -> LeftoverScanResult {
        let start = Date()
        var identity = app.identity
        let overrides = rules.overrides.matching(bundleID: identity.bundleID)
        for override in overrides {
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
        let receiptIDs = matchingReceipts(identity: identity, overrides: overrides)
        let manifestPaths = receiptManifestPaths(for: receiptIDs)

        var cancelled = false
        for root in rules.catalogue.roots {
            if Task.isCancelled { cancelled = true; break }
            for rootPath in root.allRoots {
                let expanded = PathExpander.expand(rootPath, home: home)
                guard !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded) else { continue }
                candidates.append(contentsOf: scanRoot(URL(filePath: expanded), rule: root, identity: identity, appPath: appPath,
                                                       receiptIDs: receiptIDs, manifestPaths: manifestPaths))
            }
        }

        if !cancelled {
            candidates.append(contentsOf: overrideCandidates(overrides, identity: identity))
            candidates.append(contentsOf: manifestCandidates(manifestPaths, candidates: candidates))
            candidates.append(contentsOf: shellRCCandidates(identity: identity, overrides: overrides, appPath: appPath, candidates: candidates))
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
                if candidate.tier > existing.tier { existing.tier = candidate.tier }
                if existing.subtitle == nil { existing.subtitle = candidate.subtitle }
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

        let otherIdentities = otherApps.filter { $0.url != app.url }.map(\.identity)
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
            if deduped[index].kind != .registration, deduped[index].group != "Executables",
               let sharer = sharedWith(deduped[index], identities: otherIdentities) {
                if deduped[index].tier < .caution { deduped[index].tier = .caution }
                deduped[index].subtitle = "Shared with \(sharer)"
            }
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

    // MARK: - Catalogue roots

    private func scanRoot(_ root: URL, rule: LeftoverRoot, identity: AppIdentity, appPath: String,
                          receiptIDs: Set<String>, manifestPaths: Set<String>) -> [Candidate] {
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
            var reasons = NameMatcher.match(reduced: reducedNames(for: child, style: rule.nameStyle),
                                            identity: identity, allowed: allowed, shared: rules.shared)
            reasons.append(contentsOf: contentSignals(child, values: values, rule: rule, allowed: allowed, identity: identity,
                                                      appPath: appPath, receiptIDs: receiptIDs, manifestPaths: manifestPaths))
            reasons = Array(NSOrderedSet(array: reasons)) as? [String] ?? reasons

            let vendorOnly = reasons == ["vendor folder"]
            if vendorOnly, rule.depth >= 2, isDirectory {
                out.append(contentsOf: scanVendorFolder(child, rule: rule, identity: identity, appPath: appPath))
                continue
            }
            if vendorOnly {
                // Vendor-named item at depth 1 (e.g. ~/Library/Dropbox, /Library/Google): keep but mark cautious.
                out.append(Candidate(url: child, group: rule.group, tier: max(rule.tier, .caution), needsRoot: rule.requiresRoot,
                                     matchedBy: reasons, subtitle: "Vendor folder, may be shared by other apps from \(identity.developerName ?? identity.vendor ?? "this developer")",
                                     kind: isDirectory ? .directory : .file))
                continue
            }
            guard !reasons.isEmpty else { continue }
            out.append(Candidate(url: child, group: rule.group, tier: rule.tier, needsRoot: rule.requiresRoot, matchedBy: reasons,
                                 kind: isDirectory ? .directory : .file))
        }
        return out
    }

    /// Looks inside a vendor folder (`~/Library/Application Support/Google/`) for the app's product folder.
    private func scanVendorFolder(_ folder: URL, rule: LeftoverRoot, identity: AppIdentity, appPath: String) -> [Candidate] {
        let allowed: Set<String> = ["bundleID", "subBundleID", "extensionID", "name", "executable"]
        guard let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var matched: [Candidate] = []
        for child in children where child.lastPathComponent != ".DS_Store" {
            let reasons = NameMatcher.match(reduced: reducedNames(for: child, style: .folder), identity: identity, allowed: allowed, shared: rules.shared)
            guard !reasons.isEmpty else { continue }
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            matched.append(Candidate(url: child, group: rule.group, tier: rule.tier, needsRoot: rule.requiresRoot,
                                     matchedBy: ["vendor folder"] + reasons, kind: isDirectory ? .directory : .file))
        }
        let realChildren = children.filter { $0.lastPathComponent != ".DS_Store" }
        if !matched.isEmpty, matched.count == realChildren.count {
            return [Candidate(url: folder, group: rule.group, tier: rule.tier, needsRoot: rule.requiresRoot,
                              matchedBy: ["vendor folder (all contents belong to this app)"], kind: .directory)]
        }
        if matched.isEmpty, realChildren.isEmpty {
            return [Candidate(url: folder, group: rule.group, tier: .safe, needsRoot: rule.requiresRoot,
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

    private func contentSignals(_ url: URL, values: URLResourceValues?, rule: LeftoverRoot, allowed: Set<String>, identity: AppIdentity,
                                appPath: String, receiptIDs: Set<String>, manifestPaths: Set<String>) -> [String] {
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
                    !rules.protectedRules.isProtected(bundleID: id) { reasons.append("plug-in from the same developer (\(id))") }
        }
        if allowed.contains("pkgReceipt") {
            if rule.nameStyle == .receipt {
                let id = NameMatcher.reduce(url.lastPathComponent, style: .receipt).first ?? ""
                if receiptIDs.contains(id) { reasons.append("package receipt") }
            } else if manifestPaths.contains(url.standardizedFileURL.path) {
                reasons.append("installed by the app's package")
            }
        }
        return reasons
    }

    // MARK: - Receipts

    /// Package receipts that belong to the app: listed by a vendor override, or sharing the vendor prefix and the product name.
    private func matchingReceipts(identity: AppIdentity, overrides: [VendorOverride]) -> Set<String> {
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: "/private/var/db/receipts") else { return [] }
        let ids = Set(all.filter { $0.hasSuffix(".plist") }.map { String($0.dropLast(6)).lowercased() })
        var matched: Set<String> = []
        let patterns = overrides.flatMap { $0.pkgReceipts ?? [] }.map { $0.lowercased() }
        for id in ids {
            if rules.protectedRules.isProtected(bundleID: id) { continue }
            if patterns.contains(where: { fnmatch($0, id, 0) == 0 }) { matched.insert(id); continue }
            guard let prefix = identity.vendorPrefix, id.hasPrefix(prefix + ".") else { continue }
            let normalizedID = NameMatcher.normalize(id.replacingOccurrences(of: ".", with: " "))
            let names = identity.normalizedNames.filter { $0.count >= 4 }
            let lastComponent = identity.bundleID.split(separator: ".").last.map { NameMatcher.normalize(String($0)) } ?? ""
            if names.contains(where: { normalizedID.contains($0) }) || (lastComponent.count >= 4 && normalizedID.contains(lastComponent)) {
                matched.insert(id)
            }
        }
        return matched
    }

    /// Top-level paths (≤ 3 components below the install location) recorded in the receipts' bill of materials.
    private func receiptManifestPaths(for receiptIDs: Set<String>) -> Set<String> {
        var paths: Set<String> = []
        for id in receiptIDs {
            guard let output = runPkgutil(["--files", id]) else { continue }
            let volume = runPkgutil(["--pkg-info", id])?
                .split(separator: "\n").first { $0.hasPrefix("volume:") }.map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) } ?? "/"
            let location = runPkgutil(["--pkg-info", id])?
                .split(separator: "\n").first { $0.hasPrefix("location:") }.map { String($0.dropFirst(9)).trimmingCharacters(in: .whitespaces) } ?? ""
            let base = URL(filePath: volume).appending(path: location)
            for line in output.split(separator: "\n") {
                let relative = String(line)
                guard !relative.isEmpty, relative.split(separator: "/").count <= 3 else { continue }
                let full = base.appending(path: relative).standardizedFileURL.path
                if FileManager.default.fileExists(atPath: full) { paths.insert(full) }
            }
        }
        return paths
    }

    private func runPkgutil(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/pkgutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    /// Manifest entries that are not already candidates (e.g. `/Library/Frameworks/R.framework`).
    private func manifestCandidates(_ manifestPaths: Set<String>, candidates: [Candidate]) -> [Candidate] {
        let existing = Set(candidates.map { $0.url.standardizedFileURL.path })
        var out: [Candidate] = []
        var sorted = Array(manifestPaths).sorted()
        // Drop children of other manifest paths so the deepest common parent is shown.
        sorted = sorted.filter { path in !sorted.contains { other in other != path && path.hasPrefix(other + "/") } }
        for path in sorted where !existing.contains(path) {
            if rules.protectedRules.isProtected(path, home: home) { continue }
            let url = URL(filePath: path)
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let group: String = path.hasPrefix("/usr/local") ? "CLI Tools" : path.hasPrefix("/Library/Frameworks") ? "Runtime" :
                path.hasPrefix("/Applications") ? "Executables" : "Application Support"
            out.append(Candidate(url: url, group: group, tier: group == "Runtime" ? .caution : .normal,
                                 needsRoot: !FileRemover.isUserRemovable(url), matchedBy: ["installed by the app's package"],
                                 kind: isDirectory ? .directory : .file))
        }
        return out
    }

    // MARK: - Vendor overrides

    private func overrideCandidates(_ overrides: [VendorOverride], identity: AppIdentity) -> [Candidate] {
        var out: [Candidate] = []
        for override in overrides {
            for include in override.include ?? [] {
                for path in PathExpander.glob(PathExpander.expand(include.path, home: home)) {
                    let url = URL(filePath: path)
                    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    out.append(Candidate(url: url, group: include.group, tier: include.tier,
                                         needsRoot: include.needsRoot ?? !FileRemover.isUserRemovable(url),
                                         matchedBy: ["vendor rule"], subtitle: include.sharedNote, kind: isDirectory ? .directory : .file))
                }
            }
        }
        return out
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
