import Foundation

/// TheTVDB's placement of an AniList entry: the series and its season number there (0 for
/// specials). From the media index's id map, which the app bundles as `tvdb-seasons.csv`.
public struct TVDBRef: Equatable, Sendable {
    public var id: Int
    public var season: Int?

    public init(id: Int, season: Int?) {
        self.id = id
        self.season = season
    }

    /// `anilist,tvdb,season` lines; `#` comments and malformed lines are skipped.
    public static func parse(_ text: String) -> [Int: TVDBRef] {
        var refs: [Int: TVDBRef] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: ",")
            guard fields.count == 3, let anilist = Int(fields[0]), let tvdb = Int(fields[1]) else { continue }
            refs[anilist] = TVDBRef(id: tvdb, season: Int(fields[2]))
        }
        return refs
    }
}

/// A season picker's entries and names (Android's `tvdbSeasonChain` and `seasonLabels`).
///
/// AniList has no seasons: "season two" is another entry joined by a sequel relation, and every
/// cour is its own entry. Counting entries named Mushoku Tensei's second half of season two
/// "Season 4". TheTVDB groups cours the way viewers count seasons, so its numbers lead when they
/// place every entry in one series and agree with what the titles say and the airing order;
/// otherwise the titles are read ("Season 3", "3rd Season", "Part 2", "Cour 2").
public enum SeasonLabels {
    /// The relation chain reduced to the entries TheTVDB files as numbered seasons of this
    /// title's series, in season order; nil when it can't place this title (about a fifth of the
    /// catalogue), so the caller keeps its own guess.
    public static func chain(_ info: Media, series: [Media], ref: (Int) -> TVDBRef?) -> [Media]? {
        guard let anchor = ref(info.id), anchor.season != nil else { return nil }
        let placed = series.compactMap { media -> (Int, Media)? in
            guard let entry = ref(media.id), entry.id == anchor.id, let season = entry.season, season >= 1 else { return nil }
            return (season, media)
        }
        // The page's own entry must be in its own chain, or neither source is trusted.
        guard placed.contains(where: { $0.1.id == info.id }) else { return nil }
        var seen = Set<Int>()
        let ordered = placed.enumerated()
            .sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
            .map(\.element.1)
            .filter { seen.insert($0.id).inserted }
        return ordered.count > 1 ? ordered : nil
    }

    /// "Season 2", "Season 2 Part 2", or "Part 3" when every entry is one season split into parts,
    /// by AniList id.
    public static func labels(_ seasons: [Media], ref: (Int) -> TVDBRef?) -> [Int: String] {
        guard !seasons.isEmpty else { return [:] }
        let numbers = tvdbNumbers(seasons, ref: ref).flatMap { agrees(seasons, $0) ? $0 : nil } ?? titleNumbers(seasons)
        var groupSizes: [Int: Int] = [:]
        for number in numbers { groupSizes[number, default: 0] += 1 }
        let singleSeason = groupSizes.count == 1 && seasons.count > 1
        var partSeen: [Int: Int] = [:]
        var labels: [Int: String] = [:]
        for (index, media) in seasons.enumerated() {
            let season = numbers[index]
            partSeen[season, default: 0] += 1
            let part = partSeen[season]!
            if singleSeason {
                labels[media.id] = "Part \(part)"
            } else if (groupSizes[season] ?? 1) > 1 {
                labels[media.id] = "Season \(season) Part \(part)"
            } else {
                labels[media.id] = "Season \(season)"
            }
        }
        return labels
    }

    /// A season that hasn't started airing: shown, faded, and not choosable unless it's the page's own.
    public static func isUpcoming(_ media: Media) -> Bool { media.status == "NOT_YET_RELEASED" }

    public static func choosable(_ season: Media, selected: Int) -> Bool { !isUpcoming(season) || season.id == selected }

    // MARK: - Numbering

    private static func tvdbNumbers(_ seasons: [Media], ref: (Int) -> TVDBRef?) -> [Int]? {
        var refs: [TVDBRef] = []
        for media in seasons {
            guard let found = ref(media.id) else { return nil }
            refs.append(found)
        }
        guard Set(refs.map(\.id)).count == 1 else { return nil }
        var numbers: [Int] = []
        for found in refs {
            guard let season = found.season, season >= 1 else { return nil }
            numbers.append(season)
        }
        return numbers
    }

    /// Every season a title names for itself matches, and the numbers never go down with airing.
    private static func agrees(_ seasons: [Media], _ numbers: [Int]) -> Bool {
        for (index, media) in seasons.enumerated() {
            if let named = explicitSeason(media), named != numbers[index] { return false }
        }
        let byAiring = seasons.indices.filter { seasons[$0].seasonYear != nil }
            .sorted { (seasons[$0].seasonYear!, $0) < (seasons[$1].seasonYear!, $1) }
            .map { numbers[$0] }
        return zip(byAiring, byAiring.dropFirst()).allSatisfy { $0 <= $1 }
    }

    private static func titleNumbers(_ seasons: [Media]) -> [Int] {
        let joined = titleNumbers(seasons, partsJoinPrevious: true)
        let distinct = Array(Set(joined)).sorted()
        let contiguous = zip(distinct, distinct.dropFirst()).allSatisfy { $1 == $0 + 1 }
        return contiguous ? joined : titleNumbers(seasons, partsJoinPrevious: false)
    }

    private static func titleNumbers(_ seasons: [Media], partsJoinPrevious: Bool) -> [Int] {
        var previous = 0
        return seasons.map { media in
            let part = titles(media).lazy.compactMap(titlePart).first
            let joins = partsJoinPrevious && (part ?? 0) >= 2 && previous > 0
            let season = explicitSeason(media) ?? (joins ? previous : previous + 1)
            previous = season
            return season
        }
    }

    private static func titles(_ media: Media) -> [String] { [media.title.english, media.title.romaji].compactMap { $0 } }

    static func explicitSeason(_ media: Media) -> Int? { titles(media).lazy.compactMap(titleSeason).first }

    static func titleSeason(_ title: String) -> Int? {
        (seasonWordFirst.firstMatch(in: title)?[1] ?? seasonOrdinal.firstMatch(in: title)?[1]).flatMap { Int($0) }
    }

    static func titlePart(_ title: String) -> Int? {
        if let token = partWord.firstMatch(in: title)?[1] {
            return Int(token) ?? ["i": 1, "ii": 2, "iii": 3, "iv": 4][token.lowercased()]
        }
        return (courWordFirst.firstMatch(in: title)?[1] ?? courOrdinal.firstMatch(in: title)?[1]).flatMap { Int($0) }
    }

    private static let seasonWordFirst = Pattern(#"\bseason\s*(\d{1,2})\b"#)
    private static let seasonOrdinal = Pattern(#"\b(\d{1,2})(?:st|nd|rd|th)\s+season\b"#)
    private static let partWord = Pattern(#"\bpart\s*(\d{1,2}|iv|i{1,3})\b"#)
    private static let courWordFirst = Pattern(#"\bcour\s*(\d{1,2})\b"#)
    private static let courOrdinal = Pattern(#"\b(\d{1,2})(?:st|nd|rd|th)\s+cour\b"#)
}
