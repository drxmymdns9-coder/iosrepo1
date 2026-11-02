import Foundation
import Testing
@testable import AnililiCore

struct WatchHistoryTests {
    private func show(episodes: Int? = 12, nextAiring: Int? = nil) -> Media {
        var media = Media(id: 7, title: .init(english: "Test"))
        media.episodes = episodes
        media.status = nextAiring == nil ? "FINISHED" : "RELEASING"
        media.nextAiringEpisode = nextAiring.map { .init(episode: $0, airingAt: 0) }
        return media
    }

    @Test func resumesMidEpisodeButRestartsFinishedAndBarelyStartedOnes() {
        var history = WatchHistory()
        history.record(show(), episode: 1, position: 600, duration: 1440)
        history.record(show(), episode: 2, position: 1400, duration: 1440)
        history.record(show(), episode: 3, position: 4, duration: 1440)

        #expect(history.resumePosition(mediaID: 7, episode: 1) == 600)
        #expect(history.resumePosition(mediaID: 7, episode: 2) == 0)
        #expect(history.resumePosition(mediaID: 7, episode: 3) == 0)
        #expect(history.resumePosition(mediaID: 7, episode: 4) == 0)
    }

    @Test func continueWatchingMovesOnAfterAFinishedEpisode() {
        var history = WatchHistory()
        history.record(show(), episode: 4, position: 1400, duration: 1440)
        #expect(history.shows[7]?.resumeEpisode == 5)

        history.record(show(), episode: 5, position: 300, duration: 1440)
        #expect(history.shows[7]?.resumeEpisode == 5)
    }

    @Test func theLastReleasedEpisodeStaysPutWhenFinished() {
        var history = WatchHistory()
        // Airing: episode 6 is next, so 5 is the newest out.
        history.record(show(episodes: nil, nextAiring: 6), episode: 5, position: 1400, duration: 1440)
        #expect(history.shows[7]?.resumeEpisode == 5)
    }

    @Test func mostRecentFirstAndRoundTripsThroughJSON() throws {
        var history = WatchHistory()
        var other = show()
        other.id = 8
        history.record(show(), episode: 1, position: 60, duration: 1440, at: Date(timeIntervalSince1970: 100))
        history.record(other, episode: 1, position: 60, duration: 1440, at: Date(timeIntervalSince1970: 200))

        #expect(history.continueWatching.map(\.media.id) == [8, 7])
        let decoded = try JSONDecoder().decode(WatchHistory.self, from: JSONEncoder().encode(history))
        #expect(decoded == history)
    }

    @Test func ignoresAnUnknownDuration() {
        var history = WatchHistory()
        history.record(show(), episode: 1, position: 10, duration: .nan)
        #expect(history.shows.isEmpty)
    }

    @Test func watchedFilterSeparatesStartedFromCompleted() {
        var history = WatchHistory()
        var done = show()
        done.id = 1
        var going = show()
        going.id = 2
        history.record(done, episode: 12, position: 1400, duration: 1440)
        history.record(going, episode: 3, position: 600, duration: 1440)

        #expect(history.watchedIDs(.off).isEmpty)
        #expect(history.watchedIDs(.started) == [1, 2])
        #expect(history.watchedIDs(.completed) == [1])
    }

    @Test func theEpisodeEyeMarksAndClears() {
        var history = WatchHistory()
        history.setWatched(show(), episode: 3, true)
        #expect(history.isWatched(mediaID: 7, episode: 3))
        #expect(history.shows[7]?.resumeEpisode == 4)
        history.setWatched(show(), episode: 1, true)
        #expect(history.shows[7]?.lastEpisode == 3, "filling a gap doesn't move you back")
        history.setWatched(show(), episode: 3, false)
        #expect(!history.isWatched(mediaID: 7, episode: 3))
        #expect(history.shows[7]?.lastEpisode == 1)
        history.setWatched(show(), episode: 1, false)
        #expect(history.shows[7] == nil)
    }
}
