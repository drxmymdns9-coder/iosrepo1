import Foundation

/// Where an account's titles sit, in a fixed order (Android's `ListStatusSlice`). Rewatching
/// folds into Watching: a sixth sliver would be too thin to read.
public enum ListStatusSlice: String, CaseIterable, Sendable, Identifiable {
    case watching, completed, planning, paused, dropped
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .watching: return "Watching"
        case .completed: return "Completed"
        case .planning: return "Planned"
        case .paused: return "Paused"
        case .dropped: return "Dropped"
        }
    }

    /// The reference categorical palette's first five dark-mode slots, as on Android.
    public var argb: UInt32 {
        switch self {
        case .watching: return 0xFF3987E5
        case .completed: return 0xFFD95926
        case .planning: return 0xFF199E70
        case .paused: return 0xFFC98500
        case .dropped: return 0xFFD55181
        }
    }
}

/// Everything the account sheet shows, worked out once from the lists already loaded (Android's
/// `AccountInsights` / `accountInsights`).
public struct AccountInsights: Equatable, Sendable {
    public var titles: Int
    public var episodes: Int
    public var minutesWatched: Int
    /// Nil when nothing is scored, so the stat says so rather than printing 0.0.
    public var meanScore: Double?
    /// Every slice, in `ListStatusSlice` order.
    public var statusCounts: [(slice: ListStatusSlice, count: Int)]
    public var topGenres: [(label: String, count: Int)]
    /// Every entry, most recently changed first: the activity feed.
    public var recent: [ListEntry]
    public var formats: [(label: String, count: Int)]
    public var studios: [(label: String, count: Int)]
    /// Titles per release year, or per decade once the list spans more than a dozen years.
    public var releaseYears: [(label: String, count: Int)]
    /// How many titles got each whole score 1–10; empty when nothing is scored.
    public var scoreSpread: [(label: String, count: Int)]
    /// Completed as a share of everything finished one way or the other.
    public var completionRate: Int?
    /// Episodes left in what's being watched, where the length is known.
    public var episodesToGo: Int

    public static let maxGenres = 5

    public func count(_ slice: ListStatusSlice) -> Int { statusCounts.first { $0.slice == slice }?.count ?? 0 }
    public var total: Int { statusCounts.reduce(0) { $0 + $1.count } }

    public static func == (a: AccountInsights, b: AccountInsights) -> Bool {
        a.titles == b.titles && a.episodes == b.episodes && a.minutesWatched == b.minutesWatched && a.meanScore == b.meanScore
            && a.statusCounts.map(\.count) == b.statusCounts.map(\.count) && a.recent == b.recent
    }

    public init(profile: AccountProfile?, library: AccountLibrary) {
        let entries = library.entries
        func list(_ status: ListStatus) -> [ListEntry] { entries.filter { $0.status == status } }
        let watching = list(.current), rewatching = list(.repeating), completed = list(.completed)
        let planning = list(.planning), paused = list(.paused), dropped = list(.dropped)
        statusCounts = [
            (.watching, watching.count + rewatching.count), (.completed, completed.count), (.planning, planning.count),
            (.paused, paused.count), (.dropped, dropped.count),
        ]
        // Genres of what's been started: a Planning list is a wish list.
        let started = watching + rewatching + completed + paused + dropped
        let all = started + planning
        func unique(_ list: [ListEntry]) -> [Media] {
            var seen = Set<Int>()
            return list.map(\.media).filter { seen.insert($0.id).inserted }
        }
        let allMedia = unique(all), startedMedia = unique(started)
        topGenres = Self.ranked(unique(started.isEmpty ? planning : started).flatMap { $0.genres ?? [] }, limit: Self.maxGenres)
        formats = Self.ranked(allMedia.compactMap { Self.formatLabel($0.format) }, limit: .max)
        studios = Self.ranked(startedMedia.flatMap { ($0.studios?.nodes ?? []).filter { $0.isAnimationStudio == true }.compactMap(\.name) },
                              limit: Self.maxGenres)

        let years = allMedia.compactMap { $0.seasonYear ?? $0.startDate?.year }.filter { $0 > 0 }
        if let low = years.min(), let high = years.max() {
            if high - low <= 11 {
                releaseYears = (low...high).map { year in (Self.yearLabel(year), years.filter { $0 == year }.count) }
            } else {
                let decades = years.map { $0 / 10 * 10 }
                releaseYears = stride(from: decades.min()!, through: decades.max()!, by: 10).map { decade in
                    (Self.decadeLabel(decade), decades.filter { $0 == decade }.count)
                }
            }
        } else {
            releaseYears = []
        }

        var scoredIDs = Set<Int>()
        let scored = all.filter { $0.score > 0 && scoredIDs.insert($0.media.id).inserted }
        scoreSpread = scored.isEmpty ? [] : (1...10).map { value in
            (String(value), scored.filter { min(10, max(1, Int($0.score.rounded()))) == value }.count)
        }
        let finished = completed.count + dropped.count
        completionRate = finished == 0 ? nil : Int((Double(completed.count) * 100 / Double(finished)).rounded())
        episodesToGo = (watching + rewatching).reduce(0) { sum, entry in
            guard let total = entry.media.episodes else { return sum }
            return sum + max(0, total - entry.progress)
        }
        var recentIDs = Set<Int>()
        recent = all.filter { $0.updatedAt.timeIntervalSince1970 > 0 }
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { recentIDs.insert($0.media.id).inserted }

        let counted = statusCounts.reduce(0) { $0 + $1.count }
        titles = (profile?.animeCount ?? 0) > 0 ? profile!.animeCount : counted
        episodes = (profile?.episodesWatched ?? 0) > 0 ? profile!.episodesWatched : all.reduce(0) { $0 + max(0, $1.progress) }
        minutesWatched = profile?.minutesWatched ?? 0
        meanScore = (profile?.meanScore ?? 0) > 0 ? profile?.meanScore : nil
    }

