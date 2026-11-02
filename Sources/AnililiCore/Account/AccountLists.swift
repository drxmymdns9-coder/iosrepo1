import Foundation

/// The list service a viewer is signed in to. The app allows one at a time, as on Android
/// (`AccountService`); AniList wins if both somehow hold tokens.
public enum AccountService: String, Codable, Sendable, CaseIterable, Identifiable {
    case anilist, mal
    public var id: String { rawValue }
    public var label: String { self == .anilist ? "AniList" : "MyAnimeList" }
}

/// A title's place on the account's list, in AniList's vocabulary (MAL statuses are translated).
public enum ListStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case current = "CURRENT"
    case repeating = "REPEATING"
    case planning = "PLANNING"
    case paused = "PAUSED"
    case completed = "COMPLETED"
    case dropped = "DROPPED"

    public var id: String { rawValue }

    /// Android's `mediaListStatusLabel`.
    public var label: String {
        switch self {
        case .current: return "Watching"
        case .repeating: return "Rewatching"
        case .planning: return "Plan to watch"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .dropped: return "Dropped"
        }
    }

    /// The list status dialog's rows and their labels (Android's `animeListStatusOptions`).
    public static let pickerOptions: [(status: ListStatus, label: String)] = [
        (.current, "Watching"),
        (.planning, "Plan to Watch"),
        (.completed, "Completed"),
        (.paused, "On-Hold"),
        (.dropped, "Dropped"),
    ]

    public var isWatching: Bool { self == .current || self == .repeating }

    /// MAL's word for this status (`MalClient.malStatus`).
    public var malValue: String {
        switch self {
        case .current, .repeating: return "watching"
        case .completed: return "completed"
        case .paused: return "on_hold"
        case .dropped: return "dropped"
        case .planning: return "plan_to_watch"
        }
    }

    /// A MAL status in AniList's vocabulary (`MalClient.anilistStatus`).
    public init(mal status: String?, rewatching: Bool) {
        if rewatching { self = .repeating; return }
        switch status {
        case "watching": self = .current
        case "completed": self = .completed
        case "on_hold": self = .paused
        case "dropped": self = .dropped
        default: self = .planning
        }
    }
}

/// One title on the account's list.
public struct ListEntry: Codable, Hashable, Sendable, Identifiable {
    /// The service's own entry id (AniList's entry id; the MAL id on MyAnimeList).
    public var entryID: Int
    public var media: Media
    public var status: ListStatus
    public var progress: Int
    public var score: Double
    public var updatedAt: Date
    /// Filed in custom lists only: AniList's placeholder Planning status isn't a statement.
    public var hiddenFromStatusLists: Bool
    /// Custom lists on AniList, tags on MAL.
    public var customLists: [String]

    public var id: Int { media.id }

    public init(entryID: Int, media: Media, status: ListStatus, progress: Int, score: Double = 0,
                updatedAt: Date = Date(timeIntervalSince1970: 0), hiddenFromStatusLists: Bool = false, customLists: [String] = []) {
        self.entryID = entryID
        self.media = media
        self.status = status
        self.progress = progress
        self.score = score
        self.updatedAt = updatedAt
        self.hiddenFromStatusLists = hiddenFromStatusLists
        self.customLists = customLists
    }
}

/// Everything the signed-in account says about the viewer's anime.
public struct AccountLibrary: Codable, Equatable, Sendable {
    public var entries: [ListEntry]
    /// Every custom list the account has, the empty ones included (AniList only).
    public var customListNames: [String]

    public init(entries: [ListEntry], customListNames: [String] = []) {
        self.entries = entries
        self.customListNames = customListNames
    }

    public static let empty = AccountLibrary(entries: [])

    /// The entries on the status lists (custom-list-only filings left out).
    public var statusEntries: [ListEntry] { entries.filter { !$0.hiddenFromStatusLists } }

    /// Android's `remoteListStatuses`.
    public var statuses: [Int: ListStatus] {
        Dictionary(statusEntries.map { ($0.media.id, $0.status) }, uniquingKeysWith: { first, _ in first })
    }

