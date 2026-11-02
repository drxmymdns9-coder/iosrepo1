import Foundation
import Testing
@testable import AnililiCore

/// Android's `AniDbAppProviderTest`, on its fixtures, against a faked network.
struct AniDbAppTests {
    /// Path (and the catalogue's `post?id=`) → (status, body); anything else is a 404.
    private final class Routes: @unchecked Sendable {
        var table: [String: (Int, String)] = [:]
        let asked = RequestLog()

        func answer(_ url: URL) -> (Int, String) {
            let host = url.host ?? ""
            let prefix = host == "anidb.app" ? "/site" : host == "play.anidb.app" ? "/play" : "/cat"
            let path = url.path.replacingOccurrences(of: "/api", with: "")
            let key = prefix + path + (path.hasSuffix("/post") ? "?" + (url.query ?? "") : "")
            asked.append(key)
            return table[key] ?? (404, #"{"message":"Not found."}"#)
        }
    }

    private func deathNote() -> Media {
        var media = Media(id: 1535, title: .init(romaji: "Death Note", english: "Death Note"))
        media.idMal = 1535
        media.episodes = 2
        media.seasonYear = 2006
        media.format = "TV"
        return media
    }

    private func playerAPI(_ routes: Routes) {
        routes.table["/play/anime/1000001199/episodes"] = (200, #"{"list":[{"id":"10","name":"Episode 1","number":"1","filler":false},{"id":"11","name":"Episode 2","number":"2","filler":false}]}"#)
        routes.table["/play/episode/10/servers"] = (200, #"{"list":[{"id":"10/jpn","lang":"sub","name":"SUB Server #1"},{"id":"10/eng","lang":"dub","name":"DUB Server #1"}]}"#)
        routes.table["/play/episode/11/servers"] = (200, #"{"list":[{"id":"11/jpn","lang":"sub","name":"SUB Server #1"}]}"#)
        routes.table["/play/episode/11/jpn/iframe"] = (200, #"{"link":"https:\/\/hls.test\/death-note-2\/master.m3u8"}"#)
    }

    @Test func theWebsitesIdentityStreamsThroughThePlayerAPI() async throws {
        let routes = Routes()
        routes.table["/site/search/suggestions"] = (200, #"<a href="/anime/death-note-1199" data-search-item><p class="text-sm font-medium">Death Note</p></a>"#)
        routes.table["/site/anime/death-note-1199"] = (200, #"<a href="https://anilist.co/anime/1535">AniList</a><a href="https://myanimelist.net/anime/1535">MAL</a>"#)
        playerAPI(routes)
        let provider = AniDbApp { url, _ in routes.answer(url) }
        let listing = try await provider.episodes(for: deathNote())
        #expect(listing.subbed == [1, 2])
        #expect(listing.dubbed == [1])
        let stream = try #require(try await provider.sources(for: deathNote(), episode: 2, audio: .sub).first)
        #expect(stream.url.absoluteString == "https://hls.test/death-note-2/master.m3u8")
        #expect(stream.headers.isEmpty)
        #expect(routes.asked.entries.contains("/play/episode/11/jpn/iframe"))
    }

    @Test func aWebsiteInMaintenanceFallsBackToTheCatalogue() async throws {
        let routes = Routes()
        routes.table["/site/search/suggestions"] = (503, "Under maintenance")
        routes.table["/cat/search"] = (200, #"{"posts":[{"id":1000001200},{"id":1000001199}]}"#)
        // Same title, wrong year: the sequel loses on the year before titles are compared.
        routes.table["/cat/post?id=1000001200"] = (200, #"{"id":1000001200,"type":"TV","title":"Death Note","premiered":"Summer 2007"}"#)
        routes.table["/cat/post?id=1000001199"] = (200, #"{"id":1000001199,"type":"TV","title":"Death Note","premiered":"Fall 2006"}"#)
        playerAPI(routes)
        let listing = try await AniDbApp { url, _ in routes.answer(url) }.episodes(for: deathNote())
        #expect(listing.subbed == [1, 2])
        #expect(routes.asked.entries.contains("/play/anime/1000001199/episodes"))
    }

    /// Since 2026-10 anidb.app redirects to anilab.so's home page: a whole page, not a fragment.
    @Test func aWebsiteThatMovedIsTreatedAsDown() async throws {
        let routes = Routes()
        routes.table["/site/search/suggestions"] = (200, "<!DOCTYPE html><html><head><title>Anilab</title></head><body>…</body></html>")
        routes.table["/cat/search"] = (200, #"{"posts":[{"id":1000001199}]}"#)
        routes.table["/cat/post?id=1000001199"] = (200, #"{"id":1000001199,"type":"TV","title":"Death Note","premiered":"Fall 2006"}"#)
        playerAPI(routes)
        let listing = try await AniDbApp { url, _ in routes.answer(url) }.episodes(for: deathNote())
        #expect(listing.subbed == [1, 2])
    }

    @Test func anAnsweringWebsiteThatNamesAnotherTitleIsFinal() async throws {
        let routes = Routes()
        routes.table["/site/search/suggestions"] = (200, #"<a href="/anime/death-note-rewrite-1200" data-search-item><p class="text-sm">Death Note</p></a>"#)
        routes.table["/site/anime/death-note-rewrite-1200"] = (200, #"<a href="https://anilist.co/anime/2994">AniList</a>"#)
        routes.table["/cat/search"] = (200, #"{"posts":[{"id":1000001199}]}"#)
        #expect(try await AniDbApp { url, _ in routes.answer(url) }.episodes(for: deathNote()).isEmpty)
        #expect(!routes.asked.entries.contains { $0.hasPrefix("/cat/") })
    }

    @Test func numberingAndFormatsLineUp() {
        #expect(AniDbAppParser.inferOffset([25, 26, 27], 3) == 24, "a later season numbered on from the first")
        #expect(AniDbAppParser.inferOffset([1, 2, 3], 3) == 0)
        #expect(AniDbAppParser.sameFormatFamily("TV_SHORT", "TV"))
        #expect(!AniDbAppParser.sameFormatFamily("TV", "ONA"))
        #expect(AniDbAppParser.sameFormatFamily(nil, "Movie"))
        #expect(AniDbAppParser.isCloudflareChallenge("<title>Just a moment...</title>"))
    }
}
