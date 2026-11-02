import Foundation

/// One option in a Browse filter: the value AniList takes and the label the chip shows.
public struct CatalogChoice: Hashable, Sendable, Identifiable {
    public let value: String
    public let label: String
    public var id: String { value }

    public init(_ value: String, _ label: String) {
        self.value = value
        self.label = label
    }
}

/// An inclusive span (an episode-count bucket, a decade); either end may be open.
public struct RangeChoice: Hashable, Sendable, Identifiable {
    public let label: String
    public let from: Int?
    public let to: Int?
    public var id: String { label }
}

/// Browse's filters, a port of the Android app's `DiscoverFilters`; every one is applied by AniList.
public struct DiscoverFilters: Equatable, Sendable {
    public var query = ""
    public var genres: Set<String> = []
    public var tags: Set<String> = []
    public var excludedGenres: Set<String> = []
    public var excludedTags: Set<String> = []
    public var year: Int?
    public var season: String?
    /// A span of release years; exclusive with `year`, which pairs with the season chips.
    public var yearFrom: Int?
    public var yearTo: Int?
    public var status: String?
    public var format: String?
    /// ISO 3166-1 alpha-2: `JP` anime, `CN` donghua, `KR` aeni.
    public var country: String?
    public var source: String?
    public var episodesMin: Int?
    public var episodesMax: Int?
    public var minimumScore: Int?
    /// Only titles the dub index found a dub for; AniList has no audio field, so this travels as
    /// the dub index's id list.
    public var dubbedOnly = false
    /// Titles by one studio, found through Browse's studio search or a show page's studio chip.
    public var studioID: Int?
    public var studioName: String?
    /// Leave out what the viewer has watched; answered from the device and sent as `id_not_in`.
    public var hideWatched: WatchedFilter = .off
    public var sort = "TRENDING_DESC"

    public init() {}

    /// Android's genre chip cycle: off → include → exclude → off.
    public mutating func cycleGenre(_ genre: String) {
        if excludedGenres.contains(genre) {
            excludedGenres.remove(genre)
        } else if genres.contains(genre) {
            genres.remove(genre)
            excludedGenres.insert(genre)
        } else {
            genres.insert(genre)
        }
    }

    /// The same cycle for tags.
    public mutating func cycleTag(_ tag: String) {
        if excludedTags.contains(tag) {
            excludedTags.remove(tag)
        } else if tags.contains(tag) {
            tags.remove(tag)
            excludedTags.insert(tag)
        } else {
            tags.insert(tag)
        }
    }

    /// How many filters are on, for the badge on the filter button. A span counts once.
    public var activeCount: Int {
        var count = genres.count + tags.count + excludedGenres.count + excludedTags.count
        for set in [year != nil, season != nil, yearFrom != nil || yearTo != nil, status != nil, format != nil,
                    country != nil, source != nil, episodesMin != nil || episodesMax != nil, minimumScore != nil, dubbedOnly,
                    studioID != nil, hideWatched != .off]
            where set { count += 1 }
        return count
    }

    public var isDefault: Bool { self == DiscoverFilters() }

    public static let sorts = [
        CatalogChoice("TRENDING_DESC", "Trending"),
        CatalogChoice("POPULARITY_DESC", "Most popular"),
        CatalogChoice("SCORE_DESC", "Highest rated"),
        CatalogChoice("FAVOURITES_DESC", "Most favorited"),
        CatalogChoice("START_DATE_DESC", "Newest"),
        CatalogChoice("START_DATE", "Oldest"),
        CatalogChoice("EPISODES_DESC", "Most episodes"),
        CatalogChoice("TITLE_ROMAJI", "A–Z"),
    ]

    public static let seasons = [
        CatalogChoice("WINTER", "Winter"), CatalogChoice("SPRING", "Spring"),
        CatalogChoice("SUMMER", "Summer"), CatalogChoice("FALL", "Fall"),
    ]

    public static let statuses = [
        CatalogChoice("RELEASING", "Ongoing"), CatalogChoice("FINISHED", "Completed"),
        CatalogChoice("NOT_YET_RELEASED", "Upcoming"), CatalogChoice("HIATUS", "On hiatus"),
        CatalogChoice("CANCELLED", "Cancelled"),
    ]

    public static let formats = [
        CatalogChoice("TV", "TV"), CatalogChoice("MOVIE", "Movie"), CatalogChoice("TV_SHORT", "TV short"),
        CatalogChoice("OVA", "OVA"), CatalogChoice("ONA", "ONA"), CatalogChoice("SPECIAL", "Special"),
        CatalogChoice("MUSIC", "Music"),
    ]

    public static let ratings = [60, 70, 80, 90]

    public static let countries = [
        CatalogChoice("JP", "Japan"), CatalogChoice("CN", "China"), CatalogChoice("KR", "South Korea"),
    ]

