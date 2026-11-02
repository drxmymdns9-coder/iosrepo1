import Foundation

/// Fuzzy title matching for providers that are searched by name rather than keyed on an AniList id.
///
/// A port of the Android app's `NativeProviderParsers` scoring, kept numerically identical so a
/// title resolves to the same post on both apps. The thresholds callers use (AnimeHeaven's 0.28)
/// were tuned against these exact numbers.
public enum TitleMatching {
    private static let nonAlphanumeric = Pattern("[^a-z0-9]", caseInsensitive: false)

    private static let season = Pattern("\\bSeason\\s*0*(\\d+)\\b")
    private static let ordinalSeason = Pattern("\\b0*(\\d+)(?:st|nd|rd|th)\\s+Season\\b")
    private static let romanSeason = Pattern("\\b(II|III|IV|V|VI)\\s*$")

    /// "Gintama 2" is a second season; "Kaiju No. 8" is not an eighth one. A trailing digit after
    /// an abbreviation or a number sign is not read as a season.
    private static let trailingSeason = Pattern("(?<![.#])\\s([2-9])\\s*$")

    /// Everything from a season marker onwards, for turning an AniList sequel name into its series.
    private static let seasonSuffix = Pattern(
        "\\s*[-–—:|(\\[]?\\s*\\b(?:\\d+(?:st|nd|rd|th)\\s+)?(?:the\\s+)?(?:final\\s+)?season\\b.*$",
        dotAll: true
    )

    public static func normalize(_ value: String) -> String {
        nonAlphanumeric.replacing(in: value.lowercased(), with: "")
    }

    public static func titleScore(_ query: String, _ candidate: String) -> Double {
        normalizedScore(normalize(query), normalize(candidate))
    }

    /// Dice coefficient over character bigrams, with exact and containment short-cuts.
    static func normalizedScore(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        if a.contains(b) || b.contains(a) { return 0.86 }
        let left = Array(a.unicodeScalars)
        let right = Array(b.unicodeScalars)
        if left.count < 2 || right.count < 2 { return 0 }
        var counts: [String: Int] = [:]
        for index in 0..<(left.count - 1) {
            counts[String(left[index]) + String(left[index + 1]), default: 0] += 1
        }
        var hits = 0
        for index in 0..<(right.count - 1) {
            let pair = String(right[index]) + String(right[index + 1])
            if let remaining = counts[pair], remaining > 0 {
                hits += 1
                counts[pair] = remaining - 1
            }
        }
        return (2.0 * Double(hits)) / Double((left.count - 1) + (right.count - 1))
    }

    /// Adds a specificity tie-breaker so a base series beats similarly named sequels and spin-offs.
    public static func selectionScore(_ query: String, _ candidate: String) -> Double {
        let a = normalize(query)
        let b = normalize(candidate)
        let similarity = normalizedScore(a, b)
        if a.isEmpty || b.isEmpty || a == b { return similarity }
        let lengthRatio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
        return similarity * (0.6 + 0.4 * lengthRatio)
    }

    /// The season a title claims to cover, in the forms AniList and these sites write it:
    /// "Season 2", "2nd Season", "II" and a bare trailing "2" are all the same claim. `nil` means
    /// no claim, which for a series usually means the first; that reading belongs to the caller.
    public static func seasonNumber(_ title: String) -> Int? {
        if let value = season.firstMatch(in: title)?[1] { return Int(value) }
        if let value = ordinalSeason.firstMatch(in: title)?[1] { return Int(value) }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let roman = romanSeason.firstMatch(in: trimmed)?[1] {
            switch roman.uppercased() {
            case "II": return 2
            case "III": return 3
            case "IV": return 4
            case "V": return 5
            case "VI": return 6
            default: return nil
            }
        }
        return trailingSeason.firstMatch(in: trimmed)?[1].flatMap { Int($0) }
    }

    /// The season an AniList entry is asking for, from whichever of its names numbers one.
    public static func seasonHint(_ titles: [String]) -> Int? {
        titles.lazy.compactMap(seasonNumber).first
    }

    /// "Solo Leveling Season 2 -Arise from the Shadow-" → "Solo Leveling". A name with no season
    /// marker comes back unchanged, so callers can offer it as a query for free.
    public static func baseSeriesTitle(_ title: String) -> String {
        let stripped = seasonSuffix.replacing(in: title, with: "")
        return stripped
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—:|(["))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
