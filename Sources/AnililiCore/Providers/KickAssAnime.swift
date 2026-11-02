import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// KickAssAnime (kaa.lt), ported from the Android app's `KickAssAnimeProvider`: a small JSON
/// catalogue and adaptive HLS from its own krussdomi CDN, which wants a Referer and an Origin.
///
/// Sub and dub are one multi-audio master; the request's audio is carried as
/// `VideoSource.audioLanguage` so the player selects the right track. Miruro also offers this
/// backend (its `hop`), so this is a second route to it when Miruro is having a bad day.
public actor KickAssAnime: StreamProvider {
    public nonisolated let id = "kaa"
    public nonisolated let name = "KickAssAnime"

    struct Show: Equatable, Sendable {
        var slug: String
        var title: String
        var locales: Set<String>
        var year: Int?
        var type: String?
    }

    static let base = "https://kaa.lt"
    static let api = base + "/api"
    static let playerOrigin = "https://krussdomi.com"
    static let hlsBase = "https://hls.krussdomi.com/manifest"
    static let original = "ja-JP"
    static let dubLocale = "en-US"
    static let minTitleScore = 0.28

    typealias Fetch = @Sendable (URLRequest) async throws -> (Int, Data)

    private let fetch: Fetch
    private var shows: [Int: Show] = [:]

    public init() {
        fetch = { request in
            let (data, response) = try await HTTP.data(for: request)
            return (response.statusCode, data)
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        guard let show = try await show(for: media) else { return .empty }
        let sub = show.locales.isEmpty || show.locales.contains(Self.original) ? KickAssAnimeCodec.episodeNumbers(try await json(episodesPath(show.slug, 1, Self.original))) : []
        let dub = show.locales.contains(Self.dubLocale) ? KickAssAnimeCodec.episodeNumbers(try await json(episodesPath(show.slug, 1, Self.dubLocale))) : []
        let numbers = sub.union(dub).sorted()
        return EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: sub, dubbed: dub)
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard let show = try await show(for: media) else { throw ProviderError.titleNotFound(provider: name) }
        let locale = audio == .dub ? Self.dubLocale : Self.original
        guard show.locales.isEmpty || show.locales.contains(locale) else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        guard let row = KickAssAnimeCodec.episode(try await json(episodesPath(show.slug, episode, locale)), episode) else {
            throw ProviderError.episodeNotFound(provider: name, episode: episode)
        }
        let detail = try await json("/show/\(show.slug)/episode/ep-\(episode)-\(row.slug)")
        guard let player = KickAssAnimeCodec.vidStreamingURL(detail), let playerID = KickAssAnimeCodec.playerID(player),
              let master = URL(string: "\(Self.hlsBase)/\(playerID)/master.m3u8") else {
            throw ProviderError.noStreams(episode: episode, audio: audio)
        }
        var subtitles: [SubtitleTrack] = []
        if let page = URL(string: player), let answer = try? await fetch(request(page, referer: Self.base + "/")), answer.0 == 200 {
            subtitles = KickAssAnimeCodec.subtitles(String(decoding: answer.1, as: UTF8.self))
        }
        return [VideoSource(url: master, provider: name, server: audio == .dub ? "English" : "Japanese", kind: .hls,
                            headers: ["Referer": Self.playerOrigin + "/", "Origin": Self.playerOrigin],
                            subtitles: subtitles, softSub: !subtitles.isEmpty, audioLanguage: audio == .dub ? "eng" : "jpn")]
    }

    // MARK: - Catalogue

    private func show(for media: Media) async throws -> Show? {
        if let cached = shows[media.id] { return cached }
        var candidates: [Show] = []
        var seen = Set<String>()
        for title in [media.title.english, media.title.romaji, media.title.native].compactMap({ $0?.nonBlank }) {
            var request = request(URL(string: Self.api + "/fsearch")!, referer: Self.base + "/")
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": title])
            guard let answer = try? await fetch(request), answer.0 == 200, let root = try? JSON.parse(answer.1) else { continue }
            candidates += KickAssAnimeCodec.searchResults(root).filter { seen.insert($0.slug).inserted }
        }
        guard let best = candidates.max(by: { Self.score(media, $0) < Self.score(media, $1) }), Self.score(media, best) >= Self.minTitleScore else {
            Log.info("kaa", "\(media.id): no confident match among \(candidates.count)")
            return nil
        }
        Log.info("kaa", "\(media.id) → \(best.slug) \(best.locales.sorted())")
        shows[media.id] = best
        return best
    }

    /// Title score, nudged by the year and the format: a remake or a movie of the same name
    /// mustn't win on the title alone.
    static func score(_ media: Media, _ candidate: Show) -> Double {
        var score = [media.title.english, media.title.romaji, media.title.native].compactMap { $0?.nonBlank }
            .map { TitleMatching.selectionScore($0, candidate.title) }.max() ?? 0
        if let expected = media.seasonYear, let actual = candidate.year { score *= expected == actual ? 1.15 : 0.55 }
        if let expected = media.format?.lowercased(), let actual = candidate.type?.lowercased(),
           !(expected == actual || (expected.hasPrefix("tv") && actual == "tv")) {
            score *= 0.7
        }
        return min(score, 1)
    }

    private func episodesPath(_ slug: String, _ episode: Int, _ locale: String) -> String {
        "/show/\(slug)/episodes?ep=\(episode)&lang=\(locale)"
    }

    private func json(_ path: String) async throws -> JSON {
        let (status, data) = try await fetch(request(URL(string: Self.api + path)!, referer: Self.base + "/"))
        guard status == 200 else { throw HTTPError(status: status, "KickAssAnime answered HTTP \(status)") }
        return try JSON.parse(data)
    }

    private func request(_ url: URL, referer: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/html,*/*", forHTTPHeaderField: "Accept")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        return request
    }
}

/// Pure payload handling for `KickAssAnime` (Android's `KickAssAnimeCodec`).
enum KickAssAnimeCodec {
    struct Episode: Equatable {
        var number: Int
        var slug: String
        var title: String?
    }

    static func searchResults(_ root: JSON) -> [KickAssAnime.Show] {
        (root["result"]?.array ?? []).compactMap { row in
            guard let slug = row["slug"]?.string else { return nil }
            return KickAssAnime.Show(slug: slug, title: row["title_en"]?.string ?? row["title"]?.string ?? slug,
                                     locales: Set((row["locales"]?.array ?? []).compactMap(\.string)),
                                     year: row["year"]?.number.map { Int($0) }, type: row["type"]?.string)
        }
    }

    /// Every number in the page index (`pages[].eps`), or the rows on this page when it has none.
    static func episodeNumbers(_ root: JSON) -> Set<Int> {
        let fromPages = Set((root["pages"]?.array ?? []).flatMap { ($0["eps"]?.array ?? []).compactMap { $0.number.map { Int($0) } } }.filter { $0 > 0 })
        if !fromPages.isEmpty { return fromPages }
        return Set(episodes(root).map(\.number).filter { $0 > 0 })
    }

    static func episode(_ root: JSON, _ number: Int) -> Episode? {
        episodes(root).first { $0.number == number }
    }

    static func vidStreamingURL(_ root: JSON) -> String? {
        (root["servers"]?.array ?? []).compactMap { server -> String? in
            guard let src = server["src"]?.string else { return nil }
            let name = server["name"]?.string ?? ""
            return name.caseInsensitiveCompare("VidStreaming") == .orderedSame || src.range(of: "source=vidstream", options: .caseInsensitive) != nil ? src : nil
        }.first
    }

    static func playerID(_ player: String) -> String? {
        URLComponents(string: player)?.queryItems?.first { $0.name == "id" }?.value?.nonBlank
    }

    /// The player page's Astro props, entity-encoded: `"language":[0,"eng"],"name":[0,"English"],"src":[0,"….vtt"]`.
    private static let track = Pattern(#""language":\[0,"([^"]*)"\],"name":\[0,"([^"]*)"\],"src":\[0,"([^"]+\.vtt)"\]"#)

    static func subtitles(_ html: String) -> [SubtitleTrack] {
        let decoded = HTML.decodeEntities(html)
        var seen = Set<String>()
        return track.matches(in: decoded).compactMap { match in
            guard let address = match[3], let url = URL(string: address), seen.insert(address).inserted else { return nil }
            let language = match[1]?.nonBlank ?? "und"
            return SubtitleTrack(url: url, label: match[2]?.nonBlank ?? language, language: language)
        }
    }

    private static func episodes(_ root: JSON) -> [Episode] {
        (root["result"]?.array ?? []).compactMap { row in
            guard let number = row["episode_number"]?.number, let slug = row["slug"]?.string else { return nil }
            return Episode(number: Int(number), slug: slug, title: row["title"]?.string)
        }
    }
}
