import Foundation

/// The signed-in viewer, from either service.
public struct AccountProfile: Codable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var avatar: URL?
    public var banner: URL?
    public var animeCount: Int
    public var episodesWatched: Int
    public var minutesWatched: Int
    public var meanScore: Double

    public init(id: Int, name: String, avatar: URL? = nil, banner: URL? = nil, animeCount: Int = 0,
                episodesWatched: Int = 0, minutesWatched: Int = 0, meanScore: Double = 0) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.banner = banner
        self.animeCount = animeCount
        self.episodesWatched = episodesWatched
        self.minutesWatched = minutesWatched
        self.meanScore = meanScore
    }
}

/// One AniList notification (Android's `AppNotification`).
public struct AccountNotification: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case airing, media, social }

    public var id: Int
    public var kind: Kind
    public var createdAt: Date
    public var title: String
    public var badge: String?
    public var detail: String?
    public var episode: Int?
    public var mediaID: Int?
    public var image: URL?
    public var unread: Bool
}

/// Custom list names, which AniList sends as strings, `{name, enabled}` objects or a
/// `{name: enabled}` map depending on the field (Android's `CustomListNamesSerializer`).
struct CustomListNames: Decodable, Sendable {
    var names: [String]

    private struct Named: Decodable {
        var name: String?
        var enabled: Bool?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let strings = try? container.decode([String].self) {
            names = strings
        } else if let objects = try? container.decode([Named].self) {
            names = objects.compactMap { $0.enabled == true ? $0.name : nil }
        } else if let map = try? container.decode([String: Bool].self) {
            names = map.filter(\.value).map(\.key).sorted()
        } else {
            names = []
        }
        names = names.filter { $0.nonBlank != nil }
    }
}

extension AniListClient {
    // MARK: - Viewer

    private struct ViewerData: Decodable {
        struct ViewerNode: Decodable {
            struct Avatar: Decodable { var large: String? }
            struct Statistics: Decodable {
                struct Anime: Decodable {
                    var count: Int?
                    var episodesWatched: Int?
                    var minutesWatched: Int?
                    var meanScore: Double?
                }
                var anime: Anime?
            }
            var id: Int
            var name: String
            var avatar: Avatar?
            var bannerImage: String?
            var statistics: Statistics?
        }
        var Viewer: ViewerNode?
    }

    public func viewer() async throws -> AccountProfile {
        let query = """
        query {
          Viewer {
            id name avatar { large } bannerImage
            statistics { anime { count episodesWatched minutesWatched meanScore } }
          }
        }
        """
        let data: ViewerData = try await run(query, [:], authenticated: true)
        guard let viewer = data.Viewer else { throw HTTPError("AniList didn't say who is signed in") }
        let anime = viewer.statistics?.anime
        return AccountProfile(
            id: viewer.id, name: viewer.name,
            avatar: viewer.avatar?.large.flatMap(URL.init(string:)),
            banner: viewer.bannerImage.flatMap(URL.init(string:)),
            animeCount: anime?.count ?? 0, episodesWatched: anime?.episodesWatched ?? 0,
            minutesWatched: anime?.minutesWatched ?? 0, meanScore: anime?.meanScore ?? 0
        )
    }

    // MARK: - Activity

    private struct ActivityData: Decodable {
        struct UserNode: Decodable {
            struct Stats: Decodable {
                struct Day: Decodable { var date: Int?; var amount: Int? }
                var activityHistory: [Day]?
            }
            var stats: Stats?
        }
        var User: UserNode?
    }

    /// The account's own activity per day (epoch day → amount), for the activity grid. `User.stats`
    /// is deprecated but `statistics` has no daily history, so this is the only source (Android's
    /// `activityHistory`).
    public func activityHistory(userID: Int) async throws -> [Int: Int] {
        let query = "query ($id: Int) { User(id: $id) { stats { activityHistory { date amount } } } }"
        let data: ActivityData = try await run(query, ["id": .int(userID)], authenticated: true)
        return Self.activityDays(data.User?.stats?.activityHistory?.map { ($0.date, $0.amount) } ?? [])
    }

    /// Unix seconds (UTC midnight) to epoch days; empty days dropped.
    static func activityDays(_ rows: [(Int?, Int?)]) -> [Int: Int] {
        var days: [Int: Int] = [:]
        for case let (date?, amount?) in rows where amount > 0 { days[date / 86_400] = amount }
        return days
    }

