import Foundation

/// One root directory the deep dive lists, with the signals allowed to attribute its children.
public struct LeftoverRoot: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var root: String?
    public var roots: [String]?
    public var depth: Int
    public var group: String
    public var tier: RiskTier
    public var needsRoot: Bool?
    public var match: [String]
    public var nameStyle: NameStyle
    public var skipChildren: [String]?
    public var onlyNonStandard: Bool?

    public var allRoots: [String] { roots ?? (root.map { [$0] } ?? []) }
    public var requiresRoot: Bool { needsRoot ?? false }
}

public struct LeftoverCatalogue: Codable, Sendable {
    public var version: Int
    public var roots: [LeftoverRoot]
    public var standardLibrarySubdirectories: [String]
}

public struct SharedIdentifiers: Codable, Sendable {
    public var bundleIdentifiers: [String]
    public var bundleIdentifierPrefixes: [String]
    public var names: [String]

    public func isShared(bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        if bundleIdentifiers.contains(where: { $0.lowercased() == lower }) { return true }
        return bundleIdentifierPrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }

    public func isGenericName(_ normalized: String) -> Bool {
        names.contains(normalized)
    }
}

public struct OverridePath: Codable, Sendable, Hashable {
    public var path: String
    public var group: String
    public var tier: RiskTier
    public var needsRoot: Bool?
    public var sharedNote: String?
    /// Listed only when everything inside the folder is already part of the same removal (a vendor folder the removal empties).
    public var onlyIfEmptyAfter: Bool?
    /// Other apps known to use this path (bundle-ID patterns, see `BundleIDPattern`). When one of them is installed the path is caution.
    public var sharedWith: [String]?
}

/// Bundle-ID patterns used by the rule files: an exact, case-insensitive identifier, or a whole namespace when the pattern ends in ".".
public enum BundleIDPattern {
    public static func matches(_ pattern: String, _ bundleID: String) -> Bool {
        let p = pattern.lowercased()
        let id = bundleID.lowercased()
        guard !p.isEmpty, !id.isEmpty else { return false }
        return p.hasSuffix(".") ? id.hasPrefix(p) : id == p
    }

    public static func matchesAny(_ patterns: [String], _ bundleID: String) -> Bool {
        patterns.contains { matches($0, bundleID) }
    }
}

public struct VendorOverride: Codable, Sendable, Hashable {
    /// The app's bundle ID. Matched exactly, or as a namespace prefix when it ends in "." (`com.microsoft.`), so a rule for
    /// `com.google.Chrome` never applies to `com.google.Chrome.canary` or to Chrome's web-app shims.
    public var bundleIDPrefix: String
    /// Further bundle IDs (same pattern rules) the rule applies to, for paths several channels of one product share.
    public var bundleIDs: [String]?
    public var include: [OverridePath]?
    public var exclude: [String]?
    public var pkgReceipts: [String]?
    public var launchdLabels: [String]?
    public var shellRCMarkers: [String]?

    public func matches(bundleID: String) -> Bool {
        BundleIDPattern.matches(bundleIDPrefix, bundleID) || BundleIDPattern.matchesAny(bundleIDs ?? [], bundleID)
    }
}

public struct VendorOverrides: Codable, Sendable {
    public var overrides: [VendorOverride]

    public func matching(bundleID: String) -> [VendorOverride] {
        overrides.filter { $0.matches(bundleID: bundleID) }
    }
}

/// Known software families (installers, updaters, helpers) whose traces are reported under Remains when the software is gone.
public struct LeftoverFamily: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var bundleIDPrefixes: [String]
    public var tokens: [String]
    public var paths: [String]
    public var pkgReceipts: [String]
    public var launchdLabels: [String]
    public var processNames: [String]
    /// The software counts as installed when any of these exists (paths or globs: runtimes, CLI tools, non-app bundles,
    /// or competing products that use the same files).
    public var installedIfExists: [String]?
    /// Paths (globs) reported at caution because other tools may use them too.
    public var cautionPaths: [String]?

    /// Normalised tokens matched against path components.
    public var normalizedTokens: [String] { tokens.map { NameMatcher.normalize($0) }.filter { $0.count >= 4 } }
}

public struct LeftoverFamilies: Codable, Sendable {
    public var families: [LeftoverFamily]
}

