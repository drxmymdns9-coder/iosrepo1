import Foundation

/// The MyAnimeList v2 API for the signed-in account (Android's `MalClient`): profile, the anime
/// list, and list writes. All ids here are MAL ids; every call refreshes the token as needed.
public struct MALClient: Sendable {
    public static let shared = MALClient()

    static let api = "https://api.myanimelist.net/v2"
    /// Named in full: `tags` isn't a default field, and naming it alone could drop the rest.
    static let listStatusFields = "status,score,num_episodes_watched,is_rewatching,updated_at,tags"

    public init() {}

    public struct ListStatusData: Decodable, Equatable, Sendable {
        public var status: String?
        public var score: Int?
        public var num_episodes_watched: Int?
        public var is_rewatching: Bool?
        public var updated_at: String?
        public var tags: [String]?

        public var listStatus: ListStatus { ListStatus(mal: status, rewatching: is_rewatching ?? false) }
    }

    /// One row of the viewer's MAL list.
    public struct Entry: Equatable, Sendable {
        public var malID: Int
        public var title: String
        public var totalEpisodes: Int?
        public var status: ListStatus
        public var progress: Int
        public var score: Double
        public var updatedAt: Date
        public var tags: [String]
    }

    struct ListPage: Decodable {
        struct Node: Decodable { var id: Int; var title: String?; var num_episodes: Int? }
        struct Item: Decodable { var node: Node; var list_status: ListStatusData? }
        struct Paging: Decodable { var next: String? }
        var data: [Item]?
        var paging: Paging?
    }

    // MARK: - Reads

    public func viewer() async throws -> AccountProfile {
        struct User: Decodable {
            struct Stats: Decodable { var num_items: Int?; var num_days_watched: Double?; var mean_score: Double? }
            var id: Int
            var name: String
            var picture: String?
            var anime_statistics: Stats?
        }
        let user: User = try await get("\(Self.api)/users/@me?fields=anime_statistics")
        return AccountProfile(
            id: user.id, name: user.name, avatar: user.picture.flatMap(URL.init(string:)),
            animeCount: user.anime_statistics?.num_items ?? 0,
            minutesWatched: Int((user.anime_statistics?.num_days_watched ?? 0) * 1440),
            meanScore: user.anime_statistics?.mean_score ?? 0
        )
    }

    /// The whole list, 1000 to a page (MAL's maximum), at most five pages.
    public func animeList() async throws -> [Entry] {
        var url: String? = "\(Self.api)/users/@me/animelist?fields=list_status{\(Self.listStatusFields)},num_episodes&limit=1000&nsfw=true"
        var entries: [Entry] = []
        var pages = 0
        while let next = url, pages < 5 {
            let page: ListPage = try await get(next)
            entries += Self.entries(from: page)
            url = page.paging?.next
            pages += 1
        }
        return entries
    }

    /// The MAL list as AniList titles (joined by `idMal`); the odd title AniList doesn't know is
    /// dropped. MAL and AniList split seasons differently, so a count past this season's end is
    /// held at its finale (Android's `malAnimeList`).
    public func library(anilist: AniListClient = .shared) async throws -> AccountLibrary {
        let entries = try await animeList()
        let media = try await anilist.media(malIDs: entries.map(\.malID))
        let byMAL = Dictionary(media.compactMap { item in item.idMal.map { ($0, item) } }, uniquingKeysWith: { first, _ in first })
        let mapped = Self.join(entries, byMAL: byMAL)
        Log.info("account", "MyAnimeList list: \(entries.count) entries, \(mapped.count) matched on AniList")
        return AccountLibrary(entries: mapped)
    }

    static func join(_ entries: [Entry], byMAL: [Int: Media]) -> [ListEntry] {
        entries.compactMap { entry in
            guard var media = byMAL[entry.malID] else { return nil }
            let total = media.episodes ?? entry.totalEpisodes
            if media.episodes == nil { media.episodes = total }
            return ListEntry(entryID: entry.malID, media: media, status: entry.status,
                             progress: ListSync.clampProgress(entry.progress, totalEpisodes: total),
                             score: entry.score, updatedAt: entry.updatedAt, customLists: entry.tags)
        }
    }

    static func entries(from page: ListPage) -> [Entry] {
        (page.data ?? []).compactMap { item in
            guard let list = item.list_status else { return nil }
            return Entry(
                malID: item.node.id, title: item.node.title ?? "",
                totalEpisodes: item.node.num_episodes.flatMap { $0 > 0 ? $0 : nil },
                status: list.listStatus, progress: list.num_episodes_watched ?? 0, score: Double(list.score ?? 0),
                updatedAt: Self.date(list.updated_at) ?? Date(timeIntervalSince1970: 0), tags: list.tags ?? []
            )
        }
    }

