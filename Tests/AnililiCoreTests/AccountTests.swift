import Foundation
import Testing
@testable import AnililiCore

/// Sign-in parsing for both services.
struct AccountAuthTests {
    @Test func aniListAuthorizeURLNamesNoRedirect() throws {
        let url = AniListAuth.authorizeURL(state: "S1")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.host == "anilist.co")
        #expect(items.first { $0.name == "client_id" }?.value == "45552")
        #expect(items.first { $0.name == "response_type" }?.value == "token")
        #expect(items.first { $0.name == "state" }?.value == "S1")
        #expect(!items.contains { $0.name == "redirect_uri" })
    }

    @Test func aniListTokenComesFromTheFragmentWithTheRightState() throws {
        let redirect = try #require(URL(string: "http://localhost/#access_token=abc.def.ghi&token_type=Bearer&expires_in=31536000&state=S1"))
        #expect(AniListAuth.isRedirect(redirect))
        #expect(AniListAuth.token(from: redirect, expectedState: "S1") == "abc.def.ghi")
        #expect(AniListAuth.token(from: redirect, expectedState: "other") == nil)
        let https = try #require(URL(string: "https://localhost#access_token=tok&state=S1"))
        #expect(AniListAuth.token(from: https, expectedState: "S1") == "tok")
        let elsewhere = try #require(URL(string: "https://anilist.co/#access_token=tok&state=S1"))
        #expect(!AniListAuth.isRedirect(elsewhere))
    }

    @Test func jwtClaimsGiveExpiryAndViewer() {
        func token(_ payload: String) -> String { "e30.\(Base64URL.encode(Data(payload.utf8))).sig" }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let live = token(#"{"exp":1900000000,"sub":"5170434"}"#)
        #expect(!AniListAuth.isExpired(live, now: now))
        #expect(AniListAuth.viewerID(live) == 5_170_434)
        #expect(AniListAuth.isExpired(token(#"{"exp":1800000030}"#), now: now))
        #expect(!AniListAuth.isExpired("not-a-jwt", now: now))
    }

    @Test func malUsesPlainPKCEAndReadsTheCode() throws {
        let url = MALAuth.authorizeURL(state: "S2", verifier: "V")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "code_challenge" }?.value == "V")
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "plain")
        #expect(items.first { $0.name == "response_type" }?.value == "code")
        let redirect = try #require(URL(string: "https://localhost/?code=XYZ&state=S2"))
        #expect(MALAuth.code(from: redirect, expectedState: "S2") == "XYZ")
        #expect(MALAuth.code(from: redirect, expectedState: "S3") == nil)
    }

    @Test func randomStringsAreURLSafe() {
        let verifier = OAuthRandom.urlSafe(bytes: 32)
        #expect(verifier.count == 43)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(verifier != OAuthRandom.urlSafe(bytes: 32))
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(FormEncoding.encode(["b": "x y&z", "a": "1"]) == "a=1&b=x%20y%26z")
    }
}

/// Android's sync rules (`AniListPolicyTest`, `RemoteProgressReconcileTest`, `WatchlistRemovalTest`).
struct ListSyncTests {
    @Test func progressPlanMatchesAndroid() {
        #expect(ListSync.planProgress(current: nil, watched: 3, totalEpisodes: 12) == ProgressUpdate(progress: 3, status: .current))
        #expect(ListSync.planProgress(current: nil, watched: 1, totalEpisodes: nil) == ProgressUpdate(progress: 1, status: .current))
        #expect(ListSync.planProgress(current: (.current, 11), watched: 12, totalEpisodes: 12) == ProgressUpdate(progress: 12, status: .completed))
        #expect(ListSync.planProgress(current: (.paused, 4), watched: 5, totalEpisodes: 12) == ProgressUpdate(progress: 5, status: nil))
        #expect(ListSync.planProgress(current: (.repeating, 11), watched: 12, totalEpisodes: 12) == ProgressUpdate(progress: 12, status: nil))
        #expect(ListSync.planProgress(current: (.completed, 12), watched: 13, totalEpisodes: 13) == nil)
        #expect(ListSync.planProgress(current: (.current, 8), watched: 7, totalEpisodes: 12) == nil)
        #expect(ListSync.planProgress(current: (.planning, 0), watched: 1, totalEpisodes: 1) == ProgressUpdate(progress: 1, status: .completed))
        #expect(ListSync.planProgress(current: nil, watched: 0, totalEpisodes: 12) == nil)
    }

