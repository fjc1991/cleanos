import Foundation

/// Compares dotted version strings the way Sparkle and Homebrew expect: numeric components compare
/// numerically, missing trailing components count as zero, and a non-numeric suffix (`1.2.0_1`,
/// `2.56.0-beta`) sorts after the plain version.
public enum VersionComparison {
    public enum Result: Sendable { case older, same, newer }

    public static func compare(_ lhs: String, to rhs: String) -> Result {
        let l = components(of: lhs), r = components(of: rhs)
        let count = max(l.count, r.count)
        for i in 0..<count {
            let a = i < l.count ? l[i] : .number(0)
            let b = i < r.count ? r[i] : .number(0)
            switch (a, b) {
            case let (.number(x), .number(y)):
                if x != y { return x < y ? .older : .newer }
            case let (.text(x), .text(y)):
                if x != y { return x < y ? .older : .newer }
            case (.number, .text):
                return .newer   // "1.2" > "1.2-beta"
            case (.text, .number):
                return .older
            }
        }
        return .same
    }

    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, to: installed) == .newer
    }

    enum Component: Equatable { case number(Int), text(String) }

    static func components(of version: String) -> [Component] {
        var out: [Component] = []
        var current = ""
        var isNumber: Bool?
        func flush() {
            guard !current.isEmpty else { return }
            if let n = Int(current) { out.append(.number(n)) } else { out.append(.text(current.lowercased())) }
            current = ""
            isNumber = nil
        }
        for ch in version.trimmingCharacters(in: .whitespaces) {
            if ch == "." || ch == "-" || ch == "_" || ch == "+" || ch == " " || ch == "(" || ch == ")" {
                flush(); continue
            }
            let digit = ch.isNumber
            if let isNumber, isNumber != digit { flush() }
            isNumber = digit
            current.append(ch)
        }
        flush()
        return out
    }
}
