import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The AniList GraphQL catalogue, asking for what the Android app's `AniListClient` asks for.
///
/// AniList allows 90 requests a minute normally and drops to 30 when degraded; a 429 is a one-minute
/// timeout. Nothing here retries on its own, so a burst can't dig the hole deeper.
public struct AniListClient: Sendable {
    /// Home's catalogue rows, fetched in one operation so a cold start is one request.
    public struct HomeCollections: Sendable, Equatable {
        /// Trending, which the spotlight carousel is drawn from (and the Trending row).
        public var spotlight: [Media]
        /// Recently aired, newest first, one entry per show.
        public var newest: [Media]
        /// Popular in the current season.
        public var popular: [Media]
        public var movies: [Media]
        public var topRated: [Media]
        public var upcoming: [Media]
    }

    public static let shared = AniListClient()

    private let endpoint = URL(string: "https://graphql.anilist.co")!

    public init() {}

    /// Android's `mediaListFields`: what a card or a rail needs.
    static let mediaFields = """
    id
    idMal
    title { romaji english native userPreferred }
    coverImage { large extraLarge color }
    bannerImage
    trailer { thumbnail }
    format
    season
    seasonYear
    episodes
    duration
    status
    averageScore
    popularity
    isAdult
    countryOfOrigin
    genres
    studios(isMain: true) { nodes { id name isAnimationStudio } }
    nextAiringEpisode { episode airingAt timeUntilAiring }
    startDate { year month day }
    """

    /// Home's cinematic hero needs a synopsis; rails stay on the compact set.
    static let spotlightFields = mediaFields + "\ndescription(asHtml: false)"

    /// Android's `mediaFullFields`: the show page.
    static let fullFields = """
    id
    idMal
    title { romaji english native userPreferred }
    description(asHtml: false)
    coverImage { large extraLarge color }
    bannerImage
    format
    season
    seasonYear
    episodes
    duration
    status
    averageScore
    meanScore
    popularity
    favourites
    isAdult
    countryOfOrigin
    genres
    tags { name rank isMediaSpoiler isGeneralSpoiler }
    studios { nodes { id name isAnimationStudio } }
    trailer { id site thumbnail }
    nextAiringEpisode { episode airingAt timeUntilAiring }
    startDate { year month day }
    endDate { year month day }
    streamingEpisodes { title thumbnail url site }
    relations {
      edges {
        relationType
        node { \(mediaFields) }
      }
    }
    """

    /// airingAt is the broadcast start; allow ~25 min runtime plus an hour for streaming sites to
    /// pick the episode up, so every New Episodes entry is actually watchable.
    static let newestAiredBuffer: TimeInterval = 90 * 60

    public func homeCollections(hideAdult: Bool = false, now: Date = Date()) async throws -> HomeCollections {
        let (season, year) = Self.season(containing: now)
        let query = """
        query ($isAdult: Boolean, $airedBefore: Int, $season: MediaSeason, $seasonYear: Int) {
          spotlight: Page(page: 1, perPage: 30) {
            media(type: ANIME, sort: [TRENDING_DESC], isAdult: $isAdult) { \(Self.spotlightFields) }
          }
          newest: Page(page: 1, perPage: 50) {
            airingSchedules(airingAt_lesser: $airedBefore, sort: TIME_DESC) {
              media { \(Self.mediaFields) }
            }
          }
          popular: Page(page: 1, perPage: 30) {
            media(type: ANIME, season: $season, seasonYear: $seasonYear, sort: [POPULARITY_DESC], isAdult: $isAdult) { \(Self.mediaFields) }
          }
          movies: Page(page: 1, perPage: 30) {
            media(type: ANIME, format: MOVIE, sort: [POPULARITY_DESC], isAdult: $isAdult) { \(Self.mediaFields) }
          }
          topRated: Page(page: 1, perPage: 30) {
            media(type: ANIME, sort: [SCORE_DESC], isAdult: $isAdult) { \(Self.mediaFields) }
          }
          upcoming: Page(page: 1, perPage: 30) {
            media(type: ANIME, status: NOT_YET_RELEASED, sort: [POPULARITY_DESC], isAdult: $isAdult) { \(Self.mediaFields) }
          }
        }
        """
        struct Schedule: Decodable { var media: Media? }
        struct SchedulePage: Decodable { var airingSchedules: [Schedule] }
        struct Payload: Decodable {
            var spotlight: PageBox
            var newest: SchedulePage
            var popular: PageBox
            var movies: PageBox
            var topRated: PageBox
            var upcoming: PageBox
        }
        var variables: [String: Variable] = [
            "season": .string(season),
            "seasonYear": .int(year),
            "airedBefore": .int(Int(now.timeIntervalSince1970 - Self.newestAiredBuffer)),
        ]
        if hideAdult { variables["isAdult"] = .bool(false) }
        let data: Payload = try await run(query, variables)
        // A show airing several times in the window appears once; isAdult can't be filtered
        // inside airingSchedules.
        var seen = Set<Int>()
        let newest = data.newest.airingSchedules.compactMap(\.media).filter {
            seen.insert($0.id).inserted && !(hideAdult && $0.isAdult == true)
        }
        return HomeCollections(
            spotlight: data.spotlight.media,
            newest: newest,
            popular: data.popular.media,
            movies: data.movies.media,
            topRated: data.topRated.media,
            upcoming: data.upcoming.media
        )
    }

