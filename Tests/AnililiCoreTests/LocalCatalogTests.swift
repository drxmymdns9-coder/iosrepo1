import Foundation
import Testing
@testable import AnililiCore

struct LocalCatalogTests {
    private func title(_ id: Int, _ name: String, popularity: Int, genres: [String] = ["Action"], format: String = "TV") -> LocalCatalog.Title {
        LocalCatalog.Title(id: id, title: name, popularity: popularity, format: format, genres: genres,
                           poster: "https://s4.anilist.co/file/anilistcdn/media/anime/cover/medium/bx\(id)-a.jpg",
                           poster_color: nil, year: 2000, status: "FINISHED", episodes: 12, score: 80)
    }

    @Test func halfTypedTextFindsWhatAniListsWholeWordsMiss() {
        let titles = [title(1, "One Piece", popularity: 9), title(2, "One Punch Man", popularity: 10), title(3, "Gone Pieces", popularity: 99)]
        var filters = DiscoverFilters()
        filters.query = "one pie"
        filters.sort = "SEARCH_MATCH"
        let found = LocalCatalog.search(titles, filters, hideAdult: true, dubbedIDs: [], excludedIDs: [])
        #expect(found.map(\.id) == [1, 3])
        #expect(found.first?.coverImage?.large?.contains("/cover/large/") == true)
    }

    @Test func rankingPutsTheWholeNameFirstThenPrefixThenContains() {
        let titles = [title(1, "Naruto Shippuden", popularity: 100), title(2, "Naruto", popularity: 1), title(3, "Boruto: Naruto Next", popularity: 500)]
        var filters = DiscoverFilters()
        filters.query = "naruto"
        filters.sort = "SEARCH_MATCH"
        #expect(LocalCatalog.search(titles, filters, hideAdult: true, dubbedIDs: [], excludedIDs: []).map(\.id) == [2, 1, 3])
    }

    @Test func filtersItCannotAnswerReturnNothing() {
        var filters = DiscoverFilters()
        filters.query = "one"
        filters.tags = ["Isekai"]
        #expect(LocalCatalog.search([title(1, "One Piece", popularity: 1)], filters, hideAdult: true, dubbedIDs: [], excludedIDs: []).isEmpty)
    }

    @Test func adultExcludedAndWatchedFiltersApply() {
        let titles = [title(1, "One A", popularity: 1, genres: ["Hentai"]), title(2, "One B", popularity: 2), title(3, "One C", popularity: 3, genres: ["Drama"])]
        var filters = DiscoverFilters()
        filters.query = "one"
        filters.excludedGenres = ["Drama"]
        #expect(LocalCatalog.search(titles, filters, hideAdult: true, dubbedIDs: [], excludedIDs: []).map(\.id) == [2])
        #expect(LocalCatalog.search(titles, filters, hideAdult: true, dubbedIDs: [], excludedIDs: [2]).isEmpty)
    }

    @Test func genreChipsCycleIncludeExcludeOff() {
        var filters = DiscoverFilters()
        filters.cycleGenre("Action")
        #expect(filters.genres == ["Action"])
        filters.cycleGenre("Action")
        #expect(filters.genres.isEmpty && filters.excludedGenres == ["Action"])
        filters.cycleGenre("Action")
        #expect(filters.excludedGenres.isEmpty)
    }

    @Test func idFiltersIntersect() {
        var filters = DiscoverFilters()
        filters.dubbedOnly = true
        filters.studioID = 11
        #expect(AniListClient.mediaIDs(filters, dubbedIDs: [1, 2, 3], studioIDs: [2, 3, 4]) == [2, 3])
        filters.dubbedOnly = false
        #expect(AniListClient.mediaIDs(filters, dubbedIDs: [1], studioIDs: [5]) == [5])
        filters.studioID = nil
        #expect(AniListClient.mediaIDs(filters, dubbedIDs: [1], studioIDs: nil) == nil)
    }
}
