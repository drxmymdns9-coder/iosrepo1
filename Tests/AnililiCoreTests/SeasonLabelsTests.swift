import Foundation
import Testing
@testable import AnililiCore

/// Android's `SeasonLabelsTest` and `TvdbSeasonChainTest`, against the real AniList entries and
/// TheTVDB placements they use.
struct SeasonLabelsTests {
    private func media(_ id: Int, _ english: String?, romaji: String? = nil, format: String = "TV") -> Media {
        var media = Media(id: id, title: .init(romaji: romaji, english: english))
        media.format = format
        return media
    }

    private func labels(_ seasons: [Media], _ refs: [Int: TVDBRef] = [:]) -> [String] {
        let map = SeasonLabels.labels(seasons) { refs[$0] }
        return seasons.map { map[$0.id] ?? "?" }
    }

    @Test func splitSeasonsAreNamedByTheTVDBsSeasonWithAPartEach() {
        let mushoku = [
            media(108465, "Mushoku Tensei: Jobless Reincarnation"),
            media(127720, "Mushoku Tensei: Jobless Reincarnation Cour 2"),
            media(146065, "Mushoku Tensei: Jobless Reincarnation Season 2"),
            media(166873, "Mushoku Tensei: Jobless Reincarnation Season 2 Part 2"),
            media(178789, "Mushoku Tensei: Jobless Reincarnation Season 3"),
        ]
        let refs: [Int: TVDBRef] = [108465: .init(id: 371310, season: 1), 127720: .init(id: 371310, season: 1),
                                    146065: .init(id: 371310, season: 2), 166873: .init(id: 371310, season: 2),
                                    178789: .init(id: 371310, season: 3)]
        #expect(labels(mushoku, refs) == ["Season 1 Part 1", "Season 1 Part 2", "Season 2 Part 1", "Season 2 Part 2", "Season 3"])
    }

    @Test func theTVDBNamesSeasonsTheTitlesDontNumber() {
        let stone = [media(105333, "Dr. STONE"), media(113936, "Dr. STONE: STONE WARS"),
                     media(131518, "Dr. STONE New World"), media(162670, "Dr. STONE New World Part 2")]
        let refs: [Int: TVDBRef] = [105333: .init(id: 355774, season: 1), 113936: .init(id: 355774, season: 2),
                                    131518: .init(id: 355774, season: 3), 162670: .init(id: 355774, season: 3)]
        #expect(labels(stone, refs) == ["Season 1", "Season 2", "Season 3 Part 1", "Season 3 Part 2"])
    }

    @Test func oneSeasonInSeveralPartsIsNamedByPartAlone() {
        let tybw = [media(116674, "BLEACH: Thousand-Year Blood War"),
                    media(159322, "BLEACH: Thousand-Year Blood War - The Separation"),
                    media(169755, "BLEACH: Thousand-Year Blood War - The Conflict")]
        let refs = Dictionary(uniqueKeysWithValues: tybw.map { ($0.id, TVDBRef(id: 74796, season: 17)) })
        #expect(labels(tybw, refs) == ["Part 1", "Part 2", "Part 3"])
    }

    @Test func withoutTheTVDBTheTitlesDecide() {
        let slime = [media(101280, "That Time I Got Reincarnated as a Slime"),
                     media(108511, "That Time I Got Reincarnated as a Slime Season 2"),
                     media(116742, "That Time I Got Reincarnated as a Slime Season 2 Part 2"),
                     media(156822, nil, romaji: "Tensei Shitara Slime Datta Ken 3rd Season")]
        #expect(labels(slime) == ["Season 1", "Season 2 Part 1", "Season 2 Part 2", "Season 3"])
        let spy = [media(140960, "SPY x FAMILY"), media(142838, "SPY x FAMILY Cour 2"), media(158927, "SPY x FAMILY Season 2")]
        #expect(labels(spy) == ["Season 1 Part 1", "Season 1 Part 2", "Season 2"])
    }

    @Test func theTVDBOnlyCountsWhenItPlacesEveryEntryInOneSeries() {
        let seasons = [media(1, "Show"), media(2, "Show Season 2"), media(3, "Show Season 2 Part 2")]
        let partial: [Int: TVDBRef] = [1: .init(id: 10, season: 1), 2: .init(id: 10, season: 2)]
        #expect(labels(seasons, partial) == ["Season 1", "Season 2 Part 1", "Season 2 Part 2"])
        let mixed: [Int: TVDBRef] = [1: .init(id: 10, season: 1), 2: .init(id: 11, season: 1), 3: .init(id: 11, season: 1)]
        #expect(labels(seasons, mixed) == ["Season 1", "Season 2 Part 1", "Season 2 Part 2"])
        #expect(labels([media(1, "Show"), media(2, "Show: The Next Arc"), media(3, "Show: Final Arc")]) == ["Season 1", "Season 2", "Season 3"])
    }

    // MARK: - Chain

    private let s1 = Media(id: 1, title: .init(romaji: "Show"))
    private let s2 = Media(id: 2, title: .init(romaji: "Show 2nd Season"))
    private let s3 = Media(id: 3, title: .init(romaji: "Show 3rd Season"))
    private let movie = Media(id: 4, title: .init(romaji: "Show: The Movie"))
    private let spinOff = Media(id: 5, title: .init(romaji: "Other Show"))

    private func chain(_ refs: [Int: TVDBRef], info: Media? = nil, series: [Media]) -> [Int]? {
        SeasonLabels.chain(info ?? s1, series: series) { refs[$0] }?.map(\.id)
    }

    @Test func theChainKeepsOneSeriesNumberedRunInSeasonOrder() {
        #expect(chain([1: .init(id: 100, season: 1), 2: .init(id: 100, season: 2), 3: .init(id: 100, season: 3)], series: [s3, s1, s2]) == [1, 2, 3])
        #expect(chain([1: .init(id: 100, season: 1), 2: .init(id: 100, season: 2), 5: .init(id: 200, season: 1)], series: [s1, s2, spinOff]) == [1, 2])
        #expect(chain([1: .init(id: 100, season: 1), 2: .init(id: 100, season: 2), 4: .init(id: 100, season: 0)], series: [s1, s2, movie]) == [1, 2])
    }

    @Test func theChainDeclinesWhenItCantPlaceThePage() {
        #expect(chain([2: .init(id: 100, season: 2)], series: [s1, s2]) == nil)
        #expect(chain([1: .init(id: 100, season: nil)], series: [s1, s2]) == nil)
        #expect(chain([1: .init(id: 100, season: 1)], series: [s1]) == nil)
        #expect(chain([1: .init(id: 100, season: 1), 2: .init(id: 200, season: 1), 3: .init(id: 200, season: 2)], series: [s2, s3]) == nil)
    }

    @Test func theBundledMapParses() {
        let refs = TVDBRef.parse("# header\n108465,371310,1\n5,76885,0\nbad,line\n")
        #expect(refs == [108465: .init(id: 371310, season: 1), 5: .init(id: 76885, season: 0)])
    }

    @Test func upcomingSeasonsShowButOnlyTheirOwnPageChoosesThem() {
        var next = Media(id: 9, title: .init(english: "Show Season 3"))
        next.status = "NOT_YET_RELEASED"
        #expect(SeasonLabels.isUpcoming(next))
        #expect(!SeasonLabels.choosable(next, selected: 1))
        #expect(SeasonLabels.choosable(next, selected: 9))
    }
}
