import Foundation

/// For You and Because you watched from the media index's neighbour graph
/// (`recs/neighbours-v1.tsv.gz`), a port of the desktop's `recs.rs`: the viewer's list and
/// history become taste signals, each franchise is one seed, and neighbours are scored, kept
/// out of franchises already seen, and spread so one favourite doesn't fill the row.
public struct NeighbourGraph: Sendable {
    public static let path = "recs/neighbours-v1.tsv.gz"
    static let header = "#anilili-neighbours"
    static let formatVersion = 1
    static let flagAdult: UInt8 = 1
    static let flagUnreleased: UInt8 = 2

    struct Node: Sendable {
        var root: Int
        var flags: UInt8
        var edges: [(id: Int, weight: UInt8)]
    }

    private var nodes: [Int: Node]
    public var generated: String?

    public enum Failure: Error, Equatable { case notGzip, notNeighbours, unsupportedVersion(Int?) }

    public static func gzip(_ data: Data) throws -> NeighbourGraph {
        guard let text = try? Gzip.decompress(data) else { throw Failure.notGzip }
        return try NeighbourGraph(text)
    }

    public init(_ data: Data) throws {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        let header = (lines.next() ?? "").split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard header.first == Self.header else { throw Failure.notNeighbours }
        let version = header.count > 1 ? Int(header[1]) : nil
        guard version == Self.formatVersion else { throw Failure.unsupportedVersion(version) }
        generated = header.count > 2 ? header[2] : nil
        var nodes: [Int: Node] = [:]
        while let line = lines.next() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let first = fields.first, let id = Int(first), nodes[id] == nil else { continue }
            let root = fields.count > 1 ? Int(fields[1]) ?? id : id
            let flags = fields.count > 2 ? UInt8(fields[2]) ?? 0 : 0
            let edges: [(id: Int, weight: UInt8)] = fields.count > 3 ? fields[3].split(separator: ",").compactMap { pair in
                let halves = pair.split(separator: ":")
                guard halves.count == 2, let neighbour = Int(halves[0]), let weight = UInt32(halves[1]) else { return nil }
                return (neighbour, UInt8(min(max(weight, 1), 100)))
            } : []
            nodes[id] = Node(root: root, flags: flags, edges: edges)
        }
        self.nodes = nodes
    }

    public var count: Int { nodes.count }
    public func root(of id: Int) -> Int { nodes[id]?.root ?? id }
    public func isAdult(_ id: Int) -> Bool { (nodes[id]?.flags ?? 0) & Self.flagAdult != 0 }
    public func isUnreleased(_ id: Int) -> Bool { (nodes[id]?.flags ?? 0) & Self.flagUnreleased != 0 }
    func neighbours(_ id: Int) -> [(id: Int, weight: UInt8)] { nodes[id]?.edges ?? [] }
    func hasNeighbours(_ id: Int) -> Bool { !(nodes[id]?.edges.isEmpty ?? true) }
}

public enum Recommendations {
    public struct Signal: Equatable, Sendable {
        public var id: Int
        public var weight: Double
        public init(id: Int, weight: Double) {
            self.id = id
            self.weight = weight
        }
    }

    /// A list entry as a rating (status in AniList's words, score out of 10).
    public struct Rating: Sendable {
        public var id: Int
        public var status: ListStatus
        public var score: Double
        /// Seconds since the epoch.
        public var updatedAt: Int
        public init(id: Int, status: ListStatus, score: Double, updatedAt: Int) {
            self.id = id
            self.status = status
            self.score = score
            self.updatedAt = updatedAt
        }
    }

    public struct Played: Sendable {
        public var id: Int
        public var episodesWatched: Int
        public var updatedAt: Int
        public init(id: Int, episodesWatched: Int, updatedAt: Int) {
            self.id = id
            self.episodesWatched = episodesWatched
            self.updatedAt = updatedAt
        }
    }

    public struct Pick: Equatable, Sendable {
        public var id: Int
        public var score: Double
        /// The title it's recommended because of.
        public var because: Int
    }

    static let lowScore = 5.0
    static let yearSeconds = 365.0 * 24 * 3600
    static let minRecency = 0.35
    static let repeatSeedDecay = 0.8
    static let candidatePoolFactor = 4
    static let fallbackMinEpisodes = 3
    public static let diceOpened = 0.3
    public static let diceSkipped = -0.1

    /// The viewer's taste: the list weighed against their own scoring scale, then titles played
    /// here that aren't on it, then dice feedback, each fading with age.
    public static func signals(list: [Rating], played: [Played], feedback: [(id: Int, weight: Double)] = [], now: Int) -> [Signal] {
        let scored = list.map(\.score).filter { $0 > 0 }
        let mean = scored.isEmpty ? 0 : scored.reduce(0, +) / Double(scored.count)
        let spread = scored.count < 2 ? 1 : max(1, (scored.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(scored.count)).squareRoot())
        var order: [Int] = []
        var weights: [Int: Double] = [:]
        for entry in list {
            if weights[entry.id] == nil { order.append(entry.id) }
            weights[entry.id] = statusWeight(entry, mean: mean, spread: spread) * recency(entry.updatedAt, now: now)
        }
        for title in played where weights[title.id] == nil {
            let base = title.episodesWatched >= 3 ? 0.9 : (title.episodesWatched >= 1 ? 0.45 : 0.15)
            order.append(title.id)
            weights[title.id] = base * recency(title.updatedAt, now: now)
        }
        for (id, weight) in feedback where weights[id] == nil {
            order.append(id)
            weights[id] = weight
        }
        return order.compactMap { id in
            let weight = weights[id] ?? 0
            return weight != 0 ? Signal(id: id, weight: weight) : nil
        }
    }

