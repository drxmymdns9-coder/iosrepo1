import Foundation

/// The viewer's saved shows ("My List"), most recently added first.
public struct Watchlist: Codable, Equatable, Sendable {
    public private(set) var items: [Media] = []

    public init() {}

    public func contains(_ mediaID: Int) -> Bool {
        items.contains { $0.id == mediaID }
    }

    /// Adds the show, or removes it if it's already saved. Returns whether it is now saved.
    @discardableResult
    public mutating func toggle(_ media: Media) -> Bool {
        if contains(media.id) {
            remove(mediaID: media.id)
            return false
        }
        items.insert(media, at: 0)
        return true
    }

    public mutating func remove(mediaID: Int) {
        items.removeAll { $0.id == mediaID }
    }

    /// The account sync's merge result (`ListSync.mergeWatchlist`), in its order.
    public mutating func replace(with media: [Media]) {
        var seen = Set<Int>()
        items = media.filter { seen.insert($0.id).inserted }
    }
}
