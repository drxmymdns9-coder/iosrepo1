import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// hanime, ported from the Android app's `HanimeProvider`, `HanimeCatalog` and `HanimeBridge`. An
/// adult-only server: `SourceHub` asks it only while "Hide adult content" is off.
///
/// Its whole library is one JSON file (`search_hvs`, ~3,400 videos, 4.5 MB, ungated since the
/// Astro rebuild of 2026-09), which the site searches in the browser; it is held a day and both
/// lists the episodes and binds an AniList entry to a series by name. That part is plain HTTP.
///
/// Streams are not. The player's handshake encrypts its request and decrypts its reply in
/// WebAssembly, so only the real page can perform it: the app loads the video page in a hidden web
/// view, hooks `JSON.parse`, and keeps the first parsed object carrying a `sources` array (the
/// decrypted ladder, 720/480/360; the 1080p rung is a premium upsell with no URL). That web view
/// lives in the app target and is plugged in as `Hanime.resolver`; without one (Linux, tests)
/// hanime lists episodes and offers no streams.
public actor Hanime: StreamProvider {
    public nonisolated let id = "hanime"
    public nonisolated let name = "Hanime"

    static let origin = "https://hanime.tv"
    static let catalogueURL = URL(string: "https://guest.freeanimehentai.net/api/v11/search_hvs")!

    /// One rung of the ladder the handshake hands back; `src` is relative to `origin` and opaque.
    public struct Rung: Sendable, Equatable, Decodable {
        public var src: String
        public var label: String
        public var kind: String
        public var width: Int?
        public var height: Int?

        public init(src: String, label: String = "", kind: String = "normal", width: Int? = nil, height: Int? = nil) {
            self.src = src
            self.label = label
            self.kind = kind
            self.width = width
            self.height = height
        }

        enum CodingKeys: String, CodingKey { case src, label, kind, width, height }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            src = (try? container.decode(String.self, forKey: .src)) ?? ""
            label = (try? container.decode(String.self, forKey: .label)) ?? ""
            kind = (try? container.decode(String.self, forKey: .kind)) ?? ""
            width = Self.integer(container, .width)
            height = Self.integer(container, .height)
        }

        /// The site has sent sizes both as numbers and as strings.
        private static func integer(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
            (try? container.decode(Int.self, forKey: key)) ?? (try? container.decode(String.self, forKey: key)).flatMap(Int.init)
        }

        public var isPlayable: Bool { kind == "normal" && !src.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Resolves a video slug to the handshake's ladder by letting hanime's own page negotiate it.
    public typealias Resolver = @Sendable (_ slug: String) async throws -> [Rung]

    /// Set by the app once its hidden web view exists.
    nonisolated(unsafe) public static var resolver: Resolver?

    typealias Fetch = @Sendable (URL) async throws -> (Int, Data)

    private let fetch: Fetch
    private let resolve: @Sendable () -> Resolver?
    private let catalogue = CatalogueCache<[HanimeParser.Video]>(ttl: 24 * 3600, isEmpty: { $0.isEmpty })
    /// The series per AniList id: matching scores every one of ~1,500 series, so it's done once.
    private var matches: [Int: [HanimeParser.Video]] = [:]

    public init() {
        fetch = { url in
            var request = URLRequest(url: url)
            request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(Hanime.origin + "/", forHTTPHeaderField: "Referer")
            request.setValue(Hanime.origin, forHTTPHeaderField: "Origin")
            request.setValue("web2", forHTTPHeaderField: "X-Signature-Version")
            request.timeoutInterval = 30
            let (data, response) = try await HTTP.data(for: request)
            return (response.statusCode, data)
        }
        resolve = { Hanime.resolver }
    }

    init(fetch: @escaping Fetch, resolver: Resolver?) {
        self.fetch = fetch
        resolve = { resolver }
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        let series = try await seriesFor(media)
        guard !series.isEmpty else { return .empty }
        let numbers = series.map(\.episodeNumber)
        Log.info("hanime", "\(media.id) → \(series[0].seriesSlug): \(numbers.count) episodes")
        // Japanese audio with burnt-in or absent subtitles; there is no dub.
        return EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: Set(numbers), dubbed: [])
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard audio == .sub else { return [] }
        guard let video = try await seriesFor(media).first(where: { $0.episodeNumber == episode }) else {
            throw ProviderError.episodeNotFound(provider: name, episode: episode)
        }
        guard let resolver = resolve() else { throw HTTPError("Hanime needs the app's web view to reach its player") }
        let ladder = try await resolver(video.slug)
        let sources = HanimeParser.sources(ladder, provider: name)
        Log.info("hanime", "\(video.slug): \(ladder.count) rungs, \(sources.count) playable")
        guard !sources.isEmpty else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        return sources
    }

    private func seriesFor(_ media: Media) async throws -> [HanimeParser.Video] {
        if let known = matches[media.id] { return known }
        let all = try await catalogue.get { [fetch] in
            let (status, data) = try await fetch(Self.catalogueURL)
            guard (200..<300).contains(status) else { throw HTTPError(status: status, "hanime's catalogue answered HTTP \(status)") }
            let videos = try HanimeParser.catalogue(data)
            Log.info("hanime", "catalogue: \(videos.count) videos")
            return videos
        }
        let series = HanimeParser.match(media, all)
        if !series.isEmpty { matches[media.id] = series }
        return series
    }
}

