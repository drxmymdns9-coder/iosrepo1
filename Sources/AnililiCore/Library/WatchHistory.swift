import Foundation

/// Where the viewer is in every show they have started, keyed by AniList id.
///
/// A value type so the app can hold it in an observable store and persist it as one JSON blob;
/// the rules for what counts as finished and what to resume live here, where they are tested.
public struct WatchHistory: Codable, Equatable, Sendable {
    public struct Progress: Codable, Equatable, Sendable {
        public var position: Double
        public var duration: Double
        public var updatedAt: Date

        public init(position: Double, duration: Double, updatedAt: Date) {
            self.position = position
            self.duration = duration
            self.updatedAt = updatedAt
        }

        public var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }

        /// Watched, at Settings' "Watched at" threshold (80% unless changed): the rest is the
        /// ending and preview on nearly every TV episode, so a viewer who stops there has seen it.
        public var isFinished: Bool { duration > 0 && position >= duration * WatchHistory.watchedThreshold }
    }

    public struct Show: Codable, Equatable, Sendable {
        public var media: Media
        public var episodes: [Int: Progress]
        public var lastEpisode: Int
        public var updatedAt: Date

        public init(media: Media, episodes: [Int: Progress] = [:], lastEpisode: Int, updatedAt: Date) {
            self.media = media
            self.episodes = episodes
            self.lastEpisode = lastEpisode
            self.updatedAt = updatedAt
        }

        /// Every planned episode is out and the last one was watched past the credits.
        public var isCompleted: Bool {
            guard let total = media.episodes, total > 0, media.status == "FINISHED" || media.nextAiringEpisode == nil else { return false }
            return episodes.contains { $0.key >= total && $0.value.isFinished }
        }

        /// The episode to open from Continue Watching: the last one, unless it was finished, in
        /// which case the one after it.
        public var resumeEpisode: Int {
            guard let last = episodes[lastEpisode], last.isFinished else { return lastEpisode }
            if let released = media.releasedEpisodes, lastEpisode >= released { return lastEpisode }
            return lastEpisode + 1
        }
    }

    public private(set) var shows: [Int: Show] = [:]

    /// Settings → Player → Watched at (Android's `watched_threshold_percent`, 80% by default), as
    /// a fraction. Read each time so a change applies at once, as it does on Android.
    public static var watchedThreshold: Double {
        let stored = UserDefaults.standard.object(forKey: PlayerLimits.watchedThresholdKey) as? Int
        return Double(PlayerLimits.watchedPercent(stored)) / 100
    }

    public init() {}

    public mutating func record(_ media: Media, episode: Int, position: Double, duration: Double, at date: Date = Date()) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        var show = shows[media.id] ?? Show(media: media, episodes: [:], lastEpisode: episode, updatedAt: date)
        show.media = media
        show.episodes[episode] = Progress(position: position, duration: duration, updatedAt: date)
        show.lastEpisode = episode
        show.updatedAt = date
        shows[media.id] = show
    }

    /// The episode eye on a show page: marks an episode watched (past the credits) or clears it.
    /// Marking moves Continue Watching on when it's the furthest episode; clearing the last mark
    /// takes the show off the row.
    public mutating func setWatched(_ media: Media, episode: Int, _ watched: Bool, at date: Date = Date()) {
        if watched {
            var show = shows[media.id] ?? Show(media: media, episodes: [:], lastEpisode: episode, updatedAt: date)
            show.media = media
            show.episodes[episode] = Progress(position: 1, duration: 1, updatedAt: date)
            if episode >= show.lastEpisode || show.episodes[show.lastEpisode]?.isFinished == true {
                show.lastEpisode = max(show.lastEpisode, episode)
            }
            show.updatedAt = date
            shows[media.id] = show
        } else if var show = shows[media.id] {
            show.episodes[episode] = nil
            if show.episodes.isEmpty {
                shows[media.id] = nil
                return
            }
            if show.lastEpisode == episode { show.lastEpisode = show.episodes.keys.max() ?? episode }
            shows[media.id] = show
        }
    }

    public func isWatched(mediaID: Int, episode: Int) -> Bool {
        progress(mediaID: mediaID, episode: episode)?.isFinished == true
    }

    public mutating func remove(mediaID: Int) {
        shows[mediaID] = nil
    }

    /// Puts a whole row in place (a restore; see `restore`).
    mutating func insert(_ show: Show) {
        shows[show.media.id] = show
    }

    public func progress(mediaID: Int, episode: Int) -> Progress? {
        shows[mediaID]?.episodes[episode]
    }

    /// Where to start `episode`: the saved position, unless it is finished or barely begun, where
    /// starting over is what the viewer wants.
    public func resumePosition(mediaID: Int, episode: Int) -> Double {
        guard let saved = progress(mediaID: mediaID, episode: episode),
              !saved.isFinished, saved.position >= 10 else { return 0 }
        return saved.position
    }

    /// Most recently watched first.
    public var continueWatching: [Show] {
        shows.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Titles Browse's "hide watched" leaves out: every one started, or only those finished
    /// (the last planned episode watched past the credits).
    public func watchedIDs(_ filter: WatchedFilter) -> Set<Int> {
        switch filter {
        case .off: return []
        case .started: return Set(shows.keys)
        case .completed: return Set(shows.values.filter(\.isCompleted).map(\.media.id))
        }
    }
}
