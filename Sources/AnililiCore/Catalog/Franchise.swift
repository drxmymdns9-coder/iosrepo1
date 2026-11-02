import Foundation

/// A title's whole franchise as a watch guide: the season chain plus whatever its members'
/// franchise relations reach, shelved Seasons, Movies, OVAs, Specials, Other. A port of the
/// desktop's `franchise.rs` (Android's `buildWatchOrder`).
public enum WatchOrder {
    public enum Shelf: Int, Comparable, CaseIterable, Sendable {
        case seasons, movies, ovas, specials, other

        public static func < (lhs: Shelf, rhs: Shelf) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .seasons: return "Seasons"
            case .movies: return "Movies"
            case .ovas: return "OVAs"
            case .specials: return "Specials"
            case .other: return "Other"
            }
        }
    }

    public struct Entry: Identifiable, Hashable, Sendable {
        public var media: Media
        public var shelf: Shelf
        /// Franchise-wide airing order, from 1.
        public var position: Int
        /// The story's own order (PREQUEL/SEQUEL edges, airing order breaking ties), from 1.
        public var chronological: Int
        /// "Season 2" when the chain has more than one season.
        public var seasonNumber: Int?
        /// How it relates to the franchise ("Side story"), for entries off the season chain.
        public var relation: String?
        public var isCurrent: Bool
        public var id: Int { media.id }

        /// "Season 2 · 2023 · 12 eps", "Movie · Side story · 2024" (Android's `metaLine`).
        public var metaLine: String {
            let kind = seasonNumber.map { "Season \($0)" } ?? media.formatLabel
            return ([kind, relation].compactMap { $0 } + media.yearAndEpisodes).joined(separator: " · ")
        }
    }

    static let franchiseRelations: Set<String> = ["PREQUEL", "SEQUEL", "PARENT", "SIDE_STORY", "SUMMARY", "ALTERNATIVE", "SPIN_OFF", "COMPILATION", "CONTAINS"]
    static let seasonRelations: Set<String> = ["PREQUEL", "SEQUEL"]
    static let franchiseFormats: Set<String> = ["TV", "TV_SHORT", "MOVIE", "SPECIAL", "OVA", "ONA"]
    static let seasonFormats: Set<String> = ["TV", "TV_SHORT", "ONA"]
    static let maxSeriesEntries = 16
    static let maxSeriesDepth = 8

    /// The season chain for `id`, airing order: the media index's when it has one that includes
    /// the title, otherwise found by walking PREQUEL/SEQUEL relations on AniList. Each member
    /// carries its relations, which is what `build` reads the rest of the franchise off.
    public static func series(_ id: Int, indexSeries: [Int]?, hideAdult: Bool, aniList: AniListClient = .shared) async throws -> [Media] {
        let members: [Media]
        if let indexSeries, indexSeries.contains(id) {
            members = try await aniList.members(indexSeries)
        } else {
            members = try await walk(id, hideAdult: hideAdult, aniList: aniList)
        }
        return members.filter { !(hideAdult && $0.isAdult == true) }.sorted { airingKey($0) < airingKey($1) }
    }

    /// The chain before the walk lands: the title and its direct prequel and sequel, read off its
    /// own relations (Android's `seasonNeighbors`), so the season chips and the guide show at once.
    public static func seeded(_ info: Media, hideAdult: Bool) -> [Media] {
        var seen: Set<Int> = [info.id]
        let neighbours = (info.relations?.edges ?? []).compactMap { edge -> Media? in
            guard let kind = edge.relationType, seasonRelations.contains(kind), let node = edge.node,
                  !(hideAdult && node.isAdult == true), seen.insert(node.id).inserted else { return nil }
            return node
        }
        return ([info] + neighbours).sorted { airingKey($0) < airingKey($1) }
    }

    /// The numbered seasons of `info`'s series, in season order (Android's `seasonChain`): TheTVDB's
    /// run when it places the title, else the chain's episodic entries.
    public static func seasonChain(_ info: Media, series: [Media], ref: (Int) -> TVDBRef?) -> [Media] {
        // The page's own record, not the walk's: it's the one with the full entry behind it.
        let all = series.contains { $0.id == info.id }
            ? series.map { $0.id == info.id ? info : $0 }
            : ([info] + series).sorted { airingKey($0) < airingKey($1) }
        return SeasonLabels.chain(info, series: all, ref: ref)
            ?? all.filter { $0.id == info.id || ($0.format.map(seasonFormats.contains) ?? false) }
    }

    static func walk(_ id: Int, hideAdult: Bool, aniList: AniListClient) async throws -> [Media] {
        var found: [Int: Media] = [:]
        var expanded = Set<Int>()
        var frontier = [id]
        for _ in 0..<maxSeriesDepth {
            let batch = Array(frontier.filter { expanded.insert($0).inserted }.prefix(maxSeriesEntries))
            if batch.isEmpty || found.count >= maxSeriesEntries { break }
            var next: [Int] = []
            for member in try await aniList.members(batch) {
                for edge in member.relations?.edges ?? [] {
                    guard let kind = edge.relationType, seasonRelations.contains(kind), let node = edge.node,
                          !(hideAdult && node.isAdult == true) else { continue }
                    if !expanded.contains(node.id) && found.count + next.count < maxSeriesEntries { next.append(node.id) }
                }
                found[member.id] = member
            }
            frontier = Array(Set(next)).sorted()
        }
        return Array(found.values)
    }

    static func airingKey(_ media: Media) -> (Int, Int, Int, Int) {
        (media.startDate?.year ?? media.seasonYear ?? 9999, media.startDate?.month ?? 99, media.startDate?.day ?? 99, media.id)
    }

    /// `seasons` is the season chain the Episodes tab's chips use, so both tabs number the same
    /// run; without it the chain's episodic entries are the seasons.
    public static func build(_ current: Media, series: [Media], seasons seasonChain: [Media]? = nil, hideAdult: Bool) -> [Entry] {
        var members: [Media] = [current] + series.filter { $0.id != current.id && !(hideAdult && $0.isAdult == true) }
        let chain = members
        var labels: [Int: String] = [:]
        for member in chain {
            for edge in member.relations?.edges ?? [] {
                guard let kind = edge.relationType, franchiseRelations.contains(kind), let node = edge.node,
                      !(hideAdult && node.isAdult == true) else { continue }
                let known = members.contains { $0.id == node.id }
                if !known && !(node.format.map(franchiseFormats.contains) ?? false) { continue }
                if !known { members.append(node) }
                if !seasonRelations.contains(kind), labels[node.id] == nil { labels[node.id] = pretty(kind) }
            }
        }
        members.sort { airingKey($0) < airingKey($1) }
        let storyOrder = story(members) ?? members.map(\.id)
        var storyAt: [Int: Int] = [:]
        for (index, id) in storyOrder.enumerated() { storyAt[id] = index + 1 }
        let chainIDs = Set(chain.map(\.id))
        let memberIDs = Set(members.map(\.id))
        let seasons = seasonChain.map { $0.map(\.id).filter(memberIDs.contains) }
            ?? members.filter { $0.id == current.id || (chainIDs.contains($0.id) && ($0.format.map(seasonFormats.contains) ?? false)) }.map(\.id)

        var entries: [Entry] = members.enumerated().map { index, media in
            let seasonIndex = seasons.firstIndex(of: media.id)
            let shelf: Shelf
            if seasonIndex != nil {
                shelf = .seasons
            } else {
                switch media.format {
                case "MOVIE": shelf = .movies
                case "OVA": shelf = .ovas
                case "SPECIAL": shelf = .specials
                default: shelf = .other
                }
            }
            return Entry(
                media: media,
                shelf: shelf,
                position: index + 1,
                chronological: storyAt[media.id] ?? index + 1,
                seasonNumber: seasons.count > 1 ? seasonIndex.map { $0 + 1 } : nil,
                relation: shelf == .seasons ? nil : labels[media.id],
                isCurrent: media.id == current.id
            )
        }
        entries.sort { ($0.shelf, $0.seasonNumber ?? $0.position) < ($1.shelf, $1.seasonNumber ?? $1.position) }
        return entries
    }

    /// The story's order: a topological sort of PREQUEL/SEQUEL edges, airing order breaking ties.
    /// Nil when the data has a cycle, and then the story follows airing order.
    static func story(_ members: [Media]) -> [Int]? {
        let ids = Set(members.map(\.id))
        var after: [Int: [Int]] = [:]
        var before: [Int: [Int]] = [:]
        for member in members {
            for edge in member.relations?.edges ?? [] {
                guard let kind = edge.relationType, seasonRelations.contains(kind), let node = edge.node, ids.contains(node.id) else { continue }
                let (earlier, later) = kind == "PREQUEL" ? (node.id, member.id) : (member.id, node.id)
                after[later, default: []].append(earlier)
                before[earlier, default: []].append(later)
            }
        }
        var place: [Int: Int] = [:]
        for (index, member) in members.enumerated() { place[member.id] = index }
        var waiting: [Int: Int] = after.mapValues(\.count)
        var ready = members.filter { waiting[$0.id] == nil }.map { place[$0.id]! }
        var out: [Int] = []
        while !ready.isEmpty {
            ready.sort(by: >)
            let index = ready.removeLast()
            let id = members[index].id
            out.append(id)
            for later in before[id] ?? [] {
                guard let count = waiting[later] else { continue }
                waiting[later] = count - 1
                if count - 1 == 0, let position = place[later] { ready.append(position) }
            }
        }
        return out.count == members.count ? out : nil
    }

    static let readingFormats: Set<String> = ["MANGA", "NOVEL", "ONE_SHOT"]

    /// AniList's community picks worth listing under the guide: not the title itself, nothing the
    /// guide already lists, nothing to read, nothing adult when that's hidden, each once.
    public static func suggestions(_ recommendations: [Media], current: Int, guide: [Entry], hideAdult: Bool) -> [Media] {
        var seen = Set(guide.map(\.media.id))
        seen.insert(current)
        return recommendations.filter { media in
            !(media.format.map(readingFormats.contains) ?? false) && !(hideAdult && media.isAdult == true)
                && seen.insert(media.id).inserted
        }
    }

    static func pretty(_ kind: String) -> String {
        let lower = kind.replacingOccurrences(of: "_", with: " ").lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }
}