    // MARK: - Lists

    struct ListEntryData: Decodable {
        var id: Int
        var updatedAt: Int?
        var progress: Int?
        var score: Double?
        var status: String?
        var hiddenFromStatusLists: Bool?
        var customLists: CustomListNames?
        var media: Media?

        var entry: ListEntry? {
            guard let media, let status = status.flatMap(ListStatus.init(rawValue:)) else { return nil }
            return ListEntry(entryID: id, media: media, status: status, progress: progress ?? 0, score: score ?? 0,
                             updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt ?? 0)),
                             hiddenFromStatusLists: hiddenFromStatusLists ?? false, customLists: customLists?.names ?? [])
        }
    }

    struct CollectionData: Decodable {
        struct Collection: Decodable {
            struct User: Decodable {
                struct Options: Decodable {
                    struct AnimeList: Decodable { var customLists: CustomListNames? }
                    var animeList: AnimeList?
                }
                var mediaListOptions: Options?
            }
            struct Group: Decodable { var entries: [ListEntryData]? }
            var user: User?
            var lists: [Group]?
        }
        var MediaListCollection: Collection?
    }

    /// The viewer's anime lists with progress and custom lists, plus every custom list name.
    public func animeList(userID: Int) async throws -> AccountLibrary {
        let query = """
        query ($userId: Int) {
          MediaListCollection(userId: $userId, type: ANIME, status_in: [CURRENT, REPEATING, PLANNING, PAUSED, COMPLETED, DROPPED]) {
            user { mediaListOptions { animeList { customLists } } }
            lists {
              entries {
                id updatedAt progress score(format: POINT_10_DECIMAL) status
                hiddenFromStatusLists customLists(asArray: true)
                media { \(Self.mediaFields) }
              }
            }
          }
        }
        """
        let data: CollectionData = try await run(query, ["userId": .int(userID)], authenticated: true)
        guard let collection = data.MediaListCollection else { throw HTTPError("AniList returned no list for this account") }
        return Self.library(from: collection)
    }

    static func library(from collection: CollectionData.Collection) -> AccountLibrary {
        // An entry in several custom lists appears once per list; keep the first.
        var seen = Set<Int>()
        let entries = (collection.lists ?? []).flatMap { $0.entries ?? [] }
            .filter { seen.insert($0.id).inserted }
            .compactMap(\.entry)
        return AccountLibrary(entries: entries,
                              customListNames: collection.user?.mediaListOptions?.animeList?.customLists?.names ?? [])
    }

    private struct EntryLookup: Decodable {
        struct MediaNode: Decodable { var mediaListEntry: ListEntryData? }
        var Media: MediaNode?
    }

    /// The viewer's entry for one title (status, progress, custom lists), nil when it isn't listed.
    public func listEntry(mediaID: Int) async throws -> (entryID: Int, status: ListStatus, progress: Int, hidden: Bool, customLists: [String])? {
        let query = """
        query ($mediaId: Int) {
          Media(id: $mediaId, type: ANIME) { mediaListEntry { id status progress hiddenFromStatusLists customLists(asArray: true) } }
        }
        """
        let data: EntryLookup = try await run(query, ["mediaId": .int(mediaID)], authenticated: true)
        guard let entry = data.Media?.mediaListEntry, let status = entry.status.flatMap(ListStatus.init(rawValue:)) else { return nil }
        return (entry.id, status, entry.progress ?? 0, entry.hiddenFromStatusLists ?? false, entry.customLists?.names ?? [])
    }

    private struct Saved: Decodable {}

    /// Progress from a finished episode, under Android's rules (`syncMediaListProgress`). Returns
    /// what was written, nil when the entry shouldn't change.
    @discardableResult
    public func syncProgress(mediaID: Int, watched: Int, totalEpisodes: Int?) async throws -> ProgressUpdate? {
        let current = try await listEntry(mediaID: mediaID)
        guard let update = ListSync.planProgress(current: current.map { ($0.status, $0.progress) }, watched: watched, totalEpisodes: totalEpisodes) else {
            return nil
        }
        // A status change brings a title filed in custom lists only onto Watching.
        let query = update.status == nil
            ? "mutation ($mediaId: Int, $progress: Int) { SaveMediaListEntry(mediaId: $mediaId, progress: $progress) { id } }"
            : "mutation ($mediaId: Int, $progress: Int, $status: MediaListStatus) { SaveMediaListEntry(mediaId: $mediaId, progress: $progress, status: $status, hiddenFromStatusLists: false) { id } }"
        var variables: [String: Variable] = ["mediaId": .int(mediaID), "progress": .int(update.progress)]
        if let status = update.status { variables["status"] = .string(status.rawValue) }
        let _: Saved = try await run(query, variables, authenticated: true)
        return update
    }

    /// Moves a title to another list, keeping progress and score; out of custom-lists-only too.
    public func setStatus(mediaID: Int, _ status: ListStatus) async throws {
        let query = "mutation ($mediaId: Int, $status: MediaListStatus) { SaveMediaListEntry(mediaId: $mediaId, status: $status, hiddenFromStatusLists: false) { id } }"
        let _: Saved = try await run(query, ["mediaId": .int(mediaID), "status": .string(status.rawValue)], authenticated: true)
    }

    /// Every episode watched in one write; a title without a known count gets the status alone.
    public func setCompleted(mediaID: Int, totalEpisodes: Int?) async throws {
        var variables: [String: Variable] = ["mediaId": .int(mediaID), "status": .string(ListStatus.completed.rawValue)]
        let query: String
        if let total = totalEpisodes {
            variables["progress"] = .int(total)
            query = "mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int) { SaveMediaListEntry(mediaId: $mediaId, status: $status, hiddenFromStatusLists: false, progress: $progress) { id } }"
        } else {
            query = "mutation ($mediaId: Int, $status: MediaListStatus) { SaveMediaListEntry(mediaId: $mediaId, status: $status, hiddenFromStatusLists: false) { id } }"
        }
        let _: Saved = try await run(query, variables, authenticated: true)
    }

    struct ScoreSaved: Decodable {
        struct Entry: Decodable { var score: Double? }
        var SaveMediaListEntry: Entry?
    }

    /// The viewer's score, 1–10 or 0 to remove it (Android's `updateMediaListScore`). Offered only
    /// for a listed title, since AniList would otherwise make an entry to hold it. AniList's
    /// confirmation is checked against what was sent.
    public func setScore(mediaID: Int, _ score: Int) async throws {
        guard (0...10).contains(score) else { throw HTTPError("A list score is 0 to 10, not \(score)") }
        let query = "mutation ($mediaId: Int, $scoreRaw: Int) { SaveMediaListEntry(mediaId: $mediaId, scoreRaw: $scoreRaw) { id score(format: POINT_10_DECIMAL) } }"
        let data: ScoreSaved = try await run(query, ["mediaId": .int(mediaID), "scoreRaw": .int(ListScore.aniListRaw(score))], authenticated: true)
        try Self.checkScore(data, requested: score)
    }

    static func checkScore(_ data: ScoreSaved, requested: Int) throws {
        guard let confirmed = data.SaveMediaListEntry?.score, abs(confirmed - Double(requested)) < 0.05 else {
            throw HTTPError("AniList confirmed score \(data.SaveMediaListEntry?.score.map(ListScore.format) ?? "missing") after being sent \(requested)")
        }
    }

    private struct Deleted: Decodable {
        struct Result: Decodable { var deleted: Bool? }
        var DeleteMediaListEntry: Result?
    }

    /// Takes the entry off the list with its progress and score. False when there was none.
    @discardableResult
    public func deleteEntry(mediaID: Int) async throws -> Bool {
        guard let current = try await listEntry(mediaID: mediaID) else { return false }
        let data: Deleted = try await run("mutation ($id: Int) { DeleteMediaListEntry(id: $id) { deleted } }",
                                          ["id": .int(current.entryID)], authenticated: true)
        return data.DeleteMediaListEntry?.deleted ?? false
    }

    /// Mirrors the device's Save button without hurting an entry that's more than a plan
    /// (`syncSavedAnime`): a save becomes Planning; an unsave removes only a Planning entry, and
    /// one that's also in a custom list is tucked into its lists instead of deleted.
    public func syncSaved(mediaID: Int, saved: Bool) async throws {
        let current = try await listEntry(mediaID: mediaID)
        let hide = "mutation ($mediaId: Int, $hidden: Boolean) { SaveMediaListEntry(mediaId: $mediaId, hiddenFromStatusLists: $hidden) { id } }"
        switch (saved, current) {
        case (true, nil):
            let _: Saved = try await run("mutation ($mediaId: Int) { SaveMediaListEntry(mediaId: $mediaId, status: PLANNING) { id } }",
                                         ["mediaId": .int(mediaID)], authenticated: true)
        case (true, let entry?) where entry.status == .planning && entry.hidden:
            let _: Saved = try await run(hide, ["mediaId": .int(mediaID), "hidden": .bool(false)], authenticated: true)
        case (false, let entry?) where entry.status == .planning && !entry.hidden && !entry.customLists.isEmpty:
            let _: Saved = try await run(hide, ["mediaId": .int(mediaID), "hidden": .bool(true)], authenticated: true)
        case (false, let entry?) where entry.status == .planning && entry.customLists.isEmpty:
            let _: Deleted = try await run("mutation ($id: Int) { DeleteMediaListEntry(id: $id) { deleted } }",
                                           ["id": .int(entry.entryID)], authenticated: true)
        default:
            break
        }
    }

    // MARK: - Custom lists

    /// Makes the account's custom lists exactly `names`. AniList has no create or rename: the
    /// names are one field written whole, and a dropped name leaves every entry that was in it.
    @discardableResult
    public func setCustomListNames(_ names: [String]) async throws -> [String] {
        struct Updated: Decodable {
            struct User: Decodable {
                struct Options: Decodable {
                    struct AnimeList: Decodable { var customLists: CustomListNames? }
                    var animeList: AnimeList?
                }
                var mediaListOptions: Options?
            }
            var UpdateUser: User?
        }
        let query = "mutation ($names: [String]) { UpdateUser(animeListOptions: { customLists: $names }) { mediaListOptions { animeList { customLists } } } }"
        let data: Updated = try await run(query, ["names": .strings(names)], authenticated: true)
        return data.UpdateUser?.mediaListOptions?.animeList?.customLists?.names ?? names
    }

    /// Which custom lists a title is in. A title with no entry is created as Planning hidden from
    /// the status lists: the viewer filed it, they didn't plan it.
    public func setCustomLists(mediaID: Int, lists: [String], create: Bool) async throws {
        let extra = create ? ", status: PLANNING, hiddenFromStatusLists: true" : ""
        let query = "mutation ($mediaId: Int, $lists: [String]) { SaveMediaListEntry(mediaId: $mediaId, customLists: $lists\(extra)) { id } }"
        let _: Saved = try await run(query, ["mediaId": .int(mediaID), "lists": .strings(lists)], authenticated: true)
    }

    // MARK: - Favourites

    private struct FavouritesData: Decodable {
        struct ViewerNode: Decodable {
            struct Favourites: Decodable {
                struct Connection: Decodable {
                    struct PageInfo: Decodable { var hasNextPage: Bool? }
                    var pageInfo: PageInfo?
                    var nodes: [Media]?
                }
                var anime: Connection?
            }
            var favourites: Favourites?
        }
        var Viewer: ViewerNode?
    }

    public func favouriteAnime(maxPages: Int = 8) async throws -> [Media] {
        let query = """
        query ($page: Int) {
          Viewer { favourites { anime(page: $page, perPage: 25) { pageInfo { hasNextPage } nodes { \(Self.mediaFields) } } } }
        }
        """
        var all: [Media] = []
        var page = 1
        while page <= maxPages {
            let data: FavouritesData = try await run(query, ["page": .int(page)], authenticated: true)
            guard let connection = data.Viewer?.favourites?.anime else { break }
            all += connection.nodes ?? []
            guard connection.pageInfo?.hasNextPage == true else { break }
            page += 1
        }
        var seen = Set<Int>()
        return all.filter { seen.insert($0.id).inserted }
    }

    // MARK: - MyAnimeList ids

    private struct PageData: Decodable {
        struct PageNode: Decodable { var media: [Media]? }
        var Page: PageNode?
    }

    /// AniList titles for MAL ids, 50 to a request; ids AniList doesn't know are simply absent.
    public func media(malIDs: [Int]) async throws -> [Media] {
        let query = "query ($ids: [Int]) { Page(page: 1, perPage: 50) { media(type: ANIME, idMal_in: $ids) { \(Self.mediaFields) } } }"
        var found: [Media] = []
        let ids = Array(Set(malIDs)).sorted()
        for start in stride(from: 0, to: ids.count, by: 50) {
            let chunk = Array(ids[start..<min(start + 50, ids.count)])
            let data: PageData = try await run(query, ["ids": .ints(chunk)])
            found += data.Page?.media ?? []
        }
        return found
    }

    // MARK: - Notifications

    /// The viewer's notification feed, newest first, and how many are unread. AniList has no
    /// per-item read flag: the first `unread` are the unread ones.
    public func notifications() async throws -> (items: [AccountNotification], unread: Int) {
        let media = "media { id title { romaji english userPreferred } coverImage { large } bannerImage }"
        let user = "user { id name avatar { large } }"
        let query = """
        query {
          Viewer { unreadNotificationCount }
          Page(page: 1, perPage: 50) {
            notifications(resetNotificationCount: false) {
              __typename
              ... on AiringNotification { id createdAt episode \(media) }
              ... on RelatedMediaAdditionNotification { id createdAt context \(media) }
              ... on MediaDataChangeNotification { id createdAt context \(media) }
              ... on MediaMergeNotification { id createdAt reason \(media) }
              ... on FollowingNotification { id createdAt context \(user) }
              ... on ActivityMessageNotification { id createdAt context \(user) }
              ... on ActivityMentionNotification { id createdAt context \(user) }
              ... on ActivityReplyNotification { id createdAt context \(user) }
              ... on ActivityLikeNotification { id createdAt context \(user) }
              ... on ActivityReplyLikeNotification { id createdAt context \(user) }
            }
          }
        }
        """
        let data: NotificationsData = try await run(query, [:], authenticated: true)
        return Self.notifications(from: data)
    }

    /// Resets the unread count, in its own request: GraphQL sibling fields have no order, so it
    /// can't ride along with the read that needs the old count.
    public func markNotificationsRead() async throws {
        struct Empty: Decodable {}
        let _: Empty = try await run("query { Page(page: 1, perPage: 1) { notifications(resetNotificationCount: true) { __typename } } }",
                                     [:], authenticated: true)
    }

    struct NotificationsData: Decodable {
        struct ViewerNode: Decodable { var unreadNotificationCount: Int? }
        struct Item: Decodable {
            struct Title: Decodable { var romaji: String?; var english: String?; var userPreferred: String? }
            struct Image: Decodable { var large: String? }
            struct MediaNode: Decodable { var id: Int?; var title: Title?; var coverImage: Image?; var bannerImage: String? }
            struct UserNode: Decodable { var id: Int?; var name: String?; var avatar: Image? }
            var __typename: String?
            var id: Int?
            var createdAt: Int?
            var episode: Int?
            var context: String?
            var reason: String?
            var media: MediaNode?
            var user: UserNode?
        }
        struct PageNode: Decodable { var notifications: [Item]? }
        var Viewer: ViewerNode?
        var Page: PageNode?
    }

    static func notifications(from data: NotificationsData) -> (items: [AccountNotification], unread: Int) {
        let unread = data.Viewer?.unreadNotificationCount ?? 0
        let items = (data.Page?.notifications ?? []).enumerated().compactMap { index, item -> AccountNotification? in
            guard let type = item.__typename, let id = item.id else { return nil }
            let mediaTitle = item.media?.title.flatMap { $0.english ?? $0.userPreferred ?? $0.romaji }
            let userName = item.user?.name
            let context = (item.context ?? item.reason)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: AccountNotification.Kind
            let badge: String?
            switch type {
            case "AiringNotification":
                kind = .airing
                badge = item.episode.map { "EP \($0)" }
            case "RelatedMediaAdditionNotification":
                kind = .media
                badge = "NEW RELATED"
            case "MediaDataChangeNotification", "MediaMergeNotification":
                kind = .media
                badge = "MEDIA UPDATE"
            default:
                kind = .social
                badge = nil
            }
            let detail = kind == .social ? [userName, context].compactMap { $0?.nonBlank }.joined(separator: " ").nonBlank : nil
            return AccountNotification(
                id: id, kind: kind, createdAt: Date(timeIntervalSince1970: TimeInterval(item.createdAt ?? 0)),
                title: mediaTitle ?? userName ?? "AniList", badge: badge, detail: detail,
                episode: type == "AiringNotification" ? item.episode : nil, mediaID: item.media?.id,
                image: (item.media?.coverImage?.large ?? item.user?.avatar?.large).flatMap(URL.init(string:)),
                unread: index < unread
            )
        }
        return (items, unread)
    }
}
