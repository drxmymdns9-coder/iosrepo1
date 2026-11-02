import Foundation
import Testing
@testable import AnililiCore

/// Fixtures are the Android app's, lifted verbatim from live pages on 2026-09-13, including the
/// site's apostrophe-quoted attributes, its stray whitespace inside tags and its valueless `alt`.
struct AnimeHeavenParserTests {
    @Test func searchCardsReadThePathAndDecodeTheTitle() throws {
        let results = AnimeHeavenParser.parseSearch(try Fixture.text("animeheaven/search.html"))

        #expect(results.map(\.path) == ["anime.php?ak2gr", "anime.php?hgj3i"])
        #expect(results[0].title == "Frieren: Beyond Journey's End")
        #expect(results[1].title == "Frieren 2nd Season")
    }

    @Test func chartRowsParseAsTheSameEntries() throws {
        // The inner `chartimg` / `chartep` divs must not count as cards, and the bookmark
        // button's valueless `alt` must not be read as a title.
        let results = AnimeHeavenParser.parseSearch(try Fixture.text("animeheaven/chart.html"))

        #expect(results == [.init(path: "anime.php?sfvog", title: "Mushoku Tensei: Jobless Reincarnation 3rd Season")])
    }

    @Test func episodesComeBackAscendingWithTheirGateKeys() throws {
        let episodes = AnimeHeavenParser.parseEpisodes(try Fixture.text("animeheaven/episodes.html"))

        #expect(episodes.map(\.number) == [26, 27, 28])
        #expect(episodes.first { $0.number == 26 }?.gateKey == "aaef295ca750e9bf2d7077cbc27df63d")
        #expect(episodes.first { $0.number == 28 }?.gateKey == "47edc338ae59c34cc3ea427c7f6871df")
    }

    @Test func aRowWithNoNumberIsDroppedRatherThanBorrowingTheNext() throws {
        let html = try Fixture.text("animeheaven/episodes.html").replacingOccurrences(
            of: "<div  class= ' watch2 bc ' >27</div>",
            with: "<div class='watch1 bc c'>27</div>"
        )

        let episodes = AnimeHeavenParser.parseEpisodes(html)

        #expect(episodes.map(\.number) == [26, 28])
        #expect(episodes.first { $0.number == 26 }?.gateKey == "aaef295ca750e9bf2d7077cbc27df63d")
        #expect(episodes.first { $0.number == 28 }?.gateKey == "47edc338ae59c34cc3ea427c7f6871df")
    }

    /// One Piece's page lists "1100.5" (a recap) just above 1100, newest first (2026-10-12).
    @Test func aRecapIsNotTakenForTheEpisodeBelowIt() throws {
        let html = try Fixture.text("animeheaven/episodes.html").replacingOccurrences(
            of: "<div  class= ' watch2 bc ' >27</div>",
            with: "<div  class= ' watch2 bc ' >26.5</div>"
        )
        let episodes = AnimeHeavenParser.parseEpisodes(html)
        #expect(episodes.map(\.number) == [26, 28])
        #expect(episodes.first { $0.number == 26 }?.gateKey == "aaef295ca750e9bf2d7077cbc27df63d")
    }

    @Test func gateMirrorsKeepThePageOrderAndDropTheRepeat() throws {
        let urls = AnimeHeavenParser.videoURLs(try Fixture.text("animeheaven/gate.html"))

        #expect(urls.count == 3)
        #expect(urls[0].hasPrefix("https://ax.animeheaven.me/"))
        #expect(urls[1].hasPrefix("https://ct.animeheaven.me/"))
        #expect(urls[2].hasPrefix("https://ck.animeheaven.me/"))
        // Two tokens joined by a bare `&`; entity decoding must not eat it.
        #expect(urls[0].hasSuffix("?47edc338ae59c34cc3ea427c7f6871df&62e1da5299fc22a964b06b8c9125d847"))
    }

    @Test func aPageWithNothingParsesAsEmpty() {
        #expect(AnimeHeavenParser.parseEpisodes("<div>Not Found</div>").isEmpty)
        #expect(AnimeHeavenParser.parseSearch("<div>Not Found</div>").isEmpty)
        #expect(AnimeHeavenParser.videoURLs("<div>Not Found</div>").isEmpty)
    }
}