    public static let sources = [
        CatalogChoice("ORIGINAL", "Original"), CatalogChoice("MANGA", "Manga"),
        CatalogChoice("LIGHT_NOVEL", "Light novel"), CatalogChoice("NOVEL", "Novel"),
        CatalogChoice("VISUAL_NOVEL", "Visual novel"), CatalogChoice("VIDEO_GAME", "Game"),
        CatalogChoice("OTHER", "Other"),
    ]

    public static let episodeBuckets = [
        RangeChoice(label: "1–12", from: 1, to: 12),
        RangeChoice(label: "13–26", from: 13, to: 26),
        RangeChoice(label: "27–51", from: 27, to: 51),
        RangeChoice(label: "52+", from: 52, to: nil),
    ]

    /// Decades back from the current one, newest first, then everything older.
    public static func decades(now: Date = Date()) -> [RangeChoice] {
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        let current = year - year % 10
        var choices = (0..<5).map { step -> RangeChoice in
            let start = current - step * 10
            return RangeChoice(label: "\(start)s", from: start, to: start + 9)
        }
        choices.append(RangeChoice(label: "Earlier", from: nil, to: current - 41))
        return choices
    }
}

/// Browse's "hide watched" choice (Android's `WatchedFilter`).
public enum WatchedFilter: String, CaseIterable, Sendable, Identifiable {
    case off
    case completed
    case started

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .off: return "Show everything"
        case .completed: return "Hide completed"
        case .started: return "Hide anything I've watched"
        }
    }
    public var detail: String {
        switch self {
        case .off: return "Watched titles stay in the results"
        case .completed: return "Titles you finished, on your list or on this device"
        case .started: return "Also in progress, paused and dropped titles"
        }
    }
}

/// One AniList tag, for the Tags page of Browse's filters.
public struct MediaTagInfo: Decodable, Hashable, Sendable, Identifiable {
    public var name: String
    public var category: String?
    public var description: String?
    public var isAdult: Bool?
    public var id: String { name }
}

public struct StudioInfo: Decodable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
}

/// A page of Browse results.
public struct MediaPage: Sendable, Equatable {
    public var items: [Media]
    public var hasNextPage: Bool
    public var page: Int
    /// AniList's count of matches, or 0 when it didn't say.
    public var total: Int
}

extension AniListClient {
    /// Browse: every filter applied by AniList. `dubbedIDs` is the dub index, needed only when
    /// `filters.dubbedOnly` is set.
    public func discover(
        _ filters: DiscoverFilters,
        page: Int = 1,
        perPage: Int = 30,
        hideAdult: Bool = false,
        dubbedIDs: Set<Int> = [],
        studioIDs: Set<Int>? = nil,
        excludedIDs: Set<Int> = []
    ) async throws -> MediaPage {
        let ids = Self.mediaIDs(filters, dubbedIDs: dubbedIDs, studioIDs: studioIDs)
        if let ids, ids.isEmpty {
            // An id filter that resolved to nothing means nothing can match; sending no ids would
            // widen the search to the whole catalogue instead.
            return MediaPage(items: [], hasNextPage: false, page: page, total: 0)
        }
        let query = """
        query (
          $search: String, $page: Int, $perPage: Int, $genres: [String], $tags: [String],
          $excludedGenres: [String], $excludedTags: [String], $mediaIds: [Int], $excludedIds: [Int], $year: Int,
          $season: MediaSeason, $startedAfter: FuzzyDateInt, $startedBefore: FuzzyDateInt,
          $status: MediaStatus, $format: MediaFormat, $country: CountryCode, $source: MediaSource,
          $episodesMin: Int, $episodesMax: Int, $minimumScore: Int, $sort: [MediaSort], $isAdult: Boolean
        ) {
          Page(page: $page, perPage: $perPage) {
            pageInfo { hasNextPage currentPage total }
            media(
              search: $search, type: ANIME, genre_in: $genres, tag_in: $tags,
              genre_not_in: $excludedGenres, tag_not_in: $excludedTags, id_in: $mediaIds, id_not_in: $excludedIds,
              seasonYear: $year, season: $season, startDate_greater: $startedAfter,
              startDate_lesser: $startedBefore, status: $status, format: $format,
              countryOfOrigin: $country, source: $source, episodes_greater: $episodesMin,
              episodes_lesser: $episodesMax, averageScore_greater: $minimumScore, sort: $sort,
              isAdult: $isAdult
            ) { \(Self.mediaFields) }
          }
        }
        """
        struct PageInfo: Decodable { var hasNextPage: Bool?; var total: Int? }
        struct PageResult: Decodable { var pageInfo: PageInfo?; var media: [Media] }
        struct Payload: Decodable { var Page: PageResult }
        var variables = Self.discoverVariables(filters, page: page, perPage: perPage, hideAdult: hideAdult, dubbedIDs: dubbedIDs)
        if let ids { variables["mediaIds"] = .ints(ids.sorted()) }
        if !excludedIDs.isEmpty { variables["excludedIds"] = .ints(excludedIDs.sorted()) }
        let data: Payload = try await run(query, variables)
        return MediaPage(
            items: data.Page.media,
            hasNextPage: data.Page.pageInfo?.hasNextPage ?? false,
            page: page,
            total: data.Page.pageInfo?.total ?? 0
        )
    }

