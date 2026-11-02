import Foundation

/// The device library in Android's backup shapes and back. iOS keeps whole-numbered episodes
/// with a position each; Android keeps a row per show with its current episode, the watched set
/// and resume points. Specials ("7.5") have no place on iOS and are left out of a restore.
public enum BackupLibrary {
    // MARK: - iOS → Android

    public static func historyEntries(_ history: WatchHistory, preferDub: Bool) -> [BackupDocument.HistoryEntry] {
        history.continueWatching.map { show in
            let current = show.episodes[show.lastEpisode]
            let watched = show.episodes.filter { $0.value.isFinished }.keys.sorted().map(Double.init)
            var resume: [String: BackupDocument.EpisodeResume] = [:]
            for (episode, progress) in show.episodes where !progress.isFinished && progress.position > 0 {
                resume[String(episode)] = .init(positionMs: milliseconds(progress.position), durationMs: milliseconds(progress.duration))
            }
            return BackupDocument.HistoryEntry(
                anilistId: show.media.id, title: show.media.title.preferred, cover: show.media.coverImage?.card?.absoluteString,
                episodeNumber: Double(show.lastEpisode), category: preferDub ? "dub" : "sub",
                positionMs: current.map { milliseconds($0.position) } ?? 0, durationMs: current.map { milliseconds($0.duration) } ?? 0,
                updatedAt: Int64(show.updatedAt.timeIntervalSince1970 * 1000), watchedEpisodes: watched, resumePoints: resume
            )
        }
    }

    public static func watchlistEntries(_ watchlist: Watchlist) -> [BackupDocument.WatchlistEntry] {
        watchlist.items.map { media in
            BackupDocument.WatchlistEntry(anilistId: media.id, title: media.title.preferred, cover: media.coverImage?.card?.absoluteString,
                                          format: media.format, averageScore: media.averageScore)
        }
    }

    // MARK: - Android → iOS

    public static func media(id: Int, title: String, cover: String?, format: String? = nil, averageScore: Int? = nil) -> Media {
        var media = Media(id: id, title: Media.Title(romaji: title.nonBlank, userPreferred: title.nonBlank))
        media.coverImage = cover.map { Media.CoverImage(large: $0) }
        media.format = format
        media.averageScore = averageScore
        return media
    }

    public static func show(_ entry: BackupDocument.HistoryEntry) -> WatchHistory.Show? {
        guard entry.anilistId > 0 else { return nil }
        let updated = Date(timeIntervalSince1970: TimeInterval(entry.updatedAt) / 1000)
        var episodes: [Int: WatchHistory.Progress] = [:]
        for watched in entry.watchedEpisodes where watched.rounded() == watched && watched >= 1 {
            episodes[Int(watched)] = WatchHistory.Progress(position: 1, duration: 1, updatedAt: updated)
        }
        for (key, resume) in entry.resumePoints {
            guard let episode = Int(key), resume.positionMs > 0, resume.durationMs > 0, episodes[episode] == nil else { continue }
            episodes[episode] = WatchHistory.Progress(position: seconds(resume.positionMs), duration: seconds(resume.durationMs), updatedAt: updated)
        }
        let isWhole = entry.episodeNumber.rounded() == entry.episodeNumber && entry.episodeNumber >= 1
        if isWhole, entry.positionMs > 0, entry.durationMs > 0, episodes[Int(entry.episodeNumber)] == nil {
            episodes[Int(entry.episodeNumber)] = WatchHistory.Progress(position: seconds(entry.positionMs), duration: seconds(entry.durationMs), updatedAt: updated)
        }
        let last = isWhole ? Int(entry.episodeNumber) : (episodes.keys.max() ?? Int(entry.episodeNumber.rounded(.down)))
        guard last >= 1 else { return nil }
        return WatchHistory.Show(media: media(id: entry.anilistId, title: entry.title, cover: entry.cover),
                                 episodes: episodes, lastEpisode: last, updatedAt: updated)
    }

    static func milliseconds(_ seconds: Double) -> Int64 { seconds.isFinite ? Int64((seconds * 1000).rounded()) : 0 }
    static func seconds(_ milliseconds: Int64) -> Double { Double(milliseconds) / 1000 }
}

extension WatchHistory {
    /// A restored row, merged as Android merges them: the more recently updated of the two wins,
    /// and the episodes either side watched stay watched. Returns whether anything changed.
    @discardableResult
    public mutating func restore(_ show: Show) -> Bool {
        guard let existing = shows[show.media.id] else {
            insert(show)
            return true
        }
        let newer = show.updatedAt > existing.updatedAt ? show : existing
        let older = newer.updatedAt == show.updatedAt ? existing : show
        var merged = newer
        if newer.media.coverImage == nil || newer.media.title.preferred.isEmpty { merged.media = older.media }
        for (episode, progress) in older.episodes where merged.episodes[episode] == nil || (progress.isFinished && merged.episodes[episode]?.isFinished != true) {
            merged.episodes[episode] = progress
        }
        guard merged != existing else { return false }
        insert(merged)
        return true
    }
}
