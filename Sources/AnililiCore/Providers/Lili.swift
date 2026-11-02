import Foundation

/// "Lili": 稀饭动漫 (xfdm), as the Android app names it, from the URLs the media index has already
/// resolved (`anime/<shard>/<id>/lili.json`, written by its crawler). Android's `XfdmProvider`
/// reads the same file first and only scrapes the site when there isn't one; that live path needs
/// the Bangumi title join and Chinese search, and isn't ported.
///
/// Progressive MP4 that answers `206` with no headers at all, so AVPlayer, AirPlay and other apps
/// can all open it as it is. The subtitles are Chinese and burned into the picture; there's no dub
/// (the site's channels are mirrors of one file).
public actor Lili: StreamProvider {
    public nonisolated let id = "xfdm"
    public nonisolated let name = "Lili"

    /// One title's record: a shared base and each episode's own path after it.
    public struct Sources: Decodable, Sendable, Equatable {
        public var provider: String?
        public var layout: String?
        public var base: String?
        public var episodes: [String: String]?

        /// The full URL for `episode`, or nil when the crawl didn't reach it (never a bare base).
        public func url(for episode: Int) -> URL? {
            guard let path = episodes?[String(episode)], !path.isEmpty else { return nil }
            return URL(string: (base ?? "") + path)
        }

        public var numbers: [Int] { (episodes ?? [:]).compactMap { $0.value.isEmpty ? nil : Int($0.key) }.filter { $0 > 0 }.sorted() }

        /// `temp` is the site's own word for a title still being staged, whose paths move.
        public var isProvisional: Bool { layout?.lowercased() == "temp" }
    }

    typealias Fetch = @Sendable (Int) async throws -> Sources?

    private let fetch: Fetch
    private var records: [Int: (at: Date, sources: Sources?)] = [:]

    static let ttl: TimeInterval = 6 * 60 * 60

    public init() {
        fetch = { id in
            guard let url = URL(string: "\(MediaIndex.base)/anime/\(id / 1000)/\(id)/lili.json") else { return nil }
            let (data, response) = try await HTTP.data(url)
            if response.statusCode == 404 { return nil }
            guard (200..<300).contains(response.statusCode) else {
                throw HTTPError(status: response.statusCode, "Media index answered HTTP \(response.statusCode)")
            }
            return try JSONDecoder().decode(Sources.self, from: data)
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        guard let record = try await record(media.id) else { return .empty }
        let numbers = record.numbers
        return EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: Set(numbers), dubbed: [])
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard audio == .sub else { return [] }
        guard let record = try await record(media.id), let url = record.url(for: episode) else {
            throw ProviderError.episodeNotFound(provider: name, episode: episode)
        }
        return [VideoSource(url: url, provider: name, server: "Chinese subtitles", kind: .mp4)]
    }

    /// A 404 is the ordinary answer (only part of the catalogue is crawled) and is remembered.
    private func record(_ id: Int) async throws -> Sources? {
        if let cached = records[id], Date().timeIntervalSince(cached.at) < Self.ttl { return cached.sources }
        let found = try await fetch(id)
        records[id] = (Date(), found)
        return found
    }
}
