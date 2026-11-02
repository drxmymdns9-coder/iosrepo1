import Foundation

/// One row Home can draw. The raw value is what's stored (Android's keys), so it must never change.
public enum HomeRow: String, CaseIterable, Sendable, Identifiable {
    case continueWatching = "continue"
    case forYou = "for_you"
    case because
    case newest
    case trending
    case popular
    case topRated = "top_rated"
    case movies
    case upcoming

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .continueWatching: return "Continue Watching"
        case .forYou: return "For You"
        case .because: return "Because you watched…"
        case .newest: return "New Episodes"
        case .trending: return "Trending"
        case .popular: return "Popular This Season"
        case .topRated: return "Top Rated"
        case .movies: return "Movies"
        case .upcoming: return "Upcoming"
        }
    }

    /// Rows backed by an AniList catalogue list, which can be expanded into a grid.
    public var isCatalogue: Bool {
        switch self {
        case .continueWatching, .forYou, .because: return false
        default: return true
        }
    }
}

/// The viewer's Home: which rows, in what order. A port of the Android app's `HomeLayout`.
///
/// Stored as one string, `continue,for_you,-because,newest,…` with a leading `-` meaning hidden,
/// the same encoding Android writes, so a backup carries it across. Absent means "never
/// customised", which is not the same as "customised to today's default".
public struct HomeLayout: Equatable, Sendable {
    public var order: [HomeRow]
    public var hidden: Set<HomeRow>

    public init(order: [HomeRow], hidden: Set<HomeRow> = []) {
        self.order = order
        self.hidden = hidden
    }

    /// The phone's feed: what is out now first, then the catalogue's long-standing order.
    public static let defaultOrder: [HomeRow] = [
        .continueWatching, .forYou, .because, .newest, .trending, .popular, .topRated, .movies, .upcoming,
    ]

    public static let standard = HomeLayout(order: defaultOrder)

    public var visible: [HomeRow] { order.filter { !hidden.contains($0) } }

    public func encode() -> String {
        order.map { hidden.contains($0) ? "-\($0.rawValue)" : $0.rawValue }.joined(separator: ",")
    }

    public func moving(_ row: HomeRow, to target: Int) -> HomeLayout {
        guard let from = order.firstIndex(of: row) else { return self }
        let destination = min(max(target, 0), order.count - 1)
        guard destination != from else { return self }
        var copy = self
        copy.order.remove(at: from)
        copy.order.insert(row, at: destination)
        return copy
    }

    public func withHidden(_ row: HomeRow, _ hide: Bool) -> HomeLayout {
        var copy = self
        if hide { copy.hidden.insert(row) } else { copy.hidden.remove(row) }
        return copy
    }

    /// The stored layout, or the default when there is none. Unknown keys and repeats are dropped;
    /// a row the stored layout doesn't mention (added after the viewer customised) goes back where
    /// the default has it, after the row that precedes it there.
    public static func decode(_ stored: String?) -> HomeLayout {
        guard let stored, !stored.trimmingCharacters(in: .whitespaces).isEmpty else { return standard }
        var order: [HomeRow] = []
        var hidden = Set<HomeRow>()
        for token in stored.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let hide = token.hasPrefix("-")
            guard let row = HomeRow(rawValue: hide ? String(token.dropFirst()) : token), !order.contains(row) else { continue }
            order.append(row)
            if hide { hidden.insert(row) }
        }
        for (index, row) in defaultOrder.enumerated() where !order.contains(row) {
            if let before = defaultOrder[..<index].last(where: order.contains), let position = order.firstIndex(of: before) {
                order.insert(row, at: position + 1)
            } else {
                order.insert(row, at: 0)
            }
        }
        return HomeLayout(order: order, hidden: hidden)
    }
}
