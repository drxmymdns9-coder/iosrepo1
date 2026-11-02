import Foundation

/// A compiled `NSRegularExpression`, held once per pattern.
///
/// ICU rather than Swift `Regex` because the parsers ported from the Android app lean on
/// lookbehind (`(?<![.#])`), which Swift's regex engine does not support. Compiling once matters
/// for the same reason it did on Android: these run per element over whole pages.
public struct Pattern: @unchecked Sendable {
    public struct Match {
        /// The whole match.
        public let range: Range<String.Index>
        /// Capture groups, `nil` where a group did not participate. Index 0 is the whole match.
        public let groups: [String?]

        public subscript(group: Int) -> String? { group < groups.count ? groups[group] : nil }
    }

    private let regex: NSRegularExpression

    public init(_ pattern: String, caseInsensitive: Bool = true, dotAll: Bool = false, anchorsMatchLines: Bool = false) {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        if anchorsMatchLines { options.insert(.anchorsMatchLines) }
        // A pattern here is a literal in this codebase; a typo should fail the first test that
        // touches it, not degrade silently.
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    public func matches(in text: String, range: Range<String.Index>? = nil) -> [Match] {
        let searchRange = NSRange(range ?? text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: searchRange).compactMap { result in
            guard let whole = Range(result.range, in: text) else { return nil }
            let groups: [String?] = (0..<result.numberOfRanges).map { index in
                Range(result.range(at: index), in: text).map { String(text[$0]) }
            }
            return Match(range: whole, groups: groups)
        }
    }

    public func firstMatch(in text: String, range: Range<String.Index>? = nil) -> Match? {
        let searchRange = NSRange(range ?? text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, range: searchRange),
              let whole = Range(result.range, in: text) else { return nil }
        let groups: [String?] = (0..<result.numberOfRanges).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) }
        }
        return Match(range: whole, groups: groups)
    }

    public func contains(in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    /// Replaces every match with `template`, which uses `$1`-style references.
    public func replacing(in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: template
        )
    }

    /// Replaces every match with the string `transform` builds from it.
    public func replacing(in text: String, transform: (Match) -> String) -> String {
        var output = ""
        var cursor = text.startIndex
        for match in matches(in: text) {
            output += text[cursor..<match.range.lowerBound]
            output += transform(match)
            cursor = match.range.upperBound
        }
        output += text[cursor...]
        return output
    }

    public static func escape(_ literal: String) -> String {
        NSRegularExpression.escapedPattern(for: literal)
    }
}
