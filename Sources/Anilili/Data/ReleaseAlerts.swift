#if canImport(UIKit)
import AnililiCore
import Foundation
import UserNotifications

/// "Episode 7 is out" for the shows you follow (Android's `ReleaseSyncScheduler`, setting
/// `release_notifications`): saved shows, ones in progress, and the account's Watching and Plan
/// to watch. iOS can't poll in the background reliably, so each refresh schedules local
/// notifications for the next air times AniList knows; opening the app keeps them current.
@MainActor
enum ReleaseAlerts {
    static let key = "release_notifications"
    private static let prefix = "release:"
    private static let lastRunKey = "ios_release_alerts_last_run"
    /// iOS keeps 64 pending notifications per app; episode reminders need room too.
    private static let limit = 40
    private static let horizon: TimeInterval = 14 * 24 * 3600

    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// At most hourly, unless forced.
    static func refreshIfStale(library: LibraryStore) {
        let last = UserDefaults.standard.double(forKey: lastRunKey)
        guard Date().timeIntervalSince1970 - last > 3600 else { return }
        Task { await refresh(library: library) }
    }

    static func refresh(library: LibraryStore) async {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRunKey)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        guard enabled else {
            center.removePendingNotificationRequests(withIdentifiers: pending)
            return
        }
        var ids = Set(library.watchlist.items.map(\.id))
        ids.formUnion(library.history.continueWatching.filter { !$0.isCompleted }.map(\.media.id))
        let account = AccountStore.shared.library
        ids.formUnion(account.entries(.current).map(\.media.id) + account.entries(.planning).map(\.media.id) + account.entries(.repeating).map(\.media.id))
        ids = ids.filter { $0 > 0 }
        guard !ids.isEmpty else {
            center.removePendingNotificationRequests(withIdentifiers: pending)
            return
        }
        do {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else { return }
            } else if settings.authorizationStatus == .denied {
                Log.info("release", "notifications are off for Anilili in iOS Settings")
                return
            }
            let media = try await AniListClient.shared.media(ids: Array(ids))
            let now = Date()
            let upcoming = media
                .compactMap { item -> (Media, Media.NextAiring)? in item.nextAiringEpisode.map { (item, $0) } }
                .filter { $0.1.date > now && $0.1.date.timeIntervalSince(now) < horizon }
                .sorted { $0.1.date < $1.1.date }
                .prefix(limit)
            var wanted = Set<String>()
            for (show, next) in upcoming {
                let id = "\(prefix)\(show.id):\(next.episode)"
                wanted.insert(id)
                guard !pending.contains(id) else { continue }
                let content = UNMutableNotificationContent()
                content.title = show.title.preferred
                content.body = "Episode \(next.episode) is out"
                content.sound = .default
                content.userInfo = ["anilistId": show.id, "episode": next.episode]
                content.threadIdentifier = "release-\(show.id)"
                // Streams appear a little after broadcast; five minutes gives the servers a head start.
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, next.date.timeIntervalSince(now) + 300), repeats: false)
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { !wanted.contains($0) })
            Log.info("release", "\(wanted.count) release alerts for \(ids.count) followed shows")
        } catch {
            Log.error("release", "couldn't schedule release alerts: \(Log.describe(error))")
        }
    }
}
#endif