    /// AniList search matches whole words only: "narut" finds nothing while "naruto" does.
    public func search(_ text: String, page: Int = 1, perPage: Int = 30, hideAdult: Bool = false) async throws -> [Media] {
        let query = """
        query ($search: String, $page: Int, $perPage: Int, $isAdult: Boolean) {
          Page(page: $page, perPage: $perPage) {
            media(search: $search, type: ANIME, sort: SEARCH_MATCH, isAdult: $isAdult) { \(Self.mediaFields) }
          }
        }
        """
        struct Payload: Decodable { var Page: PageBox }
        var variables: [String: Variable] = ["search": .string(text), "page": .int(page), "perPage": .int(perPage)]
        if hideAdult { variables["isAdult"] = .bool(false) }
        let data: Payload = try await run(query, variables)
        return data.Page.media
    }

    public func media(id: Int) async throws -> Media {
        let query = """
        query ($id: Int) {
          Media(id: $id, type: ANIME) { \(Self.fullFields) }
        }
        """
        struct Payload: Decodable { var Media: AnililiCore.Media }
        let data: Payload = try await run(query, ["id": .int(id)])
        return data.Media
    }

    /// AniList's community recommendations for a title, best rated first.
    public func recommendations(id: Int) async throws -> [Media] {
        let query = """
        query ($id: Int) {
          Media(id: $id, type: ANIME) {
            recommendations(sort: [RATING_DESC], perPage: 24) {
              nodes { rating mediaRecommendation { \(Self.mediaFields) } }
            }
          }
        }
        """
        struct Node: Decodable { var rating: Int?; var mediaRecommendation: AnililiCore.Media? }
        struct Connection: Decodable { var nodes: [Node] }
        struct Recommended: Decodable { var recommendations: Connection? }
        struct Payload: Decodable { var Media: Recommended? }
        let data: Payload = try await run(query, ["id": .int(id)])
        return data.Media?.recommendations?.nodes.compactMap(\.mediaRecommendation) ?? []
    }

    /// AniList's genre list, for the genre chips and filters.
    public func genres() async throws -> [String] {
        struct Payload: Decodable { var GenreCollection: [String] }
        let data: Payload = try await run("query { GenreCollection }", [:])
        return data.GenreCollection
    }

    public struct AiringSlot: Decodable, Identifiable, Hashable, Sendable {
        public var episode: Int
        public var airingAt: Int
        public var media: Media

        public var id: String { "\(media.id)-\(episode)" }
        public var date: Date { Date(timeIntervalSince1970: TimeInterval(airingAt)) }
    }

