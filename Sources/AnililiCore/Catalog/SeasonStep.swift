import Foundation

/// One season of one year, the unit Browse's season bar steps (Android's `SeasonDate` and
/// `stepSeasonWithinBounds`).
public struct SeasonStep: Equatable, Sendable {
    /// AniList's season names in broadcast order.
    public static let order = ["WINTER", "SPRING", "SUMMER", "FALL"]
    /// The earliest year the bar walks to; AniList has nothing before it.
    public static let earliestYear = 1900
    /// How far past the airing season it walks: announcements land well ahead (in September 2026
    /// AniList listed 50+ titles for Winter 2027 but a dozen for Spring), so two.
    public static let seasonsAhead = 2

    public var season: String
    public var year: Int

    public init(season: String, year: Int) {
        self.season = season
        self.year = year
    }

    /// Seasons since Winter of year zero, so a step is integer arithmetic.
    var index: Int { year * Self.order.count + (Self.order.firstIndex(of: season) ?? 0) }

    init(index: Int) {
        let count = Self.order.count
        season = Self.order[((index % count) + count) % count]
        year = Int((Double(index) / Double(count)).rounded(.down))
    }

    /// The season a date falls in, in AniList's quarters.
    public static func containing(_ date: Date) -> SeasonStep {
        let (season, year) = AniListClient.season(containing: date)
        return SeasonStep(season: season, year: year)
    }

    /// `delta` seasons on, or nil past the bounds: before 1900, or more than `seasonsAhead`
    /// past `today`'s season, where there is reliably nothing to list.
    public func stepped(_ delta: Int, today: SeasonStep) -> SeasonStep? {
        let target = SeasonStep(index: index + delta)
        if target.year < Self.earliestYear { return nil }
        if target.index > today.index + Self.seasonsAhead { return nil }
        return target
    }

    /// "Summer 2024", or the bare season with no year.
    public static func label(_ season: String, year: Int?) -> String {
        let pretty = season.prefix(1).uppercased() + season.dropFirst().lowercased()
        return year.map { "\(pretty) \($0)" } ?? pretty
    }
}
