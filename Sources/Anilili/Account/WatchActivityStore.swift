#if canImport(UIKit)
import AnililiCore
import Foundation
import Observation

/// Episodes finished on this device, per day: what the account sheet's activity grid draws
/// (Android's `WatchActivityStore`). The library only knows when each title was last touched, and
/// MyAnimeList keeps no history at all, so a day is counted here as it happens. AniList's own
/// history is merged in when there is one (`WatchActivity.merged`).
@MainActor
@Observable
final class WatchActivityStore {
    static let shared = WatchActivityStore()

    private(set) var days: [Int: Int]

    @ObservationIgnored private let key = "watch_activity_days"

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        days = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    /// One episode newly finished today.
    func recordEpisode(on date: Date = Date()) {
        days = WatchActivity.recording(days, on: WatchActivity.day(date))
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: days.map { (String($0.key), $0.value) }), forKey: key)
    }
}
#endif
