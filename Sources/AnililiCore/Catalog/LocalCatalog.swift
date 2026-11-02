import Foundation

/// The media index's title list (`index.json`, about 20,000 titles) searched on the device, as the
/// Android app's `LocalCatalog` and the desktop's `search_titles` do.
///
/// AniList matches whole words only, so a half-typed "one pie" finds little there; this answers
/// with titles *containing* the text, ranked whole title → starts with → contains, popularity
/// breaking ties. Browse merges it in when AniList's first page comes back thin or fails.
public actor LocalCatalog {
    public static let shared = LocalCatalog()

    public struct Title: Decodable, Sendable, Equatable {
        public var id: Int
        public var title: String
        public var popularity: Int?
        public var format: String?
        public var genres: [String]?
        public var poster: String?
        public var poster_color: String?
        public var year: Int?
        public var status: String?
        public var episodes: Int?
        public var score: Int?

        /// The list has no adult flag; AniList's Hentai genre marks the same titles.
        public var isAdult: Bool { genres?.contains("Hentai") == true }

        /// The row as a card. The poster is asked for at AniList's `large` size where its CDN has
        /// one (`bx`/`nx` uploads come in every size at the same path).
        public var media: Media {
            var media = Media(id: id, title: .init(english: title))
            var cover = poster
            if let poster, let range = poster.range(of: "/cover/medium/") {
                let file = poster[range.upperBound...]
                if file.hasPrefix("bx") || file.hasPrefix("nx") {
                    cover = poster.replacingCharacters(in: range, with: "/cover/large/")
                }
            }
            media.coverImage = .init(large: cover, color: poster_color)
            media.format = format
            media.genres = genres
            media.seasonYear = year
            media.status = status
            media.episodes = episodes
            media.averageScore = score
            media.popularity = popularity
            media.isAdult = isAdult
            return media
        }
    }

    typealias Fetch = @Sendable (URL) async throws -> Data?

    private let fetch: Fetch
    private var titles: [Title]?
    private var loadedAt = Date.distantPast
    static let ttl: TimeInterval = 24 * 60 * 60

    public init() {
        fetch = { url in
            let (data, response) = try await HTTP.data(url)
            guard (200..<300).contains(response.statusCode) else { return nil }
            return data
        }
    }

    init(titles: [Title]) {
        fetch = { _ in nil }
        self.titles = titles
        loadedAt = Date()
    }

    public func search(_ filters: DiscoverFilters, hideAdult: Bool, dubbedIDs: Set<Int>, excludedIDs: Set<Int>) async -> [Media] {
        await load()
        return Self.search(titles ?? [], filters, hideAdult: hideAdult, dubbedIDs: dubbedIDs, excludedIDs: excludedIDs)
    }

    /// Settings → Data → Re-download metadata: reads the title list again now. Returns how many
    /// titles it holds, or nil when it couldn't be read (the old list stays).
    public func refresh() async -> Int? {
        loadedAt = .distantPast
        await load()
        return Date().timeIntervalSince(loadedAt) < Self.ttl ? titles?.count : nil
    }

    private func load() async {
        if titles != nil, Date().timeIntervalSince(loadedAt) < Self.ttl { return }
        guard let url = URL(string: "\(MediaIndex.base)/index.json") else { return }
        do {
            guard let data = try await fetch(url) else { return }
            titles = try JSONDecoder().decode([Title].self, from: data)
            loadedAt = Date()
            Log.info("catalog", "local title list: \(titles?.count ?? 0) titles")
        } catch {
            Log.warning("catalog", "local title list failed: \(Log.describe(error))")
        }
    }

    /// A filter the list has no field for (tags, season, country, source, studio) returns nothing
    /// rather than results that contradict the chips on screen.
    static func search(_ titles: [Title], _ filters: DiscoverFilters, hideAdult: Bool, dubbedIDs: Set<Int>, excludedIDs: Set<Int>) -> [Media] {
        let needle = filters.query.trimmingCharacters(in: .whitespaces).lowercased()
        let unsupported = !filters.tags.isEmpty || !filters.excludedTags.isEmpty || filters.season != nil
            || filters.country != nil || filters.source != nil || filters.studioID != nil
        guard !needle.isEmpty, !unsupported else { return [] }

        func matches(_ value: String?, _ wanted: String?) -> Bool {
            guard let wanted else { return true }
            return value?.caseInsensitiveCompare(wanted) == .orderedSame
        }
        var ranked: [(rank: Int, title: Title)] = []
        for title in titles {
            if hideAdult && title.isAdult { continue }
            let genres = Set(title.genres ?? [])
            if !filters.genres.isEmpty && genres.isDisjoint(with: filters.genres) { continue }
            if !genres.isDisjoint(with: filters.excludedGenres) { continue }
            if let year = filters.year, title.year != year { continue }
            if let from = filters.yearFrom, (title.year ?? Int.min) < from { continue }
            if let to = filters.yearTo, (title.year ?? Int.max) > to { continue }
            if !matches(title.status, filters.status) || !matches(title.format, filters.format) { continue }
            if let minimum = filters.episodesMin, (title.episodes ?? Int.min) < minimum { continue }
            if let maximum = filters.episodesMax, (title.episodes ?? Int.max) > maximum { continue }
            if let score = filters.minimumScore, (title.score ?? 0) < score { continue }
            if filters.dubbedOnly && !dubbedIDs.contains(title.id) { continue }
            if excludedIDs.contains(title.id) { continue }
            let name = title.title.lowercased()
            let rank: Int
            if name == needle { rank = 0 } else if name.hasPrefix(needle) { rank = 1 } else if name.contains(needle) { rank = 2 } else { continue }
            ranked.append((rank, title))
        }
        let popularity = { (title: Title) in title.popularity ?? 0 }
        switch filters.sort {
        case let sort where sort.hasPrefix("SCORE"):
            ranked.sort { ($0.title.score ?? 0, popularity($0.title)) > ($1.title.score ?? 0, popularity($1.title)) }
        case let sort where sort.hasPrefix("START_DATE"):
            ranked.sort { ($0.title.year ?? 0, popularity($0.title)) > ($1.title.year ?? 0, popularity($1.title)) }
        case "SEARCH_MATCH":
            ranked.sort { $0.rank != $1.rank ? $0.rank < $1.rank : popularity($0.title) > popularity($1.title) }
        default:
            // A snapshot can't know what's trending this week; popularity is the honest stand-in.
            // A typed query still puts the closest names first.
            ranked.sort { $0.rank != $1.rank ? $0.rank < $1.rank : popularity($0.title) > popularity($1.title) }
        }
        return ranked.prefix(30).map(\.title.media)
    }
}
