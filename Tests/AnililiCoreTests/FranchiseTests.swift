import Foundation
import Testing
@testable import AnililiCore

/// The desktop's `franchise.rs` tests, case for case.
struct FranchiseTests {
    private func member(_ id: Int, _ format: String, _ year: Int, _ relations: [(String, Media)] = []) -> Media {
        var media = Media(id: id, title: .init(english: "#\(id)"))
        media.format = format
        media.seasonYear = year
        media.startDate = .init(year: year, month: 1, day: 1)
        media.relations = .init(edges: relations.map { .init(relationType: $0.0, node: $0.1) })
        return media
    }

    @Test func shelvesTheFranchiseInRunningOrder() {
        let movie = member(9, "MOVIE", 2022)
        let recap = member(8, "SPECIAL", 2021)
        let manga = member(7, "MANGA", 2015)
        let s1 = member(1, "TV", 2020, [("SEQUEL", member(2, "TV", 2021)), ("ADAPTATION", manga)])
        let s2 = member(2, "TV", 2021, [("PREQUEL", member(1, "TV", 2020)), ("SIDE_STORY", movie), ("SUMMARY", recap)])
        let order = WatchOrder.build(s2, series: [s1, s2], hideAdult: true)

        #expect(order.map(\.media.id) == [1, 2, 9, 8])
        #expect(order.map(\.shelf) == [.seasons, .seasons, .movies, .specials])
        #expect(order.map(\.seasonNumber) == [1, 2, nil, nil])
        #expect(order[1].isCurrent)
        #expect(order[2].relation == "Side story")
        #expect(order.allSatisfy { $0.media.id != 7 }, "the manga is not part of a watch order")
        #expect(order.allSatisfy { $0.chronological == $0.position })
    }

    @Test func aPrequelThatAiredLaterLeadsTheStory() {
        let movie = member(9, "MOVIE", 2009)
        let sn = member(1, "TV", 2006, [("SIDE_STORY", movie)])
        let zero = member(2, "TV", 2011, [("SEQUEL", sn)])
        let order = WatchOrder.build(zero, series: [sn, zero], hideAdult: true)
        func at(_ id: Int) -> WatchOrder.Entry { order.first { $0.media.id == id }! }
        #expect((at(1).position, at(9).position, at(2).position) == (1, 2, 3))
        #expect((at(9).chronological, at(2).chronological, at(1).chronological) == (1, 2, 3))
        #expect(at(2).isCurrent)
    }

    @Test func cyclicRelationsLeaveTheStoryAtTheAiringOrder() {
        let a = member(1, "TV", 2020, [("SEQUEL", member(2, "TV", 2021))])
        let b = member(2, "TV", 2021, [("SEQUEL", member(1, "TV", 2020))])
        let order = WatchOrder.build(a, series: [a, b], hideAdult: true)
        #expect(order.allSatisfy { $0.chronological == $0.position })
    }

    @Test func theEpisodesTabsSeasonChainNumbersTheShelf() {
        // TheTVDB files the ONA as season 2 and the TV entry as season 3, against airing order.
        let s1 = member(1, "TV", 2018, [("SEQUEL", member(3, "TV", 2020))])
        let ona = member(2, "ONA", 2021)
        let s3 = member(3, "TV", 2020, [("PREQUEL", s1)])
        let order = WatchOrder.build(s1, series: [s1, s3, ona], seasons: [s1, ona, s3], hideAdult: true)
        #expect(order.map(\.media.id) == [1, 2, 3])
        #expect(order.map(\.seasonNumber) == [1, 2, 3])
        #expect(order.allSatisfy { $0.shelf == .seasons })
    }

    @Test func seasonChainFallsBackToTheEpisodicEntries() {
        let s1 = member(1, "TV", 2018)
        let movie = member(2, "MOVIE", 2019)
        let s2 = member(3, "ONA", 2020)
        let chain = WatchOrder.seasonChain(s1, series: [s1, movie, s2], ref: { _ in nil })
        #expect(chain.map(\.id) == [1, 3])
    }