struct AnimeHeavenProviderTests {
    private static let base = URL(string: "https://animeheaven.test")!

    private static func frieren() -> Media {
        Media(id: 154587, title: .init(romaji: "Sousou no Frieren", english: "Frieren: Beyond Journey's End"))
    }

    /// Serves the fixtures by path and records every request.
    private final class FakeSite: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [(url: URL, headers: [String: String])] = []
        var failSearch = false

        func fetch(_ url: URL, _ headers: [String: String]) throws -> String {
            lock.lock()
            requests.append((url, headers))
            lock.unlock()
            switch url.path {
            case "/search.php":
                if failSearch { throw HTTPError(status: 503, "down") }
                return try Fixture.text("animeheaven/search.html")
            case "/anime.php": return try Fixture.text("animeheaven/episodes.html")
            case "/gate.php": return try Fixture.text("animeheaven/gate.html")
            default: throw HTTPError(status: 404, "no fixture for \(url)")
            }
        }
    }

    @Test func resolvesAnEpisodeToItsMirrorsWithTheGateCookie() async throws {
        let site = FakeSite()
        let provider = AnimeHeaven(base: Self.base) { url, headers in try site.fetch(url, headers) }

        #expect(try await provider.episodes(for: Self.frieren()).episodes.map(\.number) == [26, 27, 28])
        let streams = try await provider.sources(for: Self.frieren(), episode: 27, audio: .sub)

        #expect(streams.map(\.server) == ["Mirror 1 (ax)", "Mirror 2 (ct)", "Mirror 3 (ck)"])
        #expect(try await provider.sources(for: Self.frieren(), episode: 27, audio: .dub).isEmpty)
        #expect(streams.allSatisfy { $0.kind == .mp4 && $0.headers.isEmpty })
        let gate = try #require(site.requests.last)
        #expect(gate.url.absoluteString == "https://animeheaven.test/gate.php")
        #expect(gate.headers["Cookie"] == "key=0437d20b317e2834760f61c83f8c973a")
        #expect(gate.headers["Referer"] == "https://animeheaven.test/anime.php?ak2gr")
    }

    @Test func theFirstSearchUsesTheSeasonStrippedNameAndIsEncoded() async throws {
        let site = FakeSite()
        let provider = AnimeHeaven(base: Self.base) { url, headers in try site.fetch(url, headers) }

        _ = try await provider.episodes(for: Self.frieren())

        let search = try #require(site.requests.first)
        #expect(search.url.absoluteString == "https://animeheaven.test/search.php?s=Frieren%3A%20Beyond%20Journey%27s%20End")
    }

    @Test func anUnreachableSiteThrowsInsteadOfCachingAMiss() async throws {
        let site = FakeSite()
        site.failSearch = true
        let provider = AnimeHeaven(base: Self.base) { url, headers in try site.fetch(url, headers) }

        await #expect(throws: HTTPError.self) { try await provider.episodes(for: Self.frieren()) }
        // Had that been remembered as "no entry", this would return [] without asking again.
        site.failSearch = false
        #expect(try await provider.episodes(for: Self.frieren()).episodes.map(\.number) == [26, 27, 28])
    }

    @Test func theAskedForSeasonOutranksABetterTitleScore() {
        let tanya2 = Media(id: 1, title: .init(romaji: "Youjo Senki II", english: "Saga of Tanya the Evil Season 2"))
        let candidates: [AnimeHeavenParser.SearchResult] = [
            .init(path: "anime.php?one", title: "Saga of Tanya the Evil"),
            .init(path: "anime.php?two", title: "Saga of Tanya the Evil II"),
        ]

        #expect(AnimeHeaven.rank(candidates, for: tanya2).map(\.path) == ["anime.php?two", "anime.php?one"])
    }

    @Test func searchQueriesLeadWithTheBaseSeries() {
        let media = Media(id: 2, title: .init(romaji: "Ore dake Level Up na Ken Season 2: Arise from the Shadow", english: "Solo Leveling Season 2 -Arise from the Shadow-"))

        #expect(AnimeHeaven.searchQueries(media) == [
            "Solo Leveling",
            "Solo Leveling Season 2 -Arise from the Shadow-",
            "Ore dake Level Up na Ken",
        ])
    }
}
