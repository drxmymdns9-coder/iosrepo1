import Foundation

/// Tag-soup helpers for scraping provider pages, ported from the Android app's
/// `NativeProviderParsers`.
///
/// Provider markup is hand-written and inconsistent: attributes are quoted with apostrophes as
/// often as with double quotes, sometimes not quoted at all, and tags carry stray whitespace
/// (`<div  class= ' watch2 bc ' >`). Everything here tolerates all three.
public enum HTML {
    private static let htmlTag = Pattern("<[^>]*>")
    private static let whitespaceRun = Pattern("\\s+")
    private static let decimalEntity = Pattern("&#(\\d+);")
    private static let hexEntity = Pattern("&#x([0-9a-f]+);")

    private static let cache = AttributePatternCache()

    /// The value of attribute `name` on `tag`, entity-decoded, or `""` when it is absent.
    public static func attr(_ tag: String, _ name: String) -> String {
        let (quoted, unquoted) = cache.patterns(for: name)
        // Group 2 because group 1 captures which quote opened the value.
        if let value = quoted.firstMatch(in: tag)?[2] {
            return decodeEntities(value)
        }
        // Some providers emit unquoted attribute values.
        if let value = unquoted.firstMatch(in: tag)?[1] {
            return decodeEntities(value)
        }
        return ""
    }

    public static func stripTags(_ html: String) -> String {
        let spaced = htmlTag.replacing(in: html, with: " ")
        return decodeEntities(whitespaceRun.replacing(in: spaced, with: " ").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func decodeEntities(_ value: String) -> String {
        // Most attribute values and text runs contain neither marker, so skip every pass below.
        guard value.contains("&") || value.contains("\\") else { return value }
        var decoded = value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        decoded = decimalEntity.replacing(in: decoded) { match in
            guard let code = match[1].flatMap({ UInt32($0) }), let scalar = Unicode.Scalar(code) else {
                return String(decoded[match.range])
            }
            return String(Character(scalar))
        }
        decoded = hexEntity.replacing(in: decoded) { match in
            guard let code = match[1].flatMap({ UInt32($0, radix: 16) }), let scalar = Unicode.Scalar(code) else {
                return String(decoded[match.range])
            }
            return String(Character(scalar))
        }
        return decoded.replacingOccurrences(of: "\\/", with: "/")
    }

    /// The text of an AniList description, which arrives with `<br>` and `<i>` even when asked for
    /// plain text.
    public static func plainDescription(_ html: String) -> String {
        let withBreaks = html
            .replacingOccurrences(of: "<br><br>", with: "\n\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
        let stripped = htmlTag.replacing(in: withBreaks, with: "")
        return decodeEntities(stripped)
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Attribute patterns keyed by attribute name. Names always come from literals in this codebase,
/// so the key set is closed and needs no eviction.
private final class AttributePatternCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (Pattern, Pattern)] = [:]

    func patterns(for name: String) -> (Pattern, Pattern) {
        lock.lock()
        defer { lock.unlock() }
        if let cached = entries[name] { return cached }
        let escaped = Pattern.escape(name)
        let built = (
            Pattern("\\b\(escaped)\\s*=\\s*([\"'])(.*?)\\1", dotAll: true),
            Pattern("\\b\(escaped)\\s*=\\s*([^\"'\\s>]+)")
        )
        entries[name] = built
        return built
    }
}
