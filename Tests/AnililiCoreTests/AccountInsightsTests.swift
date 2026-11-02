import Foundation
import Testing
@testable import AnililiCore

/// Android's `accountInsights` and `WatchActivityStore` helpers.
struct AccountInsightsTests {
    private func media(_ id: Int, genres: [String] = [], format: String? = "TV", year: Int? = nil, episodes: Int? = nil) -> Media {
        var media = Media(id: id, title: .init(english: "Show \(id)"))
        media.genres = genres
        media.format = format
        media.seasonYear = year
        media.episodes = episodes
        return media
    }

    private func entry(_ media: Media, _ status: ListStatus, progress: Int = 0, score: Double = 0, updated: TimeInterval = 0) -> ListEntry {
        ListEntry(entryID: media.id, media: media, status: status, progress: progress, score: score,
                  updatedAt: Date(timeIntervalSince1970: updated), hiddenFromStatusLists: false, customLists: [])
    }

    @Test func countsGenresAndRatesComeFromTheLists() {
        let library = AccountLibrary(entries: [
            entry(media(1, genres: ["Action", "Drama"], year: 2020, episodes: 12), .current, progress: 4, score: 8, updated: 300),
            entry(media(2, genres: ["Action"], format: "MOVIE", year: 2022), .completed, score: 9.4, updated: 100),
            entry(media(3, genres: ["Romance"], year: 2021), .planning, updated: 200),
            entry(media(4, genres: ["Drama"], year: 2020), .dropped),
            entry(media(5, year: 2020, episodes: 10), .repeating, progress: 3),
        ], customListNames: [])
        let insights = AccountInsights(profile: nil, library: library)
        #expect(insights.count(.watching) == 2)
        #expect(insights.count(.planning) == 1)
        #expect(insights.titles == 5)
        #expect(insights.episodes == 7)
        // Planning doesn't vote: Romance only appears when nothing has been started.
        #expect(insights.topGenres.map(\.label) == ["Action", "Drama"])
        #expect(insights.formats.map(\.label) == ["TV", "Movie"])
        #expect(insights.releaseYears.map(\.label) == ["\u{2019}20", "\u{2019}21", "\u{2019}22"])
        #expect(insights.releaseYears.map(\.count) == [3, 1, 1])
        #expect(insights.scoreSpread[7].count == 1 && insights.scoreSpread[8].count == 1)
        #expect(insights.completionRate == 50)
        #expect(insights.episodesToGo == 8 + 7)
        #expect(insights.recent.map(\.media.id) == [1, 3, 2])
        #expect(insights.meanScore == nil)
    }

    @Test func theAccountsOwnTotalsWinWhenItHasThem() {
        let profile = AccountProfile(id: 1, name: "x", animeCount: 300, episodesWatched: 4000, minutesWatched: 90_000, meanScore: 7.6)
        let insights = AccountInsights(profile: profile, library: AccountLibrary(entries: [], customListNames: []))
        #expect(insights.titles == 300 && insights.episodes == 4000 && insights.meanScore == 7.6)
        #expect(insights.completionRate == nil && insights.scoreSpread.isEmpty && insights.releaseYears.isEmpty)
    }

    @Test func aLongListCountsByDecade() {
        let library = AccountLibrary(entries: [entry(media(1, year: 1995), .completed), entry(media(2, year: 2014), .completed)], customListNames: [])
        #expect(AccountInsights(profile: nil, library: library).releaseYears.map(\.label) == ["90s", "00s", "10s"])
    }

    @Test func labels() {
        #expect(AccountInsights.statWatchTime(63_720) == "1,062 h")
        #expect(AccountInsights.statWatchTime(125) == "2h 5m")
        #expect(AccountInsights.watchTimeLabel(45) == "45m")
        #expect(AccountInsights.watchTimeLabel(120) == "2h")
        #expect(AccountInsights.grouped(1_234_567) == "1,234,567")
        #expect(AccountInsights.profileURL(.anilist, name: "lili")?.absoluteString == "https://anilist.co/user/lili/")
        #expect(AccountInsights.profileURL(.mal, name: "lili")?.absoluteString == "https://myanimelist.net/profile/lili")
    }

    @Test func activityMergesStreaksAndLevels() {
        #expect(WatchActivity.merged([1: 2, 2: 1], [2: 3, 3: 0]) == [1: 2, 2: 3])
        #expect(WatchActivity.streak([10: 1, 9: 2, 7: 1], today: 10) == 2)
        // Nothing yet today: the streak still stands on yesterday.
        #expect(WatchActivity.streak([9: 1, 8: 1], today: 10) == 2)
        #expect(WatchActivity.streak([8: 1], today: 10) == 0)
        #expect(WatchActivity.level(0, max: 5) == 0)
        #expect(WatchActivity.level(1, max: 8) == 1)
        #expect(WatchActivity.level(8, max: 8) == 4)
        #expect(WatchActivity.recording([1: 1], on: 500) == [500: 1])
        #expect(WatchActivity.recording([450: 1], on: 500) == [450: 1, 500: 1])
        #expect(WatchActivity.weekday(0) == 3)  // 1970-01-01, a Thursday
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(WatchActivity.day(Date(timeIntervalSince1970: 86_400 * 3 + 100), calendar: utc) == 3)
        #expect(AniListClient.activityDays([(86_400 * 5, 2), (86_400 * 6, 0), (nil, 3)]) == [5: 2])
    }
}