/// Pure parsing and matching for `Hanime`, kept network-free for tests.
enum HanimeParser {
    struct Video: Sendable, Equatable, Decodable {
        var id: Int
        var name: String
        var slug: String
        /// Alternate names, the Japanese one among them: what rescues localised titles.
        var searchTitles: String

        enum CodingKeys: String, CodingKey {
            case id, name, slug
            case searchTitles = "search_titles"
        }

        init(id: Int, name: String, slug: String, searchTitles: String = "") {
            self.id = id
            self.name = name
            self.slug = slug
            self.searchTitles = searchTitles
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            name = (try? container.decode(String.self, forKey: .name)) ?? ""
            slug = (try? container.decode(String.self, forKey: .slug)) ?? ""
            searchTitles = (try? container.decode(String.self, forKey: .searchTitles)) ?? ""
        }

        /// Everything in a series shares a slug once the episode number is off the end.
        var seriesSlug: String { trailingSlugNumber.replacing(in: slug.trimmingCharacters(in: .whitespaces), with: "") }
        /// Unnumbered entries are one-shots and count as episode 1.
        var episodeNumber: Int { trailingSlugNumber.firstMatch(in: slug.trimmingCharacters(in: .whitespaces))?[1].flatMap(Int.init) ?? 1 }

        var titles: [String] {
            var seen = Set<String>()
            return [name, trailingTitleNumber.replacing(in: name.trimmingCharacters(in: .whitespaces), with: ""), searchTitles]
                .compactMap(\.nonBlank).filter { seen.insert($0).inserted }
        }
    }

    /// The catalogue, either as a bare array (the old shape) or wrapped in `{"data": […]}` (since
    /// the Astro rebuild). Accepting both is what stops the next change costing anything: on Android
    /// the wrapper went unnoticed for weeks behind the bundled snapshot.
    static func catalogue(_ data: Data) throws -> [Video] {
        struct Wrapped: Decodable { var data: [Video] }
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(Wrapped.self, from: data) { return wrapped.data }
        return try decoder.decode([Video].self, from: data)
    }

    /// The best series for an AniList entry, its episodes in order, or none below the bar.
    static func match(_ media: Media, _ catalogue: [Video]) -> [Video] {
        let wanted = AdultTitles.candidates(media)
        guard !wanted.isEmpty else { return [] }
        var best: (episodes: [Video], score: Double)?
        for (_, episodes) in Dictionary(grouping: catalogue, by: \.seriesSlug) {
            var score = 0.0
            for episode in episodes {
                for candidate in episode.titles {
                    for target in wanted { score = max(score, AdultTitles.similarity(target, candidate)) }
                }
            }
            if score >= AdultTitles.matchThreshold, score > (best?.score ?? 0) { best = (episodes, score) }
        }
        return (best?.episodes ?? []).sorted { $0.episodeNumber < $1.episodeNumber }
    }

    /// The playable rungs as streams, sharpest first; hanime is one of the few servers with a real
    /// quality choice. The manifest is AES-128 with an open key, and wants no headers, but the
    /// page's own origin is sent as Referer as Android does.
    static func sources(_ ladder: [Hanime.Rung], provider: String) -> [VideoSource] {
        var seen = Set<URL>()
        return ladder.filter(\.isPlayable)
            .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
            .compactMap { rung -> VideoSource? in
                guard let url = URL(string: rung.src, relativeTo: URL(string: Hanime.origin + "/"))?.absoluteURL,
                      url.scheme == "https", seen.insert(url).inserted else { return nil }
                let label = rung.label.nonBlank ?? rung.height.map { "\($0)p" } ?? "HLS"
                return VideoSource(url: url, provider: provider, server: label, kind: .hls, headers: ["Referer": Hanime.origin + "/"])
            }
    }

    private static let trailingSlugNumber = Pattern(#"-(\d{1,2})$"#, caseInsensitive: false)
    private static let trailingTitleNumber = Pattern(#"\s+\d{1,2}$"#, caseInsensitive: false)
}
