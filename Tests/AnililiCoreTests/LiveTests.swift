import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AnililiCore

/// Against the real sites, so off by default: `ANILILI_LIVE=1 swift test --filter Live`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANILILI_LIVE"] == "1"))
struct LiveTests {
    @Test func aniListHomeCollectionsDecode() async throws {
        let home = try await AniListClient.shared.homeCollections()
        for (name, row) in [("spotlight", home.spotlight), ("newest", home.newest), ("popular", home.popular),
                            ("movies", home.movies), ("topRated", home.topRated), ("upcoming", home.upcoming)] {
            #expect(!row.isEmpty, "\(name) is empty")
        }
        #expect(home.spotlight.first?.description != nil)
        print("Live: home rows \(home.spotlight.count)/\(home.newest.count)/\(home.popular.count)/\(home.movies.count)/\(home.topRated.count)/\(home.upcoming.count)")
    }

    /// The mirror only: Linux's libcurl has no WebSockets, so the relay path runs on Apple
    /// platforms alone (nos.lol and relay.primal.net held the announcement on 2026-10-12).
    @Test func announcementsVerifyFromTheMirror() async throws {
        let mirrored = await AnnouncementSource.fromMirror()
        print("Live: announcement mirror \(mirrored?.id ?? "none")")
        #expect(mirrored != nil, "the project has an announcement up as of 2026-10-12")
    }

    @Test func neighbourGraphLoadsAndRecommends() async throws {
        let graph = try #require(await MediaIndex.shared.neighbourGraph())
        #expect(graph.count > 5000)
        let picks = Recommendations.because(graph, seed: 154587, exclude: [], hideAdult: true, limit: 12)
        #expect(picks.count >= 6)
        print("Live: neighbour graph \(graph.count) titles; because Frieren: \(picks.prefix(6).map(\.id))")
    }

    @Test func aniListShowPageAndRecommendationsDecode() async throws {
        let frieren = try await AniListClient.shared.media(id: 154587)
        #expect(frieren.mainStudio?.name == "MADHOUSE")
        #expect(frieren.relations?.edges?.isEmpty == false)
        #expect(try await AniListClient.shared.recommendations(id: 154587).count > 5)
        #expect(try await AniListClient.shared.genres().contains("Action"))
    }

    @Test func homeRowsPage() async throws {
        for row in [HomeRow.newest, .trending, .popular, .topRated, .movies, .upcoming] {
            let page = try await AniListClient.shared.homeRow(row, page: 2, hideAdult: true)
            #expect(!page.items.isEmpty, "\(row.rawValue) page 2 is empty")
        }
    }

    @Test func scheduleTodayFromTheIndex() async throws {
        let today = try await ScheduleService().day(Date(), hideAdult: true)
        #expect(today.count > 3)
        #expect(today == today.sorted { $0.airingAt < $1.airingAt })
    }

    @Test func tagsStudiosAndLocalCatalog() async throws {
        #expect(try await AniListClient.shared.tags().count > 300)
        let madhouse = try #require(try await AniListClient.shared.studios(matching: "Madhouse").first)
        #expect(madhouse.id == 11)
        #expect(try await AniListClient.shared.studioMediaIDs(11).contains(154587))
        var filters = DiscoverFilters()
        filters.query = "frier"
        #expect(await LocalCatalog().search(filters, hideAdult: true, dubbedIDs: [], excludedIDs: []).contains { $0.id == 154587 })
    }

    @Test func frieranWatchOrderAndFillers() async throws {
        let detail = await MediaIndex().detail(154587)
        let series = try await WatchOrder.series(154587, indexSeries: detail?.series, hideAdult: true)
        let current = try #require(series.first { $0.id == 154587 })
        let order = WatchOrder.build(current, series: series, hideAdult: true)
        #expect(order.contains { $0.isCurrent && $0.shelf == .seasons })
        let naruto = await MediaIndex().fillerEpisodes(20)
        #expect(naruto.count > 50)
    }

    @Test func softSubsLoadWithTheirServersHeaders() async throws {
        let media = try #require(try await AniListClient.shared.search("Frieren").first)
        let sources = try await Miruro().sources(for: media, episode: 1, audio: .sub)
        let soft = try #require(sources.first { $0.softSub && !$0.subtitles.isEmpty })
        let english = try #require(soft.subtitles.first { $0.language == "en" } ?? soft.subtitles.first)
        let cues = try await Subtitles.load(english, headers: soft.headers)
        #expect(cues.count > 50)
        let hard = try #require(sources.first { !$0.softSub })
        _ = try? await HLSPlaylist.load(hard.url, headers: hard.headers)
        #expect(await SkipTimesService().skipTimes(anilistID: 154587, malID: 52991, episode: 2, length: 1440) != nil)
    }

    @Test func browseAppliesFilters() async throws {
        var filters = DiscoverFilters()
        filters.genres = ["Action"]
        filters.format = "MOVIE"
        filters.sort = "SCORE_DESC"
        let page = try await AniListClient.shared.discover(filters, hideAdult: true)
        #expect(page.items.count == 30)
        #expect(page.total > 100)
        #expect(page.items.allSatisfy { $0.format == "MOVIE" && $0.genres?.contains("Action") == true })
    }

    @Test func mediaIndexAnswers() async throws {
        let index = MediaIndex()
        #expect(await index.dubbedIDs().contains(154587))
        #expect(await index.logo(154587) != nil)
        #expect(await index.episodes(154587).first?.still != nil)
        #expect(await index.detail(999_999_999) == nil)
    }

    /// AniList → Miruro → sub and dub HLS for one episode, with the first master playlist
    /// fetched under its server's headers, as AVPlayer will ask for it.
    @Test func miruroResolvesSubAndDubPlaylists() async throws {
        let media = try #require(try await AniListClient.shared.search("Frieren").first)
        let hub = SourceHub(providers: [Miruro()])

        let listing = try await hub.episodes(for: media)
        #expect(listing.episodes.first?.title != nil)
        for audio in AudioTrack.allCases {
            let sources = try await hub.sources(for: media, episode: 1, audio: audio)
            let first = try #require(sources.first)
            var request = URLRequest(url: first.url)
            for (name, value) in first.headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue(HTTP.safariUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await HTTP.session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data.prefix(7), as: UTF8.self) == "#EXTM3U")
            print("Live: \(audio.rawValue) → \(sources.map(\.label))")
        }
    }

    @Test func scheduleHasThisWeek() async throws {
        let slots = try await AniListClient.shared.schedule(DateInterval(start: Date(), duration: 7 * 24 * 3600))
        #expect(slots.count > 20)
        #expect(slots == slots.sorted { $0.airingAt < $1.airingAt })
    }

    /// AniList title → AnimeHeaven entry → gate → an MP4 the CDN serves bare, which is the whole
    /// reason this provider leads on iOS.
    @Test func animeHeavenResolvesAPlayableMP4() async throws {
        let media = try #require(try await AniListClient.shared.search("Frieren").first)
        let provider = AnimeHeaven()

        let episodes = try await provider.episodes(for: media).episodes.map(\.number)
        let first = try #require(episodes.first, "no episodes for \(media.title.preferred)")
        let streams = try await provider.sources(for: media, episode: first, audio: .sub)
        let stream = try #require(streams.first)

        var request = URLRequest(url: stream.url)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (_, response) = try await HTTP.session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 206)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.contains("video/mp4") == true)
        print("Live: \(media.title.preferred) ep \(first) of \(episodes.count) → \(streams.map(\.label))")
    }
}