extension Media {
    /// The year and, for anything longer than one sitting, the episode count: ["2023", "12 eps"].
    public var yearAndEpisodes: [String] {
        let year = (seasonYear ?? startDate?.year).map(String.init)
        let count = episodes.flatMap { $0 > 1 && format != "MOVIE" ? "\($0) eps" : nil }
        return [year, count].compactMap { $0 }
    }

    /// "TV · 2016 · 24 eps", for a title off the guide.
    public var relatedMetaLine: String {
        ([formatLabel].compactMap { $0 } + yearAndEpisodes).joined(separator: " · ")
    }
}

extension AniListClient {
    /// Titles by id, card fields only, 50 to a request (release alerts, new-episode badges).
    public func media(ids: [Int]) async throws -> [Media] {
        let query = "query ($ids: [Int]) { Page(page: 1, perPage: 50) { media(id_in: $ids, type: ANIME) { \(Self.mediaFields) } } }"
        struct PageResult: Decodable { var media: [Media] }
        struct Payload: Decodable { var Page: PageResult }
        var out: [Media] = []
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 50, ids.count)])
            let data: Payload = try await run(query, ["ids": .ints(chunk)])
            out += data.Page.media
            start += 50
        }
        return out
    }

    /// Titles by id with their relations, for walking a franchise (the desktop's `members`).
    public func members(_ ids: [Int]) async throws -> [Media] {
        let query = """
        query ($ids: [Int]) {
          Page(page: 1, perPage: 50) {
            media(id_in: $ids, type: ANIME) {
              \(Self.mediaFields)
              relations { edges { relationType node { type \(Self.mediaFields) } } }
            }
          }
        }
        """
        struct PageResult: Decodable { var media: [Media] }
        struct Payload: Decodable { var Page: PageResult }
        var out: [Media] = []
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 50, ids.count)])
            let data: Payload = try await run(query, ["ids": .ints(chunk)])
            out += data.Page.media
            start += 50
        }
        return out
    }
}