    static func ranked(_ values: [String], limit: Int) -> [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(limit).map { ($0.key, $0.value) }
    }

    static func formatLabel(_ format: String?) -> String? {
        switch format {
        case nil: return nil
        case "TV": return "TV"
        case "TV_SHORT": return "TV short"
        case "MOVIE": return "Movie"
        case "OVA": return "OVA"
        case "ONA": return "ONA"
        case "SPECIAL": return "Special"
        case "MUSIC": return "Music"
        case let other?: return other.prefix(1).uppercased() + other.dropFirst().lowercased()
        }
    }

    /// A year narrow enough for twelve across a phone: 2024 is ’24.
    public static func yearLabel(_ year: Int) -> String { "\u{2019}" + String(format: "%02d", year % 100) }

    /// A decade: 1990 is 90s, 2000 is 00s.
    public static func decadeLabel(_ decade: Int) -> String { String(format: "%02d", decade % 100) + "s" }

    /// "3h 20m", "45m", "2h" (Android's `watchTimeLabel`).
    public static func watchTimeLabel(_ minutes: Int) -> String {
        let minutes = max(0, minutes)
        let hours = minutes / 60, remainder = minutes % 60
        if hours == 0 { return "\(remainder)m" }
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    /// Hours once there are enough to count ("1,062 h"), hours and minutes before that.
    public static func statWatchTime(_ minutes: Int) -> String {
        minutes >= 600 ? grouped(minutes / 60) + " h" : watchTimeLabel(minutes)
    }

    /// 1062 → "1,062", as Android's `%,d` prints it whatever the locale.
    public static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return (value < 0 ? "-" : "") + out
    }

    /// The account's public page on its own site.
    public static func profileURL(_ service: AccountService, name: String) -> URL? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? name
        switch service {
        case .anilist: return URL(string: "https://anilist.co/user/\(encoded)/")
        case .mal: return URL(string: "https://myanimelist.net/profile/\(encoded)")
        }
    }
}

/// Episodes finished per day, the activity grid's numbers (Android's `WatchActivityStore`
/// helpers). Days are counted from 1970-01-01 in the given calendar's time zone.
public enum WatchActivity {
    public static let keepDays = 400
    public static let heatmapWeeks = 20

    public static func day(_ date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month, .day], from: start)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnight = utc.date(from: components) ?? start
        return Int((midnight.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// One more episode on `day`, keeping `keepDays` of history.
    public static func recording(_ days: [Int: Int], on day: Int) -> [Int: Int] {
        var updated = days
        updated[day, default: 0] += 1
        return updated.filter { $0.key > day - keepDays }
    }

    /// This device's count and the account's, one per day: the larger, not the sum (the same
    /// evening is often in both).
    public static func merged(_ local: [Int: Int], _ account: [Int: Int]) -> [Int: Int] {
        var merged: [Int: Int] = [:]
        for day in Set(local.keys).union(account.keys) {
            let value = max(local[day] ?? 0, account[day] ?? 0)
            if value > 0 { merged[day] = value }
        }
        return merged
    }

    /// Consecutive active days ending today, or yesterday (a streak survives until tonight).
    public static func streak(_ days: [Int: Int], today: Int) -> Int {
        var day = (days[today] ?? 0) > 0 ? today : today - 1
        var streak = 0
        while (days[day] ?? 0) > 0 {
            streak += 1
            day -= 1
        }
        return streak
    }

    /// 0 for nothing, else 1–4 against the busiest day on screen.
    public static func level(_ count: Int, max: Int) -> Int {
        guard count > 0 else { return 0 }
        return Swift.min(4, Swift.max(1, Int((4.0 * Double(count) / Double(Swift.max(1, max))).rounded(.up))))
    }

    /// Epoch day → weekday, Monday 0 … Sunday 6 (1970-01-01 was a Thursday).
    public static func weekday(_ day: Int) -> Int { ((day + 3) % 7 + 7) % 7 }
}