    @Test func resumeEpisodeMatchesAndroid() {
        #expect(ListSync.resumeEpisode(progress: 8, totalEpisodes: 12, airedEpisodes: 10) == 9)
        #expect(ListSync.resumeEpisode(progress: 8, totalEpisodes: nil, airedEpisodes: nil) == 9)
        #expect(ListSync.resumeEpisode(progress: 8, totalEpisodes: 12, airedEpisodes: 8) == 8)
        #expect(ListSync.resumeEpisode(progress: 9, totalEpisodes: 12, airedEpisodes: 8) == 8)
        #expect(ListSync.resumeEpisode(progress: 12, totalEpisodes: 12, airedEpisodes: nil) == nil)
    }

    @Test func onlyAMoveOffWatchingCounts() {
        let previous: [Int: ListStatus] = [1: .current, 2: .repeating, 3: .completed, 4: .current]
        let current: [Int: ListStatus] = [1: .completed, 2: .paused, 3: .completed, 4: .current, 5: .dropped]
        #expect(ListSync.movesOffWatching(previous: previous, current: current) == [1, 2])
    }

    private func media(_ id: Int) -> Media { Media(id: id, title: .init(romaji: "T\(id)")) }

    @Test func watchlistMergeDropsOnlyWhatTheAccountForgot() {
        // Unsaved on another device: known before, unknown now.
        let dropped = ListSync.mergeWatchlist(local: [media(1), media(2)], planning: [media(2)], knownRemoteIDs: [2], previousRemoteIDs: [1, 2])
        #expect(dropped.map(\.id) == [2])
        // A save the account has never seen survives.
        let kept = ListSync.mergeWatchlist(local: [media(9)], planning: [media(2)], knownRemoteIDs: [2], previousRemoteIDs: [2])
        #expect(kept.map(\.id) == [9, 2])
        // First refresh only adds.
        let first = ListSync.mergeWatchlist(local: [media(1)], planning: [media(2)], knownRemoteIDs: [2], previousRemoteIDs: [])
        #expect(first.map(\.id) == [1, 2])
        // Moved to Watching is still known: the save stays.
        let moved = ListSync.mergeWatchlist(local: [media(1)], planning: [], knownRemoteIDs: [1], previousRemoteIDs: [1])
        #expect(moved.map(\.id) == [1])
        // An empty snapshot is no information.
        let empty = ListSync.mergeWatchlist(local: [media(1)], planning: [], knownRemoteIDs: [], previousRemoteIDs: [1])
        #expect(empty.map(\.id) == [1])
    }

    @Test func malStatusesTranslate() {
        #expect(ListStatus(mal: "watching", rewatching: false) == .current)
        #expect(ListStatus(mal: "completed", rewatching: true) == .repeating)
        #expect(ListStatus(mal: "on_hold", rewatching: false) == .paused)
        #expect(ListStatus(mal: "plan_to_watch", rewatching: false) == .planning)
        #expect(ListStatus.repeating.malValue == "watching")
        #expect(ListStatus.paused.malValue == "on_hold")
        #expect(ListSync.clampProgress(25, totalEpisodes: 24) == 24)
        #expect(ListSync.clampProgress(25, totalEpisodes: nil) == 25)
    }

    @Test func scoresReadLikeAndroid() {
        #expect(ListScore.points == [10, 9, 8, 7, 6, 5, 4, 3, 2, 1])
        #expect(ListScore.label(10) == "Masterpiece")
        #expect(ListScore.label(1) == "Appalling")
        #expect(ListScore.label(0) == nil)
        #expect(ListScore.format(8) == "8")
        #expect(ListScore.format(7.5) == "7.5")
        #expect(ListScore.whole(8) == 8)
        #expect(ListScore.whole(7.5) == nil)
        #expect(ListScore.aniListRaw(8) == 80)
    }
}