    @Test func theSeedIsTheTitleAndItsDirectNeighbours() {
        let s2 = member(2, "TV", 2021, [("SEQUEL", member(3, "TV", 2022)), ("PREQUEL", member(1, "TV", 2020)), ("SIDE_STORY", member(9, "MOVIE", 2021))])
        #expect(WatchOrder.seeded(s2, hideAdult: true).map(\.id) == [1, 2, 3])
    }

    @Test func metaLinesReadLikeAndroids() {
        var s2 = member(2, "TV", 2023)
        s2.episodes = 12
        var film = member(9, "MOVIE", 2024)
        film.episodes = 1
        let season = WatchOrder.Entry(media: s2, shelf: .seasons, position: 2, chronological: 2, seasonNumber: 2, relation: nil, isCurrent: false)
        let movie = WatchOrder.Entry(media: film, shelf: .movies, position: 3, chronological: 3, seasonNumber: nil, relation: "Side story", isCurrent: false)
        #expect(season.metaLine == "Season 2 · 2023 · 12 eps")
        #expect(movie.metaLine == "Movie · Side story · 2024")
        #expect(s2.relatedMetaLine == "TV · 2023 · 12 eps")
    }

    @Test func suggestionsLeaveOutTheGuideAndWhatIsntWatchable() {
        let s1 = member(1, "TV", 2020, [("SEQUEL", member(2, "TV", 2021))])
        let guide = WatchOrder.build(s1, series: [s1], hideAdult: true)
        var adult = member(6, "TV", 2019)
        adult.isAdult = true
        let picks = [member(2, "TV", 2021), member(1, "TV", 2020), member(4, "MANGA", 2010), adult, member(5, "TV", 2018), member(5, "TV", 2018)]
        #expect(WatchOrder.suggestions(picks, current: 1, guide: guide, hideAdult: true).map(\.id) == [5])
        #expect(WatchOrder.suggestions(picks, current: 1, guide: guide, hideAdult: false).map(\.id) == [6, 5])
    }
}

struct EpisodeCatalogTests {
    @Test func fillsGapsFromTheIndexThenAniListAndListsWhatsComing() {
        var miruro = EpisodeInfo(number: 1)
        miruro.title = "From Miruro"
        let listing = EpisodeListing(episodes: [miruro, EpisodeInfo(number: 2)], subbed: [1, 2], dubbed: [1])
        let index = [
            MediaIndex.Episode(number: 1, title: "Index 1", overview: "o1", air_date: "2026-01-01", still: "https://tmdb/1.jpg", runtime: 24),
            MediaIndex.Episode(number: 2, title: nil, overview: "o2", air_date: "2026-01-08", still: nil, runtime: nil),
            MediaIndex.Episode(number: 3, title: "Next week", overview: nil, air_date: "2026-12-31", still: nil, runtime: nil),
        ]
        let streaming = [Media.StreamingEpisode(title: "Episode 2 - Licensed Title", thumbnail: "https://cr/2.jpg", url: nil, site: "Crunchyroll")]

        let merged = EpisodeCatalog.merge(listing, index: index, streaming: streaming, filler: [2])

        #expect(merged.episodes.map(\.number) == [1, 2, 3])
        #expect(merged.episodes[0].title == "From Miruro")
        #expect(merged.episodes[0].thumbnail?.absoluteString == "https://tmdb/1.jpg")
        #expect(merged.episodes[1].title == "Licensed Title")
        #expect(merged.episodes[1].thumbnail?.absoluteString == "https://cr/2.jpg")
        #expect(merged.episodes[1].isFiller)
        #expect(merged.available(.sub).map(\.number) == [1, 2], "episode 3 isn't out on any provider")
    }

    @Test func blocksAndFilterFollowAndroid() {
        let episodes = (1051...1290).map(EpisodeInfo.init(number:))
        let blocks = EpisodeCatalog.blocks(episodes)
        #expect(blocks.map(\.label) == ["1051 – 1150", "1151 – 1250", "1251 – 1290"])
        #expect(EpisodeCatalog.blockIndex(blocks, holding: 1200) == 1)
        var titled = EpisodeInfo(number: 7)
        titled.title = "Episode about 105 cats"
        let found = EpisodeCatalog.filter(episodes + [titled], "105")
        #expect(found.first?.number == 1051)
        #expect(found.last?.number == 7)
    }
}
