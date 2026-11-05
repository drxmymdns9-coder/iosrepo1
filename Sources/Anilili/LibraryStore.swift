#if canImport(UIKit)
import AnililiCore
import Foundation
import Observation

/// The app's watch history and My List, each persisted to UserDefaults as one JSON blob.
///
/// A show's history is a few hundred bytes, so even a heavy viewer stays far below the point where
/// UserDefaults would be the wrong store.
@MainActor
@Observable
final class LibraryStore {
    private(set) var history: WatchHistory
    private(set) var watchlist: Watchlist

    @ObservationIgnored private let defaults: UserDefaults
    private static let historyKey = "watchHistory.v1"
    private static let watchlistKey = "watchlist.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = Self.load(WatchHistory.self, defaults, Self.historyKey) ?? WatchHistory()
        watchlist = Self.load(Watchlist.self, defaults, Self.watchlistKey) ?? Watchlist()
        Log.info("library", "loaded \(history.shows.count) shows in history, \(watchlist.items.count) in My List")
    }

    func record(_ media: Media, episode: Int, position: Double, duration: Double) {
        let wasWatched = history.isWatched(mediaID: media.id, episode: episode)
        history.record(media, episode: episode, position: position, duration: duration)
        save(history, Self.historyKey)
        // Past the watched threshold for the first time: the account hears about it.
        if !wasWatched, history.isWatched(mediaID: media.id, episode: episode) {
            Log.info("library", "\(media.id) episode \(episode) watched")
            WatchActivityStore.shared.recordEpisode()
            AccountStore.shared.episodeWatched(media, episode: episode)
        }
    }

    func setWatched(_ media: Media, episode: Int, _ watched: Bool) {
        history.setWatched(media, episode: episode, watched)
        save(history, Self.historyKey)
        Log.info("library", "\(media.id) episode \(episode) marked \(watched ? "watched" : "unwatched")")
        if watched { AccountStore.shared.episodeWatched(media, episode: episode) }
    }

    /// Many episodes at once (the series eye): one save, one push to the account.
    func setWatched(_ media: Media, episodes: [Int]) {
        guard let last = episodes.max() else { return }
        for episode in episodes { history.setWatched(media, episode: episode, true) }
        save(history, Self.historyKey)
        Log.info("library", "\(media.id): \(episodes.count) episodes marked watched")
        AccountStore.shared.episodeWatched(media, episode: last)
    }

    /// The account's Plan to watch merged into the device's saves (`ListSync.mergeWatchlist`).
    func mergeWatchlist(planning: [Media], knownRemoteIDs: Set<Int>, previousRemoteIDs: Set<Int>) {
        let merged = ListSync.mergeWatchlist(local: watchlist.items, planning: planning,
                                             knownRemoteIDs: knownRemoteIDs, previousRemoteIDs: previousRemoteIDs)
        guard merged.map(\.id) != watchlist.items.map(\.id) else { return }
        let dropped = Set(watchlist.items.map(\.id)).subtracting(merged.map(\.id))
        if !dropped.isEmpty { Log.info("library", "watchlist removals from the account: \(dropped.sorted())") }
        watchlist.replace(with: merged)
        save(watchlist, Self.watchlistKey)
    }

    func remove(mediaID: Int) {
        history.remove(mediaID: mediaID)
        save(history, Self.historyKey)
    }

    func clearHistory() {
        history = WatchHistory()
        save(history, Self.historyKey)
        Log.info("library", "history cleared")
    }

    func toggleWatchlist(_ media: Media) {
        let saved = watchlist.toggle(media)
        save(watchlist, Self.watchlistKey)
        Log.info("library", "\(saved ? "added to" : "removed from") My List: \(media.id) \(media.title.preferred)")
        AccountStore.shared.savedChanged(media, saved: saved)
    }

    func removeFromWatchlist(mediaID: Int) {
        let media = watchlist.items.first { $0.id == mediaID }
        watchlist.remove(mediaID: mediaID)
        save(watchlist, Self.watchlistKey)
        if let media { AccountStore.shared.savedChanged(media, saved: false) }
    }

    // MARK: - Restore

    /// Rows from a backup, merged (the newer row wins). Returns how many changed.
    func restoreHistory(_ shows: [WatchHistory.Show]) -> Int {
        var changed = 0
        for show in shows where history.restore(show) { changed += 1 }
        if changed > 0 { save(history, Self.historyKey) }
        return changed
    }

    /// Saves from a backup that this device doesn't have yet, first (Android's `importWatchlist`).
    func importWatchlist(_ media: [Media]) -> Int {
        var seen = Set(watchlist.items.map(\.id))
        let fresh = media.filter { seen.insert($0.id).inserted }
        guard !fresh.isEmpty else { return 0 }
        watchlist.replace(with: fresh + watchlist.items)
        save(watchlist, Self.watchlistKey)
        Task { await AccountStore.shared.pushWatchlist() }
        return fresh.count
    }

    private static func load<T: Decodable>(_ type: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Starting empty beats crashing, but the reason belongs in the log.
            Log.error("library", "couldn't read \(key) (\(data.count)B): \(error)")
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            Log.error("library", "couldn't save \(key): \(error)")
        }
    }
}

/// UserDefaults keys, the Android app's own (`SettingsStore.kt`), so a backup restores the same
/// choices on either app. Defaults are Android's.
enum Setting {
    static let preferDub = "prefer_dub"                       // false
    static let autoplay = "autoplay"                          // true: autoplay the next episode
    static let playOnOpen = "play_on_open"                    // true
    static let autoSkipIntroOutro = "auto_skip_intro_outro"   // false
    static let showSkipButton = "show_skip_button"            // true
    static let hideAdult = "hide_adult_content"               // true
    static let searchAsYouType = "search_as_you_type"         // true
    static let pictureInPicture = "picture_in_picture"        // true
    static let showPlayerDebug = "ios_player_debug_overlay"   // false; iOS only
    static let autoSyncProgress = "auto_sync_anilist"         // true: finished episodes update the account
    static let syncSaved = "sync_saved_to_anilist"            // true: watchlist ↔ Plan to watch
    static let openInExternalPlayer = "open_episodes_in_external_player" // false
    static let externalPlayer = "external_player_package"     // "": ask every time (see ExternalPlayer)
    static let videoEngine = "video_engine_v2"                // automatic, avplayer, vlc, ask; defaults to ask
    static let pauseDetailsOverlay = "pause_details_overlay"  // true
    static let playerContentScale = "player_content_scale"    // "fit" (Android's fit/crop/fill)
    static let playerClock = "player_clock"                   // true
    static let holdToSpeed = "hold_to_speed_enabled"          // true
    static let playerGestures = "player_gestures"             // true
    static let playerSeekGesture = "player_seek_gesture"      // true
    static let playerStatusBar = "player_status_bar"          // true
    static let hiddenMALTags = "hidden_mal_tags"              // "": comma-separated, shown on MAL, not My List
}

/// Settings read outside a view, with Android's defaults.
enum ContentSettings {
    static var hideAdult: Bool { UserDefaults.standard.object(forKey: Setting.hideAdult) as? Bool ?? true }
}

enum PlaybackSettings {
    static var preferredAudio: AudioTrack { UserDefaults.standard.bool(forKey: Setting.preferDub) ? .dub : .sub }
}
#endif