/// Decoding the account's responses.
struct AccountDecodingTests {
    @Test func customListNamesTakeEveryShape() throws {
        struct Box: Decodable { var lists: CustomListNames }
        func names(_ json: String) throws -> [String] {
            try JSONDecoder().decode(Box.self, from: Data(#"{"lists":\#(json)}"#.utf8)).lists.names
        }
        #expect(try names(#"["Favs","Rewatch"]"#) == ["Favs", "Rewatch"])
        #expect(try names(#"[{"name":"Favs","enabled":true},{"name":"Old","enabled":false}]"#) == ["Favs"])
        #expect(try names(#"{"B":true,"A":true,"C":false}"#) == ["A", "B"])
        #expect(try names("null") == [])
    }

    @Test func aniListScoreConfirmationIsChecked() throws {
        func saved(_ json: String) throws -> AniListClient.ScoreSaved {
            try JSONDecoder().decode(AniListClient.ScoreSaved.self, from: Data(json.utf8))
        }
        #expect(throws: Never.self) { try AniListClient.checkScore(try saved(#"{"SaveMediaListEntry":{"id":1,"score":8}}"#), requested: 8) }
        #expect(throws: Never.self) { try AniListClient.checkScore(try saved(#"{"SaveMediaListEntry":{"id":1,"score":0}}"#), requested: 0) }
        #expect(throws: HTTPError.self) { try AniListClient.checkScore(try saved(#"{"SaveMediaListEntry":{"id":1,"score":7.5}}"#), requested: 8) }
        #expect(throws: HTTPError.self) { try AniListClient.checkScore(try saved(#"{"SaveMediaListEntry":null}"#), requested: 8) }
    }

    @Test func listCollectionBecomesALibrary() throws {
        let json = """
        {"user":{"mediaListOptions":{"animeList":{"customLists":["Favs","Empty"]}}},
         "lists":[
          {"entries":[
            {"id":11,"updatedAt":1700000000,"progress":3,"score":8.5,"status":"CURRENT","hiddenFromStatusLists":false,
             "customLists":[{"name":"Favs","enabled":true}],"media":{"id":21,"title":{"romaji":"One"}}},
            {"id":12,"updatedAt":1600000000,"progress":0,"score":0,"status":"PLANNING","hiddenFromStatusLists":true,
             "customLists":[{"name":"Favs","enabled":true}],"media":{"id":22,"title":{"romaji":"Two"}}}]},
          {"entries":[
            {"id":11,"updatedAt":1700000000,"progress":3,"score":8.5,"status":"CURRENT","hiddenFromStatusLists":false,
             "customLists":[{"name":"Favs","enabled":true}],"media":{"id":21,"title":{"romaji":"One"}}},
            {"id":13,"status":"WEIRD","media":{"id":23,"title":{"romaji":"Three"}}}]}
         ]}
        """
        let collection = try JSONDecoder().decode(AniListClient.CollectionData.Collection.self, from: Data(json.utf8))
        let library = AniListClient.library(from: collection)
        #expect(library.entries.map(\.entryID) == [11, 12])
        #expect(library.customListNames == ["Favs", "Empty"])
        #expect(library.statuses == [21: .current])
        #expect(library.entries(inCustomList: "Favs").map(\.id) == [21, 22])
        #expect(library.entries(.current).first?.score == 8.5)
    }

    @Test func notificationsReadLikeAndroid() throws {
        let json = """
        {"Viewer":{"unreadNotificationCount":1},
         "Page":{"notifications":[
          {"__typename":"AiringNotification","id":1,"createdAt":1700000000,"episode":5,
           "media":{"id":21,"title":{"romaji":"Romaji","english":"English"},"coverImage":{"large":"https://x/c.jpg"}}},
          {"__typename":"FollowingNotification","id":2,"createdAt":1700000100,"context":" started following you.",
           "user":{"id":9,"name":"someone","avatar":{"large":"https://x/a.png"}}},
          {"__typename":"MediaMergeNotification","id":3,"createdAt":1,"reason":"merged","media":{"id":4,"title":{"romaji":"R"}}}]}}
        """
        let data = try JSONDecoder().decode(AniListClient.NotificationsData.self, from: Data(json.utf8))
        let (items, unread) = AniListClient.notifications(from: data)
        #expect(unread == 1)
        #expect(items.map(\.unread) == [true, false, false])
        #expect(items[0].title == "English")
        #expect(items[0].badge == "EP 5")
        #expect(items[0].episode == 5)
        #expect(items[1].kind == .social)
        #expect(items[1].detail == "someone started following you.")
        #expect(items[2].badge == "MEDIA UPDATE")
    }

    @Test func malListJoinsToAniList() throws {
        let json = """
        {"data":[
          {"node":{"id":100,"title":"A","num_episodes":24},"list_status":{"status":"watching","score":7,"num_episodes_watched":25,
           "is_rewatching":false,"updated_at":"2018-04-25T22:23:11+00:00","tags":["fav"]}},
          {"node":{"id":200,"title":"B","num_episodes":0},"list_status":{"status":"plan_to_watch","num_episodes_watched":0}},
          {"node":{"id":300,"title":"Unknown"},"list_status":{"status":"completed"}}],
         "paging":{}}
        """
        let page = try JSONDecoder().decode(MALClient.ListPage.self, from: Data(json.utf8))
        let entries = MALClient.entries(from: page)
        #expect(entries.count == 3)
        #expect(entries[0].updatedAt == Date(timeIntervalSince1970: 1_524_694_991))
        #expect(entries[1].totalEpisodes == nil)
        var a = Media(id: 1, title: .init(romaji: "A"))
        a.idMal = 100
        a.episodes = 24
        var b = Media(id: 2, title: .init(romaji: "B"))
        b.idMal = 200
        let joined = MALClient.join(entries, byMAL: [100: a, 200: b])
        #expect(joined.map(\.id) == [1, 2])
        #expect(joined[0].progress == 24)
        #expect(joined[0].customLists == ["fav"])
        #expect(joined[1].status == .planning)
    }
}
