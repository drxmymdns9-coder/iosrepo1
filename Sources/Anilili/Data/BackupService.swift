#if canImport(UIKit)
import AnililiCore
import Foundation

/// Writes and restores Android's backup file (`BackupManager.kt`): settings under Android's keys,
/// the device's watchlist and Continue Watching, search history, and optionally the AniList login
/// sealed under a passphrase. A file from either app restores on the other.
@MainActor
enum BackupService {
    /// Every setting that travels: the ones the iOS app keeps, all under Android's names.
    static var settingKeys: [String] {
        AppearanceStore.keys + [
            Setting.preferDub, Setting.autoplay, Setting.playOnOpen, Setting.autoSkipIntroOutro, Setting.showSkipButton,
            Setting.hideAdult, Setting.searchAsYouType, Setting.pictureInPicture, Setting.autoSyncProgress, Setting.syncSaved,
            "default_playback_speed", "episode_layout", "episode_order", "disabled_providers", "server_priority", "release_notifications",
            "hold_playback_speed", "hold_to_speed_enabled", "player_clock", "player_content_scale", "player_gestures",
            "player_seek_gesture", "preferred_subtitle_language", "related_layout", "schedule_calendar_view",
            "subtitles_by_default", "subtitles_with_dub", "watch_order_story", DownloadStore.qualityKey, AppIconSync.key, AnnouncementCenter.key,
            Setting.openInExternalPlayer, Setting.externalPlayer, Setting.pauseDetailsOverlay, Setting.playerStatusBar,
            Setting.hiddenMALTags, PlayerLimits.skipButtonKey, PlayerLimits.watchedThresholdKey, DefaultQuality.key,
            PlaybackBufferSize.key, TrackLanguage.audioKey, TrackLanguage.secondaryAudioKey, TrackLanguage.secondarySubtitleKey,
            ContinueVisibility.key, MenuLanguage.key, UpdateCenter.checkOnLaunchKey,
        ] + CaptionKey.all
    }

    static func document(library: LibraryStore, passphrase: String?) throws -> BackupDocument {
        var document = BackupDocument()
        document.createdAt = Int64(Date().timeIntervalSince1970 * 1000)
        document.appVersion = "iOS \(AppInfo.version)"
        let defaults = UserDefaults.standard
        for key in settingKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            switch value {
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): document.settings[key] = .bool(number.boolValue)
            case let number as NSNumber: document.settings[key] = .number(number.doubleValue)
            case let text as String: document.settings[key] = .string(text)
            default: continue
            }
        }
        document.watchlist = BackupLibrary.watchlistEntries(library.watchlist)
        document.history = BackupLibrary.historyEntries(library.history, preferDub: defaults.bool(forKey: Setting.preferDub))
        document.searchHistory = SearchHistory.entries
        if let passphrase, let token = AccountCredentials.shared.anilistToken {
            try document.seal(BackupDocument.Credentials(aniListToken: token), passphrase: passphrase)
        }
        Log.info("backup", "made: \(document.summary)")
        return document
    }

    struct Summary {
        var settings = 0
        var watchlist = 0
        var history = 0
        var searches = 0
        var logins = 0
        var warnings: [String] = []

        var text: String {
            BackupDocument.describe(settings: settings, watchlist: watchlist, history: history, searches: searches, logins: logins, lists: 0)
        }
    }

    /// Makes this device's settings the file's (keys the file lacks go back to their defaults, as
    /// on Android), merges the library, and signs in when the logins open.
    static func restore(_ document: BackupDocument, passphrase: String?, library: LibraryStore) async throws -> Summary {
        var summary = Summary()
        let defaults = UserDefaults.standard
        for key in settingKeys { defaults.removeObject(forKey: key) }
        for key in settingKeys {
            switch document.settings[key] {
            case .bool(let value)?: defaults.set(value, forKey: key)
            case .number(let value)?: defaults.set(value, forKey: key)
            case .string(let value)?: defaults.set(value, forKey: key)
            default: continue
            }
            summary.settings += 1
        }
        AppearanceStore.shared.reload()

        summary.watchlist = library.importWatchlist(document.watchlist.map {
            BackupLibrary.media(id: $0.anilistId, title: $0.title, cover: $0.cover, format: $0.format, averageScore: $0.averageScore)
        })
        summary.history = library.restoreHistory(document.history.compactMap(BackupLibrary.show))
        for query in document.searchHistory.reversed() { SearchHistory.add(query) }
        summary.searches = document.searchHistory.count
        if !document.customLists.isEmpty {
            summary.warnings.append("\(document.customLists.count) device-only list\(document.customLists.count == 1 ? "" : "s") from Android can't be kept on iOS yet; lists on your AniList account show up once you sign in.")
        }

        if let passphrase, document.credentials != nil {
            let credentials = try document.openCredentials(passphrase: passphrase)
            if let token = credentials?.aniListToken?.nonBlank {
                if AniListAuth.isExpired(token) {
                    summary.warnings.append("The AniList login in that backup has expired. Sign in again from Settings → Accounts.")
                } else {
                    await AccountStore.shared.signInAniList(token: token)
                    summary.logins += 1
                }
            } else if let credentials, credentials.hasMALHandoff, let code = credentials.malCode, let verifier = credentials.malVerifier {
                do {
                    try await AccountStore.shared.signInMAL(code: code, verifier: verifier)
                    summary.logins += 1
                } catch {
                    summary.warnings.append("MyAnimeList refused the login in that backup (its one-time code may have expired). Sign in again from Settings → Accounts.")
                }
            }
            if credentials?.hasOpenSubtitles == true {
                summary.warnings.append("OpenSubtitles isn't on iOS yet, so its login was left out.")
            }
        }
        Log.info("backup", "restored: \(summary.text)\(summary.warnings.isEmpty ? "" : "; " + summary.warnings.joined(separator: " "))")
        return summary
    }
}
#endif
