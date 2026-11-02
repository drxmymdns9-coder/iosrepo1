import Foundation

/// The airing schedule, a month at a time, as the Android app reads it (`MiruroRepository
/// .schedule`): the media index publishes one file per month (`schedule/yyyy-mm.json`), so walking
/// a season through the calendar costs one CDN read per month rather than one AniList request per
/// day. AniList stays underneath it for months the index hasn't published.
public actor ScheduleService {
    public static let shared = ScheduleService()

    /// One row of the index's month file.
    struct IndexAiring: Decodable {
        var id: Int
        var episode: Int
        var airingAt: Int
        var english: String?
        var romaji: String?
        var cover: String?
        var format: String?
        var year: Int?
        var adult: Bool?

        var slot: AniListClient.AiringSlot {
            var media = Media(id: id, title: .init(romaji: romaji, english: english))
            media.coverImage = .init(large: cover)
            media.format = format
            media.seasonYear = year
            media.isAdult = adult ?? false
            return AniListClient.AiringSlot(episode: episode, airingAt: airingAt, media: media)
        }
    }

    typealias Fetch = @Sendable (URL) async throws -> Data?

    private let fetch: Fetch
    private let aniList: AniListClient
    private var months: [String: (at: Date, slots: [AniListClient.AiringSlot])] = [:]

    /// The index regenerates daily and jsDelivr caches for hours; a month read is good for an hour.
    static let monthTTL: TimeInterval = 60 * 60

    public init(aniList: AniListClient = .shared) {
        self.aniList = aniList
        fetch = { url in
            let (data, response) = try await HTTP.data(url)
            if response.statusCode == 404 { return nil }
            guard (200..<300).contains(response.statusCode) else {
                throw HTTPError(status: response.statusCode, "Media index answered HTTP \(response.statusCode)")
            }
            return data
        }
    }

    init(aniList: AniListClient = .shared, fetch: @escaping Fetch) {
        self.aniList = aniList
        self.fetch = fetch
    }

    /// Everything airing on `day` in `calendar`'s time zone, earliest first.
    public func day(_ day: Date, calendar: Calendar = .current, hideAdult: Bool, force: Bool = false) async throws -> [AniListClient.AiringSlot] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let window = DateInterval(start: start, end: end)
        // A day near a month's edge can spill into the neighbouring month's file in UTC.
        var slots: [AniListClient.AiringSlot] = []
        for month in Self.monthKeys(covering: window) {
            slots += try await self.month(month, force: force)
        }
        return Self.filter(slots, in: window, hideAdult: hideAdult)
    }

    /// Episodes per day for every day in `days`, for the calendar's cells.
    public func counts(_ days: [Date], calendar: Calendar = .current, hideAdult: Bool) async -> [Date: Int] {
        guard let first = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) else { return [:] }
        let window = DateInterval(start: calendar.startOfDay(for: first), end: end)
        var slots: [AniListClient.AiringSlot] = []
        for month in Self.monthKeys(covering: window) {
            slots += (try? await self.month(month, force: false)) ?? []
        }
        var counts: [Date: Int] = [:]
        for slot in Self.filter(slots, in: window, hideAdult: hideAdult) {
            counts[calendar.startOfDay(for: slot.date), default: 0] += 1
        }
        return counts
    }

    /// What airs from yesterday to `ContinueVisibility.upcomingDays` out, by title and episode, for
    /// Continue Watching's "Only episodes you can watch". Empty where it can't be read, which
    /// shows every row.
    public func upcoming(now: Date = Date(), calendar: Calendar = .current) async -> ContinueVisibility.Upcoming {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -1, to: today),
              let end = calendar.date(byAdding: .day, value: ContinueVisibility.upcomingDays - 1, to: today) else { return [:] }
        let window = DateInterval(start: start, end: end)
        var slots: [AniListClient.AiringSlot] = []
        for month in Self.monthKeys(covering: window) {
            slots += (try? await self.month(month, force: false)) ?? []
        }
        return ContinueVisibility.upcoming(Self.filter(slots, in: window, hideAdult: false).map { ($0.media.id, $0.episode, $0.date) })
    }

    /// Settings → Data → Re-download metadata: the next read of each month is a fresh one.
    public func clear() {
        months = [:]
    }

    // MARK: - Months

    private func month(_ key: String, force: Bool) async throws -> [AniListClient.AiringSlot] {
        if !force, let cached = months[key], Date().timeIntervalSince(cached.at) < Self.monthTTL { return cached.slots }
        let slots: [AniListClient.AiringSlot]
        if let url = URL(string: "\(MediaIndex.base)/schedule/\(key).json"),
           let data = try? await fetch(url),
           let rows = try? JSONDecoder().decode([IndexAiring].self, from: data) {
            slots = rows.map(\.slot)
            Log.info("schedule", "\(key): \(slots.count) airings from the media index")
        } else {
            guard let interval = Self.interval(ofMonth: key) else { return [] }
            slots = try await aniList.schedule(interval)
            Log.info("schedule", "\(key): \(slots.count) airings from AniList (not in the index)")
        }
        months[key] = (Date(), slots)
        return slots
    }

    static func filter(_ slots: [AniListClient.AiringSlot], in window: DateInterval, hideAdult: Bool) -> [AniListClient.AiringSlot] {
        var seen = Set<String>()
        return slots
            .filter { window.contains($0.date) && $0.date < window.end && !(hideAdult && $0.media.isAdult == true) && seen.insert($0.id).inserted }
            .sorted { $0.airingAt < $1.airingAt }
    }

    /// The `yyyy-mm` files (UTC, as the index names them) that hold `window`.
    static func monthKeys(covering window: DateInterval) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var keys: [String] = []
        var cursor = window.start
        while cursor < window.end {
            let parts = calendar.dateComponents([.year, .month], from: cursor)
            let key = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
            if keys.last != key { keys.append(key) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let lastParts = calendar.dateComponents([.year, .month], from: window.end.addingTimeInterval(-1))
        let lastKey = String(format: "%04d-%02d", lastParts.year ?? 0, lastParts.month ?? 0)
        if keys.last != lastKey { keys.append(lastKey) }
        return keys
    }

    static func interval(ofMonth key: String) -> DateInterval? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The month grid Android draws: whole weeks from the one holding the 1st to the one holding
    /// the last day, starting on `calendar.firstWeekday`.
    public static func monthGrid(containing date: Date, calendar: Calendar = .current) -> [Date] {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date)),
              let days = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let weekday = calendar.component(.weekday, from: first)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        let cells = ((lead + days + 6) / 7) * 7
        guard let start = calendar.date(byAdding: .day, value: -lead, to: first) else { return [] }
        return (0..<cells).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}