    public func entries(_ status: ListStatus) -> [ListEntry] {
        statusEntries.filter { $0.status == status }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func entries(inCustomList name: String) -> [ListEntry] {
        entries.filter { $0.customLists.contains(name) }.sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// The viewer's own score for a title, whole points 1–10 as on Android (`AnimeScoreDialog`): MAL
/// stores nothing finer, and 0 removes the score on both services.
public enum ListScore {
    public static let points = Array((1...10).reversed())

    /// Android's `listScoreLabel`.
    public static func label(_ score: Int) -> String? {
        switch score {
        case 10: return "Masterpiece"
        case 9: return "Great"
        case 8: return "Very good"
        case 7: return "Good"
        case 6: return "Fine"
        case 5: return "Average"
        case 4: return "Bad"
        case 3: return "Very bad"
        case 2: return "Horrible"
        case 1: return "Appalling"
        default: return nil
        }
    }

    /// "8", or "7.5" for an AniList score given in half points on the website (`formatListScore`).
    public static func format(_ score: Double) -> String {
        score.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(score)) : String(format: "%.1f", score)
    }

    /// The point a score lands on, nil for a half point.
    public static func whole(_ score: Double) -> Int? {
        score.truncatingRemainder(dividingBy: 1) == 0 ? Int(score) : nil
    }

    /// AniList's `scoreRaw` is out of 100 whatever format the account displays.
    static func aniListRaw(_ score: Int) -> Int { score * 10 }
}

/// The write a finished episode makes to the account, or why it makes none.
public struct ProgressUpdate: Equatable, Sendable {
    public var progress: Int
    /// Nil keeps the entry's status.
    public var status: ListStatus?

    public init(progress: Int, status: ListStatus?) {
        self.progress = progress
        self.status = status
    }
}

/// The rules the Android app syncs by, kept as pure functions so the two apps agree.
public enum ListSync {
    /// Android's `planMediaListProgressUpdate`: never regress progress, never touch a finished
    /// entry, and keep the viewer's own Rewatching, Paused and Dropped.
    public static func planProgress(current: (status: ListStatus, progress: Int)?, watched: Int, totalEpisodes: Int?) -> ProgressUpdate? {
        if watched < 1 { return nil }
        if let current, watched <= current.progress { return nil }
        if current?.status == .completed { return nil }
        let completed = totalEpisodes.map { $0 > 0 && watched >= $0 } ?? false
        let status: ListStatus?
        switch current?.status {
        case nil, .planning?: status = completed ? .completed : .current
        case .current?: status = completed ? .completed : nil
        default: status = nil
        }
        return ProgressUpdate(progress: watched, status: status)
    }

    /// Android's `remoteRowEpisode`: the episode a Continue Watching row seeded from the account
    /// points at, or nil when there's nothing left to continue.
    public static func resumeEpisode(progress: Int, totalEpisodes: Int?, airedEpisodes: Int?) -> Int? {
        let next = progress + 1
        if let total = totalEpisodes, total > 0, next > total { return nil }
        if let aired = airedEpisodes, aired > 0, next > aired {
            let latest = min(progress, aired)
            return latest >= 1 ? latest : nil
        }
        return next
    }

    /// Android's `remoteMovesOffWatching`: titles the account moved from Watching to Completed,
    /// Dropped or Paused since the last refresh.
    public static func movesOffWatching(previous: [Int: ListStatus], current: [Int: ListStatus]) -> Set<Int> {
        Set(current.compactMap { id, status in
            [.completed, .dropped, .paused].contains(status) && previous[id]?.isWatching == true ? id : nil
        })
    }

    /// Android's `mergeWatchlistEntries`: the account's Plan to watch merged into the device's
    /// saves both ways. A save is dropped only when the account used to know the title and now
    /// doesn't know it under any status; an empty `knownRemoteIDs` is no information.
    public static func mergeWatchlist(local: [Media], planning: [Media], knownRemoteIDs: Set<Int>, previousRemoteIDs: Set<Int>) -> [Media] {
        let removable = knownRemoteIDs.isEmpty ? [] : previousRemoteIDs.subtracting(knownRemoteIDs)
        if planning.isEmpty && removable.isEmpty { return local }
        let localIDs = Set(local.map(\.id))
        var seen = Set<Int>()
        var merged: [Media] = []
        for media in local where !removable.contains(media.id) && seen.insert(media.id).inserted {
            merged.append(media)
        }
        for media in planning where !localIDs.contains(media.id) && seen.insert(media.id).inserted {
            merged.append(media)
        }
        return merged
    }

    /// MAL and AniList split seasons differently; a watched count past the season's end isn't a
    /// fact about it and is held at the finale (Android's `clampRemoteProgress`).
    public static func clampProgress(_ progress: Int, totalEpisodes: Int?) -> Int {
        guard let total = totalEpisodes, total > 0 else { return max(0, progress) }
        return min(max(0, progress), total)
    }
}