    static func statusWeight(_ entry: Rating, mean: Double, spread: Double) -> Double {
        let score = entry.score
        let relative = score > 0 ? min(max((score - mean) / spread, -2), 2) : 0
        switch entry.status {
        case .completed:
            if score <= 0 { return 1 }
            if score < lowScore { return -0.6 }
            return min(max(1 + 0.45 * relative, 0.2), 2)
        case .repeating: return 1.6
        case .current: return score > 0 && score < lowScore ? -0.3 : 0.8 + 0.2 * max(relative, 0)
        case .paused: return 0.25
        case .dropped: return score >= lowScore + 2 ? 0 : -0.8
        case .planning: return 0.25
        }
    }

    static func recency(_ updatedAt: Int, now: Int) -> Double {
        guard updatedAt > 0 else { return 1 }
        let years = Double(max(0, now - updatedAt)) / yearSeconds
        return max(pow(0.5, years), minRecency)
    }

    public static func recommend(_ graph: NeighbourGraph, signals: [Signal], exclude: Set<Int>, hideAdult: Bool, limit: Int) -> [Pick] {
        guard !signals.isEmpty else { return [] }
        var excluded = Set(exclude.map(graph.root(of:)))
        excluded.formUnion(signals.map { graph.root(of: $0.id) })
        var seeds: [(root: Int, members: [Signal])] = []
        for signal in signals {
            let root = graph.root(of: signal.id)
            if let index = seeds.firstIndex(where: { $0.root == root }) {
                seeds[index].members.append(signal)
            } else {
                seeds.append((root, [signal]))
            }
        }
        var totals: [Int: Double] = [:]
        var best: [Int: Double] = [:]
        var because: [Int: Int] = [:]
        for seed in seeds {
            // max_by keeps the last of equals, as Rust's does.
            var strongest = seed.members[0]
            for member in seed.members.dropFirst() where abs(member.weight) >= abs(strongest.weight) { strongest = member }
            var local: [Int: Double] = [:]
            for member in seed.members {
                for (neighbour, weight) in graph.neighbours(member.id) {
                    let root = graph.root(of: neighbour)
                    if excluded.contains(root) || graph.isUnreleased(neighbour) { continue }
                    if hideAdult && (graph.isAdult(neighbour) || graph.isAdult(root)) { continue }
                    let strength = Double(weight) / 100
                    if strength > local[root, default: 0] { local[root] = strength }
                }
            }
            for (root, strength) in local {
                let contribution = strongest.weight * strength
                totals[root, default: 0] += contribution
                if contribution > best[root, default: 0] {
                    best[root] = contribution
                    because[root] = strongest.id
                }
            }
        }
        var ranked = totals.compactMap { root, total -> Pick? in
            guard total > 0, let reason = because[root] else { return nil }
            return Pick(id: root, score: total, because: reason)
        }
        ranked.sort { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        return diversify(Array(ranked.prefix(limit * candidatePoolFactor)), limit: limit)
    }

    /// Because you watched `seed`.
    public static func because(_ graph: NeighbourGraph, seed: Int, exclude: Set<Int>, hideAdult: Bool, limit: Int) -> [Pick] {
        recommend(graph, signals: [Signal(id: seed, weight: 1)], exclude: exclude, hideAdult: hideAdult, limit: limit)
    }

    /// The title Because you watched is about: the latest one finished and liked, else the
    /// latest one played here for a few episodes.
    public static func featuredSeed(_ graph: NeighbourGraph, list: [Rating], played: [Played], now: Int) -> Int? {
        let weights = Dictionary(signals(list: list, played: played, now: now).map { ($0.id, $0.weight) }, uniquingKeysWith: { first, _ in first })
        let finished = list
            .filter { ($0.status == .completed || $0.status == .repeating) && weights[$0.id, default: 0] > 0 }
            .sorted { $0.updatedAt > $1.updatedAt }
        if let entry = finished.first(where: { graph.hasNeighbours($0.id) }) { return entry.id }
        let onList = Set(list.map(\.id))
        return played
            .filter { !onList.contains($0.id) && $0.episodesWatched >= fallbackMinEpisodes }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first { graph.hasNeighbours($0.id) }?.id
    }

    static func diversify(_ ranked: [Pick], limit: Int) -> [Pick] {
        var pool = ranked
        var credited: [Int: Int] = [:]
        var picked: [Pick] = []
        while picked.count < limit && !pool.isEmpty {
            var bestIndex = 0
            var bestScore = -Double.infinity
            for (index, pick) in pool.enumerated() {
                let score = pick.score * pow(repeatSeedDecay, Double(credited[pick.because, default: 0]))
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }
            let choice = pool.remove(at: bestIndex)
            credited[choice.because, default: 0] += 1
            picked.append(choice)
        }
        return picked
    }
}