    /// The viewer's entry for one anime and MAL's own episode count (an airing series often has 0).
    public func animeStatus(malID: Int) async throws -> (entry: ListStatusData?, totalEpisodes: Int?) {
        struct Anime: Decodable { var num_episodes: Int?; var my_list_status: ListStatusData? }
        let anime: Anime = try await get("\(Self.api)/anime/\(malID)?fields=my_list_status{\(Self.listStatusFields)},num_episodes")
        let entry = anime.my_list_status?.status == nil ? nil : anime.my_list_status
        return (entry, anime.num_episodes.flatMap { $0 > 0 ? $0 : nil })
    }

    // MARK: - Writes

    /// Upserts progress, status (MAL's words) and score (0 removes it); nil leaves a field alone.
    /// `tags` replaces the whole set. MAL's confirmation is checked, since it quietly refuses
    /// impossible counts.
    @discardableResult
    public func update(malID: Int, progress: Int? = nil, status: String? = nil, rewatching: Bool? = nil, score: Int? = nil, tags: [String]? = nil) async throws -> ListStatusData {
        if let score, !(0...10).contains(score) { throw HTTPError("A MyAnimeList score is 0 to 10, not \(score)") }
        var form: [String: String] = [:]
        if let progress { form["num_watched_episodes"] = String(progress) }
        if let status { form["status"] = status }
        if let rewatching { form["is_rewatching"] = String(rewatching) }
        if let score { form["score"] = String(score) }
        if let tags { form["tags"] = tags.joined(separator: ",") }
        let confirmed: ListStatusData = try await send("\(Self.api)/anime/\(malID)/my_list_status", method: "PATCH", form: form)
        if let progress, confirmed.num_episodes_watched != progress {
            throw HTTPError("MyAnimeList confirmed \(confirmed.num_episodes_watched ?? 0) watched episodes after being sent \(progress)")
        }
        if let status, confirmed.status != status {
            throw HTTPError("MyAnimeList confirmed status \(confirmed.status ?? "missing") after being sent \(status)")
        }
        if let score, (confirmed.score ?? 0) != score {
            throw HTTPError("MyAnimeList confirmed score \(confirmed.score.map(String.init) ?? "missing") after being sent \(score)")
        }
        return confirmed
    }

    public func delete(malID: Int) async throws {
        _ = try await request("\(Self.api)/anime/\(malID)/my_list_status", method: "DELETE", form: nil)
    }

    /// Progress from a finished episode under the same rules as AniList's.
    @discardableResult
    public func syncProgress(malID: Int, watched: Int) async throws -> ProgressUpdate? {
        let current = try await animeStatus(malID: malID)
        let total = current.totalEpisodes
        let watched = ListSync.clampProgress(watched, totalEpisodes: total)
        guard let plan = ListSync.planProgress(current: current.entry.map { ($0.listStatus, $0.num_episodes_watched ?? 0) },
                                               watched: watched, totalEpisodes: total) else { return nil }
        try await update(malID: malID, progress: plan.progress, status: plan.status?.malValue)
        return plan
    }

    /// The Save button on MAL: a save adds Plan to Watch; an unsave removes only a plan.
    public func syncSaved(malID: Int, saved: Bool) async throws {
        let current = try await animeStatus(malID: malID).entry
        if saved, current == nil {
            try await update(malID: malID, status: "plan_to_watch")
        } else if !saved, current?.status == "plan_to_watch" {
            try await delete(malID: malID)
        }
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ url: String) async throws -> T {
        try await send(url, method: "GET", form: nil)
    }

    private func send<T: Decodable>(_ address: String, method: String, form: [String: String]?) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request(address, method: method, form: form))
    }

    private func request(_ address: String, method: String, form: [String: String]?) async throws -> Data {
        guard let url = URL(string: address) else { throw HTTPError("Bad MyAnimeList URL") }
        let token = try await AccountCredentials.shared.malAccessToken()
        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        var body: Data?
        if let form {
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            body = Data(FormEncoding.encode(form).utf8)
        }
        let (data, response) = try await HTTP.data(url, method: method, headers: headers, body: body)
        if response.statusCode == 401 { throw AccountError.sessionExpired(.mal) }
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError(status: response.statusCode, "MyAnimeList answered HTTP \(response.statusCode)")
        }
        return data
    }

    /// MAL stamps times with a numeric offset (`2018-04-25T22:23:11+00:00`).
    static func date(_ text: String?) -> Date? {
        guard let text = text?.nonBlank else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
