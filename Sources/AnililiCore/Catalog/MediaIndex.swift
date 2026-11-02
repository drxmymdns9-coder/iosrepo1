import Foundation

/// The project's media index: static JSON on jsDelivr built by `pommieyewear/media-index`, shared
/// with the Android app (which calls it Konoha) and the desktop app. A port of the desktop's
/// `media_index.rs`.
///
/// It fills what the live sources leave empty: the dub index behind the DUB badge, a series'
/// transparent logo, episode titles and TMDB stills, filler lists and wide backdrops. A 404 is the
/// ordinary answer for a title the index hasn't covered and reads as "nothing".
public actor MediaIndex {
    public static let shared = MediaIndex()
    public static let base = "https://cdn.jsdelivr.net/gh/pommieyewear/media-index@main/data"

    public struct Images: Decodable, Sendable, Equatable {
        public var poster: String?
        public var banner: String?
        /// The series' own wordmark, a transparent PNG.
        public var logo: String?
    }

    public struct Detail: Decodable, Sendable, Equatable {
        public var images: Images?
        /// The title's season chain as the generator walked it: AniList ids in airing order.
        public var series: [Int]?
    }

    public struct Episode: Decodable, Sendable, Equatable {
        public var number: Double?
        public var title: String?
        public var overview: String?
        public var air_date: String?
        public var still: String?
        public var runtime: Int?
    }

    typealias Fetch = @Sendable (URL) async throws -> Data?

    private let fetch: Fetch
    private var dubbed: (at: Date, ids: Set<Int>)?
    private var details: [Int: Detail?] = [:]
    private var episodeLists: [Int: [Episode]] = [:]
    private var fillers: (at: Date, titles: [Int: Set<Int>])?
    private var graph: (at: Date, value: NeighbourGraph)?

    /// `{"titles": {"<anilist id>": value}}`, the shape of the index's per-title lists.
    struct Titled<Value: Decodable>: Decodable {
        var titles: [String: Value]
    }

    /// jsDelivr caches the branch for up to 12 hours, so re-reading sooner learns nothing.
    static let listTTL: TimeInterval = 6 * 60 * 60

    public init() {
        fetch = { url in
            let (data, response) = try await HTTP.data(url)
            if response.statusCode == 404 { return nil }
            guard (200..<300).contains(response.statusCode) else {
                throw HTTPError(status: response.statusCode, "Media index answered HTTP \(response.statusCode)")
            }
            return data
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// AniList ids the index found an English dub for. Empty, not an error, when it can't be read:
    /// a missing badge is the only cost.
    public func dubbedIDs() async -> Set<Int> {
        if let dubbed, Date().timeIntervalSince(dubbed.at) < Self.listTTL { return dubbed.ids }
        do {
            let ids = try await get([Int].self, "dub-index.json") ?? []
            dubbed = (Date(), Set(ids))
            Log.info("index", "dub index: \(ids.count) titles")
            return Set(ids)
        } catch {
            Log.warning("index", "dub index failed: \(Log.describe(error))")
            return dubbed?.ids ?? []
        }
    }

    /// The title's record (logo, banner, season chain), or nil where the index has none.
    public func detail(_ anilistID: Int) async -> Detail? {
        if let cached = details[anilistID] { return cached }
        let detail = try? await get(Detail.self, "anime/\(anilistID / 1000)/\(anilistID)/index.json")
        details[anilistID] = detail
        return detail
    }

    public func logo(_ anilistID: Int) async -> URL? {
        await detail(anilistID)?.images?.logo.flatMap(URL.init(string:))
    }

    /// Episode titles, synopses and stills, which Miruro lacks for anything new.
    public func episodes(_ anilistID: Int) async -> [Episode] {
        if let cached = episodeLists[anilistID] { return cached }
        let episodes = (try? await get([Episode].self, "anime/\(anilistID / 1000)/\(anilistID)/episodes.json")) ?? []
        episodeLists[anilistID] = episodes
        return episodes
    }

    /// The filler episodes of a title, from `filler-index.json`; empty when it has none or the
    /// index can't be read.
    public func fillerEpisodes(_ anilistID: Int) async -> Set<Int> {
        if let fillers, Date().timeIntervalSince(fillers.at) < Self.listTTL { return fillers.titles[anilistID] ?? [] }
        guard let list = try? await get(Titled<[Double]>.self, "filler-index.json") else { return [] }
        var titles: [Int: Set<Int>] = [:]
        for (key, numbers) in list.titles {
            if let id = Int(key) { titles[id] = Set(numbers.filter { $0 == $0.rounded() }.map { Int($0) }) }
        }
        fillers = (Date(), titles)
        return titles[anilistID] ?? []
    }

    /// Settings → Data → Re-download metadata: forget everything read so far, so the next read of
    /// each list and title comes from the index again.
    public func clear() {
        dubbed = nil
        details = [:]
        episodeLists = [:]
        fillers = nil
        graph = nil
        Log.info("index", "cleared every cached list and title")
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T? {
        guard let url = URL(string: "\(Self.base)/\(path)"), let data = try await fetch(url) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
}

extension MediaIndex {
    /// The neighbour graph For You and Because you watched are drawn from (~1.4 MB gzipped),
    /// kept for as long as jsDelivr would. Nil when it can't be read: the rows fall back to
    /// AniList's recommendations.
    public func neighbourGraph() async -> NeighbourGraph? {
        if let graph, Date().timeIntervalSince(graph.at) < Self.listTTL { return graph.value }
        guard let url = URL(string: "\(Self.base)/\(NeighbourGraph.path)") else { return nil }
        do {
            guard let data = try await fetch(url) else { return nil }
            let parsed = try NeighbourGraph.gzip(data)
            graph = (Date(), parsed)
            Log.info("recs", "neighbour graph: \(parsed.count) titles, generated \(parsed.generated ?? "?")")
            return parsed
        } catch {
            Log.warning("recs", "neighbour graph unreadable: \(Log.describe(error))")
            return graph?.value
        }
    }
}
