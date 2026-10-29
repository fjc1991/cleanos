import Foundation

/// How risky it is to remove an item. Drives default selection and whether the checkbox is enabled.
public enum RiskTier: String, Codable, Sendable, CaseIterable, Comparable {
    /// Regenerable data: caches, logs, saved state, crash reports.
    case safe
    /// Settings and app data that only matter while the app is installed.
    case normal
    /// User content, shared vendor folders, keychain items: listed but unselected by default.
    case caution
    /// Shown for transparency, can never be selected.
    case protected

    public var isSelectableByDefault: Bool { self == .safe || self == .normal }
    public var isSelectable: Bool { self != .protected }

    public var title: String {
        switch self {
        case .safe: "Safe"
        case .normal: "Normal"
        case .caution: "Caution"
        case .protected: "Protected"
        }
    }

    private var order: Int { RiskTier.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: RiskTier, rhs: RiskTier) -> Bool { lhs.order < rhs.order }
}

/// What kind of thing a `ScanItem` points at.
public enum ItemKind: String, Codable, Sendable {
    case file, directory, bundle, symlink
    /// A non-file trace: Launch Services handler, TCC row, keychain item, Dock tile…
    case registration
    /// A mounted volume (used by the Overview and per-volume categories).
    case volume
    /// A grouping node that only exists to organise children.
    case group
}

/// The single model every scanner produces and every section renders.
/// `size` is the total size of the item including its children.
public struct ScanItem: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var url: URL?
    public var title: String
    public var subtitle: String?
    public var kind: ItemKind
    /// Expert-Mode heading, e.g. "Caches", "Preferences", "Login Items".
    public var group: String
    public var size: Int64
    public var tier: RiskTier
    /// The identity signals that attributed this item to an app, e.g. ["bundleID", "launchd Program path"].
    public var matchedBy: [String]
    public var needsRoot: Bool
    public var modificationDate: Date?
    public var children: [ScanItem]
    /// Registration details (type, keys) consumed by `RegistrationRemover`; empty for files.
    public var payload: [String: String]

    public init(id: String? = nil, url: URL? = nil, title: String, subtitle: String? = nil, kind: ItemKind,
                group: String, size: Int64 = 0, tier: RiskTier = .normal, matchedBy: [String] = [],
                needsRoot: Bool = false, modificationDate: Date? = nil, children: [ScanItem] = [],
                payload: [String: String] = [:]) {
        self.id = id ?? url?.standardizedFileURL.path ?? "\(group)/\(title)"
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.group = group
        self.size = size
        self.tier = tier
        self.matchedBy = matchedBy
        self.needsRoot = needsRoot
        self.modificationDate = modificationDate
        self.children = children
        self.payload = payload
    }

    /// Pre-order traversal of this item and all descendants.
    public var flattened: [ScanItem] {
        var out: [ScanItem] = [self]
        for child in children { out.append(contentsOf: child.flattened) }
        return out
    }

    /// Leaf items only (what actually gets removed).
    public var leaves: [ScanItem] {
        children.isEmpty ? [self] : children.flatMap(\.leaves)
    }

    /// Sum of leaf sizes, useful for group nodes whose own `size` was not computed.
    public var leafSize: Int64 { children.isEmpty ? size : children.reduce(0) { $0 + $1.leafSize } }

    /// Returns a copy with `size` set to the sum of children for every group node.
    public func rollingUpSizes() -> ScanItem {
        var copy = self
        copy.children = children.map { $0.rollingUpSizes() }
        if !copy.children.isEmpty { copy.size = copy.children.reduce(0) { $0 + $1.size } }
        return copy
    }
}

public extension Int64 {
    /// Human-readable byte count using the system formatter (`13.59 GB`).
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