    /// The id list AniList is sent, or nil for none: the dub index and a studio's titles, the two
    /// filters AniList can only take as ids, intersected when both are set.
    static func mediaIDs(_ filters: DiscoverFilters, dubbedIDs: Set<Int>, studioIDs: Set<Int>?) -> Set<Int>? {
        var ids: Set<Int>?
        if filters.dubbedOnly { ids = dubbedIDs }
        if filters.studioID != nil, let studioIDs { ids = ids.map { $0.intersection(studioIDs) } ?? studioIDs }
        return ids
    }

    /// Every AniList tag, for the Tags filter page.
    public func tags() async throws -> [MediaTagInfo] {
        struct Payload: Decodable { var MediaTagCollection: [MediaTagInfo] }
        let data: Payload = try await run("query { MediaTagCollection { name category description isAdult } }", [:])
        return data.MediaTagCollection
    }

    /// Studios matching a name, for Browse's studio search.
    public func studios(matching search: String) async throws -> [StudioInfo] {
        let query = """
        query ($search: String) {
          Page(page: 1, perPage: 12) { studios(search: $search, sort: SEARCH_MATCH) { id name } }
        }
        """
        struct PageResult: Decodable { var studios: [StudioInfo] }
        struct Payload: Decodable { var Page: PageResult }
        let data: Payload = try await run(query, ["search": .string(search)])
        return data.Page.studios
    }

    /// A studio's anime ids for the studio filter, as Android's `mediaIdsForStudio` gets them:
    /// AniList has no studio argument on `Page.media`, so the studio's own connection is read once,
    /// twenty 25-item pages aliased into one request (AniList's 500-result ceiling), and the ids
    /// then go back through `id_in` so every other Browse filter stays server-side.
    public func studioMediaIDs(_ studioID: Int) async throws -> Set<Int> {
        let pages = (1...20).map { "p\($0): media(page: \($0), perPage: 25) { nodes { id } }" }.joined(separator: "\n")
        let query = """
        query ($studioId: Int) {
          Studio(id: $studioId) {
            \(pages)
          }
        }
        """
        let data: JSON = try await run(query, ["studioId": .int(studioID)])
        var ids = Set<Int>()
        for page in 1...20 {
            for node in data["Studio"]?["p\(page)"]?["nodes"]?.array ?? [] {
                if let id = node["id"]?.number { ids.insert(Int(id)) }
            }
        }
        return ids
    }

    /// Android's `discoverVariables`: AniList's `_greater`/`_lesser` bounds are exclusive, so the
    /// inclusive buckets are widened by one at each end.
    static func discoverVariables(_ filters: DiscoverFilters, page: Int, perPage: Int, hideAdult: Bool, dubbedIDs: Set<Int>) -> [String: Variable] {
        var variables: [String: Variable] = ["page": .int(page), "perPage": .int(perPage), "sort": .strings([filters.sort])]
        let search = filters.query.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty { variables["search"] = .string(search) }
        if hideAdult { variables["isAdult"] = .bool(false) }
        if !filters.genres.isEmpty { variables["genres"] = .strings(filters.genres.sorted()) }
        if !filters.tags.isEmpty { variables["tags"] = .strings(filters.tags.sorted()) }
        if !filters.excludedGenres.isEmpty { variables["excludedGenres"] = .strings(filters.excludedGenres.sorted()) }
        if !filters.excludedTags.isEmpty { variables["excludedTags"] = .strings(filters.excludedTags.sorted()) }
        if filters.dubbedOnly { variables["mediaIds"] = .ints(dubbedIDs.sorted()) }
        if let year = filters.year { variables["year"] = .int(year) }
        if let season = filters.season { variables["season"] = .string(season) }
        if let from = filters.yearFrom { variables["startedAfter"] = .int(from * 10_000) }
        if let to = filters.yearTo { variables["startedBefore"] = .int((to + 1) * 10_000) }
        if let status = filters.status { variables["status"] = .string(status) }
        if let format = filters.format { variables["format"] = .string(format) }
        if let country = filters.country { variables["country"] = .string(country) }
        if let source = filters.source { variables["source"] = .string(source) }
        if let minimum = filters.episodesMin { variables["episodesMin"] = .int(max(0, minimum - 1)) }
        if let maximum = filters.episodesMax { variables["episodesMax"] = .int(maximum + 1) }
        if let score = filters.minimumScore { variables["minimumScore"] = .int(max(0, score - 1)) }
        return variables
    }
}
