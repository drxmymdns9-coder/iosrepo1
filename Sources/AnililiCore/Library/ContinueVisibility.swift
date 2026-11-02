import Foundation

/// Settings → Content → Only episodes you can watch (Android's `ContinueWatchingVisibility`):
/// Continue Watching steps aside for a title caught up with its broadcast, and the row comes back
/// on its own once the next episode can be played.
///
/// Hidden, never removed: nothing is written, and the account never hears about it.
public enum ContinueVisibility {
    public static let key = "hide_airing_tomorrow_from_continue"

    /// AniList ids to their episodes airing around now, with each one's broadcast time.
    public typealias Upcoming = [Int: [Int: Date]]

    /// An episode is on the servers about two hours after it airs (Android's
    /// `EPISODE_WATCHABLE_AFTER_SEC`), the same bar the show page greys rows out by.
    public static let watchableAfter: TimeInterval = 2 * 60 * 60

    /// The window Home reads, starting yesterday: a weekly show's next episode, the odd skipped
    /// week, and an episode that aired late last night and isn't watchable yet.
    public static let upcomingDays = 16

    /// When a hidden row comes back, or nil when the row shows now.
    public static func returnsAt(_ show: WatchHistory.Show, upcoming: Upcoming, now: Date = Date()) -> Date? {
        let last = show.episodes[show.lastEpisode]
        // Left part-way: a place to resume, whatever the schedule says.
        if let last, !last.isFinished, last.position > 0 { return nil }
        let next = last?.isFinished == true ? show.lastEpisode + 1 : show.lastEpisode
        guard let (episode, watchableAt) = upcoming[show.media.id]?
            .map({ ($0.key, $0.value.addingTimeInterval(watchableAfter)) })
            .filter({ $0.0 >= next && now < $0.1 })
            .min(by: { $0.0 < $1.0 })
        else { return nil }
        // An earlier episode is out and unwatched: there is something to play.
        guard next >= episode else { return nil }
        return watchableAt
    }

    /// Continue Watching as Home draws it, less the rows with nothing to play yet.
    public static func visible(_ shows: [WatchHistory.Show], upcoming: Upcoming, now: Date = Date()) -> [WatchHistory.Show] {
        shows.filter { returnsAt($0, upcoming: upcoming, now: now) == nil }
    }

    /// The broadcast times of `slots` by title and episode.
    public static func upcoming(_ slots: [(mediaID: Int, episode: Int, airingAt: Date)]) -> Upcoming {
        var map: Upcoming = [:]
        for slot in slots { map[slot.mediaID, default: [:]][slot.episode] = slot.airingAt }
        return map
    }
}
