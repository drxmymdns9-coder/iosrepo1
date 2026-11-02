import Foundation
import Testing
@testable import AnililiCore

struct DiscoverTests {
    private func encoded(_ variables: [String: AniListClient.Variable]) throws -> [String: JSON] {
        let data = try JSONEncoder().encode(variables)
        return try JSON.parse(data).object ?? [:]
    }

    @Test func inclusiveBucketsBecomeAniListsExclusiveBounds() throws {
        var filters = DiscoverFilters()
        filters.episodesMin = 13
        filters.episodesMax = 26
        filters.minimumScore = 80
        filters.yearFrom = 1990
        filters.yearTo = 1999
        let vars = try encoded(AniListClient.discoverVariables(filters, page: 2, perPage: 30, hideAdult: true, dubbedIDs: []))

        #expect(vars["episodesMin"]?.number == 12)
        #expect(vars["episodesMax"]?.number == 27)
        #expect(vars["minimumScore"]?.number == 79)
        #expect(vars["startedAfter"]?.number == 19_900_000)
        #expect(vars["startedBefore"]?.number == 20_000_000)
        #expect(vars["isAdult"]?.bool == false)
        #expect(vars["page"]?.number == 2)
        #expect(vars["sort"]?.array?.first?.string == "TRENDING_DESC")
        #expect(vars["search"] == nil)
        #expect(filters.activeCount == 3)
    }

    @Test func dubbedOnlyTravelsAsTheDubIndex() async throws {
        var filters = DiscoverFilters()
        filters.dubbedOnly = true
        let vars = try encoded(AniListClient.discoverVariables(filters, page: 1, perPage: 30, hideAdult: false, dubbedIDs: [3, 1, 2]))
        #expect(vars["mediaIds"]?.array?.compactMap(\.number) == [1, 2, 3])
        // An empty dub index means nothing can match, not "no filter".
        let empty = try await AniListClient.shared.discover(filters, dubbedIDs: [])
        #expect(empty.items.isEmpty)
    }

    @Test func decadesEndInEarlier() {
        let decades = DiscoverFilters.decades(now: Date(timeIntervalSince1970: 1_791_000_000)) // 2026
        #expect(decades.map(\.label) == ["2020s", "2010s", "2000s", "1990s", "1980s", "Earlier"])
        #expect(decades.last?.to == 1979)
    }
}