public struct ProtectedRules: Codable, Sendable {
    public var pathPrefixes: [String]
    public var exactPaths: [String]
    public var bundleIdentifierPrefixes: [String]
    public var bundleIdentifierContains: [String]?
    public var hostsFileLinesKept: [String]

    /// True when the path may never be removed.
    public func isProtected(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let standardized = URL(filePath: path).standardizedFileURL.path
        for exact in exactPaths {
            let expanded = exact.hasPrefix("~") ? home + exact.dropFirst() : exact
            if standardized == expanded { return true }
        }
        for prefix in pathPrefixes {
            let expanded = prefix.hasPrefix("~") ? home + prefix.dropFirst() : prefix
            if standardized.hasPrefix(expanded) { return true }
        }
        return false
    }

    public func isProtected(bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        if bundleIdentifierPrefixes.contains(where: { lower.hasPrefix($0.lowercased()) }) { return true }
        return (bundleIdentifierContains ?? []).contains { lower.contains($0.lowercased()) }
    }
}

/// All rule files, loaded once from the package resources.
public struct Rules: Sendable {
    public let catalogue: LeftoverCatalogue
    public let shared: SharedIdentifiers
    public let overrides: VendorOverrides
    public let protectedRules: ProtectedRules
    public let families: [LeftoverFamily]

    public init(catalogue: LeftoverCatalogue, shared: SharedIdentifiers, overrides: VendorOverrides, protectedRules: ProtectedRules, families: [LeftoverFamily] = []) {
        self.catalogue = catalogue
        self.shared = shared
        self.overrides = overrides
        self.protectedRules = protectedRules
        self.families = families
    }

    public static func load() throws -> Rules { try load(from: .module) }

    public static func load(from bundle: Bundle) throws -> Rules {
        func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
            guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Resources")
                    ?? bundle.url(forResource: name, withExtension: "json") else {
                throw RulesError.missing(name)
            }
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        }
        return Rules(
            catalogue: try read("leftover-catalogue", as: LeftoverCatalogue.self),
            shared: try read("shared-identifiers", as: SharedIdentifiers.self),
            overrides: try read("vendor-overrides", as: VendorOverrides.self),
            protectedRules: try read("protected", as: ProtectedRules.self),
            families: (try? read("leftover-families", as: LeftoverFamilies.self).families) ?? []
        )
    }

    /// The bundled rules. Loading cannot fail unless the package is corrupt, in which case scanning is pointless.
    public static let bundled: Rules = {
        do { return try load() } catch { fatalError("CleanCore rules failed to load: \(error)") }
    }()

    public enum RulesError: Error, LocalizedError {
        case missing(String)
        public var errorDescription: String? {
            switch self { case .missing(let name): "Rule file \(name).json is missing from the CleanCore bundle." }
        }
    }
}

/// Expands `~`, `$USER` and the per-user `$DARWIN_USER_*` directories in rule paths.
public enum PathExpander {
    public static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        var result = path
        if result.hasPrefix("~") { result = home + result.dropFirst() }
        if result.contains("$USER") { result = result.replacingOccurrences(of: "$USER", with: NSUserName()) }
        for (token, name) in [("$DARWIN_USER_CACHE_DIR", _CS_DARWIN_USER_CACHE_DIR),
                              ("$DARWIN_USER_TEMP_DIR", _CS_DARWIN_USER_TEMP_DIR),
                              ("$DARWIN_USER_DIR", _CS_DARWIN_USER_DIR)] where result.contains(token) {
            result = result.replacingOccurrences(of: token, with: confstrValue(name))
        }
        if result.hasSuffix("/") && result.count > 1 { result.removeLast() }
        return result
    }

    static func confstrValue(_ name: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(name, &buffer, buffer.count)
        guard length > 0 else { return "" }
        var value = String(cString: buffer)
        if value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// Expands a path that may contain `*` wildcards into the existing matches.
    public static func glob(_ pattern: String) -> [String] {
        guard pattern.contains("*") else {
            return FileManager.default.fileExists(atPath: pattern) ? [pattern] : []
        }
        var results: [String] = []
        var globResult = glob_t()
        defer { globfree(&globResult) }
        if Darwin.glob(pattern, GLOB_TILDE | GLOB_BRACE | GLOB_NOSORT, nil, &globResult) == 0 {
            for i in 0..<Int(globResult.gl_matchc) {
                if let cString = globResult.gl_pathv[i] { results.append(String(cString: cString)) }
            }
        }
        return results
    }
}