    /// Everything airing in `interval`, earliest first, adult titles left out. Pages through
    /// AniList's 50-per-page cap; a week is three or four pages.
    public func schedule(_ interval: DateInterval) async throws -> [AiringSlot] {
        let query = """
        query ($start: Int, $end: Int, $page: Int) {
          Page(page: $page, perPage: 50) {
            pageInfo { hasNextPage }
            airingSchedules(airingAt_greater: $start, airingAt_lesser: $end, sort: TIME) {
              episode airingAt media { \(Self.mediaFields) }
            }
          }
        }
        """
        struct Row: Decodable { var episode: Int; var airingAt: Int; var media: Media? }
        struct PageInfo: Decodable { var hasNextPage: Bool? }
        struct SchedulePage: Decodable { var pageInfo: PageInfo?; var airingSchedules: [Row] }
        struct Payload: Decodable { var Page: SchedulePage }

        var slots: [AiringSlot] = []
        for page in 1...8 {
            let data: Payload = try await run(query, [
                "start": .int(Int(interval.start.timeIntervalSince1970) - 1),
                "end": .int(Int(interval.end.timeIntervalSince1970)),
                "page": .int(page),
            ])
            slots += data.Page.airingSchedules.compactMap { row in
                guard let media = row.media, media.isAdult != true else { return nil }
                return AiringSlot(episode: row.episode, airingAt: row.airingAt, media: media)
            }
            if data.Page.pageInfo?.hasNextPage != true { break }
        }
        return slots
    }

    // MARK: - Transport

    struct PageBox: Decodable { var media: [Media] }

    enum Variable: Encodable, Sendable {
        case int(Int)
        case string(String)
        case bool(Bool)
        case strings([String])
        case ints([Int])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .int(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .strings(let value): try container.encode(value)
            case .ints(let value): try container.encode(value)
            }
        }
    }

    private struct Request: Encodable {
        var query: String
        var variables: [String: Variable]
    }

    private struct Response<D: Decodable>: Decodable {
        struct Problem: Decodable { var message: String; var status: Int? }
        var data: D?
        var errors: [Problem]?
    }

    /// What the request says it is. AniList refuses requests with no Referer at all (Android
    /// measured it: any value passes), so this names the app honestly.
    /// Posted when AniList refuses the stored token, so the app can sign out.
    public static let sessionExpired = Notification.Name("AniListSessionExpired")

    static let identity = [
        "Referer": "ios-app://com.anilili.ios",
        "User-Agent": "Anilili iOS (AniList client \(AniListAuth.clientID))",
    ]

    func run<D: Decodable>(_ query: String, _ variables: [String: Variable], authenticated: Bool = false, anonymous: Bool = false) async throws -> D {
        let body = try JSONEncoder().encode(Request(query: query, variables: variables))
        var headers = ["Content-Type": "application/json", "Accept": "application/json"].merging(Self.identity) { first, _ in first }
        let token = anonymous ? nil : AccountCredentials.shared.anilistToken
        if authenticated && token == nil { throw AccountError.signInRequired }
        if let token { headers["Authorization"] = "Bearer \(token)" }
        let (data, response) = try await HTTP.data(endpoint, method: "POST", headers: headers, body: body)
        if response.statusCode == 401, token != nil {
            Log.warning("anilist", "401: the sign-in expired or was revoked")
            NotificationCenter.default.post(name: AniListClient.sessionExpired, object: nil)
            // The catalogue doesn't need the account: ask again without it.
            if !authenticated { return try await run(query, variables, anonymous: true) }
            throw AccountError.sessionExpired(.anilist)
        }
        if response.statusCode == 429 {
            Log.warning("anilist", "rate limited (429)")
            throw HTTPError(status: 429, "AniList is rate-limiting this device. Try again in a minute.")
        }
        let decoded: Response<D>
        do {
            decoded = try JSONDecoder().decode(Response<D>.self, from: data)
        } catch {
            Log.error("anilist", "HTTP \(response.statusCode), body didn't decode as \(D.self): \(error)")
            throw HTTPError(status: response.statusCode, "AniList answered HTTP \(response.statusCode) with an unreadable body")
        }
        if let payload = decoded.data { return payload }
        let message = decoded.errors?.first?.message ?? "AniList returned no data"
        Log.error("anilist", "query failed: \(decoded.errors?.map(\.message).joined(separator: "; ") ?? message)")
        throw HTTPError(status: response.statusCode, message)
    }

    /// The season a date falls in, by AniList's calendar quarters, as the Android app reckons it
    /// (`AiringSeason.of`): January to March is winter of the same year.
    public static func season(containing date: Date) -> (season: String, year: Int) {
        let calendar = Calendar(identifier: .gregorian)
        let month = calendar.component(.month, from: date)
        let year = calendar.component(.year, from: date)
        switch month {
        case 1...3: return ("WINTER", year)
        case 4...6: return ("SPRING", year)
        case 7...9: return ("SUMMER", year)
        default: return ("FALL", year)
        }
    }
}
