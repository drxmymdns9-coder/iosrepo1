import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// UniqueStream (anime.uniquestream.net), ported from the Android app's `UniqueStreamProvider`: a
/// Crunchyroll mirror behind an open JSON API. `/search` finds the series, `/series/{id}` lists
/// its seasons (each with a MAL id), `/season/{id}/episodes` pages the episodes, and
/// `/episode/{id}/media/hls/{ja-JP|en-US}` hands out a signed HLS master.
///
/// Its AES-128 `key.bin` is gated on a header only the site's player sends, but the key is the
/// media id read as hex bytes, so the source carries it (`VideoSource.aesKey`) and the app's
/// stream proxy answers the key requests itself. Japanese audio ships no soft subtitles, so a sub
/// plays the burnt-in en-US encode beside it.
///
/// The API black-holes bursts from one address, so requests stop at the first title that finds
/// anything and the first series whose seasons carry the MAL id.
public actor UniqueStream: StreamProvider {
    public nonisolated let id = "uniquestream"
    public nonisolated let name = "UniqueStream"

    struct Catalog: Sendable {
        var seasons: [UniqueStreamParser.Season]
        var episodes: [UniqueStreamParser.Episode]
    }

    static let base = "https://anime.uniquestream.net/api/v1"
    static let subLocale = "ja-JP"
    static let dubLocale = "en-US"
    static let pageSize = 20
    static let maxEpisodePages = 15
    static let sagaJumpPages = 8
    static let maxSearchQueries = 3
    static let maxProbeSeries = 4

    typealias Fetch = @Sendable (URL) async throws -> (Int, Data)

    private let fetch: Fetch
    private var catalogs: [Int: Catalog] = [:]

    public init() {
        fetch = { url in
            var request = URLRequest(url: url)
            request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json, */*", forHTTPHeaderField: "Accept")
            let (data, response) = try await HTTP.data(for: request)
            return (response.statusCode, data)
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        guard let catalog = try await catalog(media) else { return .empty }
        let sub = Set(catalog.episodes.filter { $0.audioLocales.contains(Self.subLocale) }.map(\.number))
        let dub = Set(catalog.episodes.filter { $0.audioLocales.contains(Self.dubLocale) }.map(\.number))
        let numbers = sub.union(dub).sorted()
        return EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: sub, dubbed: dub)
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard let catalog = try await catalog(media) else { throw ProviderError.titleNotFound(provider: name) }
        var entry = catalog.episodes.first { $0.number == episode }
        if entry == nil, let season = UniqueStreamParser.seasonForEpisode(catalog.seasons, episode) {
            entry = try await pages(season, budget: Self.sagaJumpPages).episodes.first { $0.number == episode }
        }
        guard let entry else { throw ProviderError.episodeNotFound(provider: name, episode: episode) }
        let locale = audio == .dub ? Self.dubLocale : Self.subLocale
        guard let media = UniqueStreamParser.media(try await json("/episode/\(entry.contentID)/media/hls/\(locale)")),
              let playback = UniqueStreamParser.playback(media, audio), let url = URL(string: playback.url) else {
            throw ProviderError.noStreams(episode: episode, audio: audio)
        }
        return [VideoSource(url: url, provider: name, server: playback.burntIn ? "English subtitles" : audio == .dub ? "English" : "Japanese",
                            kind: .hls, subtitles: playback.subtitles, softSub: !playback.subtitles.isEmpty,
                            aesKey: UniqueStreamParser.key(media.mediaID))]
    }

    // MARK: - Catalogue

    private func catalog(_ media: Media) async throws -> Catalog? {
        if let cached = catalogs[media.id] { return cached }
        let titles = Array(ProviderSupport.titles(media).prefix(Self.maxSearchQueries))
        var candidates: [UniqueStreamParser.Candidate] = []
        for title in titles {
            let encoded = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? title
            candidates = UniqueStreamParser.search((try? await json("/search?query=\(encoded)&limit=20")) ?? .null)
            if !candidates.isEmpty { break }
        }
        guard !candidates.isEmpty else { return nil }
        let ranked = candidates.sorted { score(titles, $0.title) > score(titles, $1.title) }
        let mal = media.idMal.map(String.init)
        var seasons: [UniqueStreamParser.Season] = []
        for candidate in ranked.prefix(Self.maxProbeSeries) {
            if let root = try? await json("/series/\(candidate.contentID)") { seasons += UniqueStreamParser.seasons(root) }
            if let mal, seasons.contains(where: { $0.malID == mal }) { break }
        }
        var seen = Set<String>()
        let chosen = UniqueStreamParser.select(seasons.filter { seen.insert($0.contentID).inserted }, malID: mal, titles: titles)
        guard !chosen.isEmpty else { return nil }
        var episodes: [UniqueStreamParser.Episode] = []
        var budget = Self.maxEpisodePages
        for season in chosen where budget > 0 {
            let (found, used) = try await pages(season, budget: budget)
            episodes += found
            budget -= used
        }
        var numbers = Set<Int>()
        let catalog = Catalog(seasons: chosen, episodes: episodes.filter { numbers.insert($0.number).inserted })
        if !catalog.episodes.isEmpty { catalogs[media.id] = catalog }
        return catalog
    }

    /// One season, twenty at a time, until a short page, the announced count, or `budget`.
    private func pages(_ season: UniqueStreamParser.Season, budget: Int) async throws -> (episodes: [UniqueStreamParser.Episode], used: Int) {
        var out: [UniqueStreamParser.Episode] = []
        var used = 0, fetched = 0
        while used < budget {
            used += 1
            guard let rows = try await json("/season/\(season.contentID)/episodes?limit=\(Self.pageSize)&page=\(used)").array else { break }
            out += UniqueStreamParser.episodes(.array(rows))
            fetched += rows.count
            if rows.count < Self.pageSize || (season.episodeCount.map { fetched >= $0 } ?? false) { break }
        }
        return (out, used)
    }

    private func score(_ titles: [String], _ candidate: String) -> Double {
        titles.map { TitleMatching.selectionScore($0, candidate) }.max() ?? 0
    }

    private func json(_ path: String) async throws -> JSON {
        let (status, data) = try await fetch(URL(string: Self.base + path)!)
        guard status == 200 else { throw HTTPError(status: status, "UniqueStream answered HTTP \(status)") }
        return try JSON.parse(data)
    }
}

/// Pure handling for UniqueStream's payloads (Android's `UniqueStreamParser`).
enum UniqueStreamParser {
    struct Candidate: Equatable { var contentID: String; var title: String }
    struct Season: Equatable, Sendable { var contentID: String; var title: String; var episodeCount: Int?; var malID: String? }
    struct Episode: Equatable, Sendable { var number: Int; var contentID: String; var audioLocales: Set<String> }
    struct Media: Equatable { var mediaID: String?; var playlist: String?; var hardSubEnglish: String?; var subtitles: [SubtitleTrack] }
    struct Playback: Equatable { var url: String; var subtitles: [SubtitleTrack]; var burntIn: Bool }

    /// Series only: a movie has no seasons and can't resolve episodes.
    static func search(_ root: JSON) -> [Candidate] {
        (root["series"]?.array ?? []).compactMap { row in
            row["content_id"]?.string.map { Candidate(contentID: $0, title: row["title"]?.string ?? "") }
        }
    }

    static func seasons(_ root: JSON) -> [Season] {
        (root["seasons"]?.array ?? []).compactMap { row in
            row["content_id"]?.string.map { Season(contentID: $0, title: row["title"]?.string ?? "",
                                                   episodeCount: row["episode_count"]?.number.map { Int($0) }, malID: row["mal_id"]?.string) }
        }
    }

    /// The MAL id's season; else a season titled like the show; else every season, read as one
    /// absolutely numbered catalogue (One Piece's sagas carry no MAL id and score nothing).
    static func select(_ seasons: [Season], malID: String?, titles: [String]) -> [Season] {
        guard !seasons.isEmpty else { return [] }
        if let malID, let exact = seasons.first(where: { $0.malID == malID }) { return [exact] }
        func score(_ season: Season) -> Double { titles.map { TitleMatching.selectionScore($0, season.title) }.max() ?? 0 }
        guard let best = seasons.max(by: { score($0) < score($1) }) else { return [] }
        return score(best) >= 0.5 ? [best] : seasons
    }

    /// The saga holding absolute episode `number`, from the announced counts; nil unless every
    /// season announces one (a single gap would slide every later range).
    static func seasonForEpisode(_ seasons: [Season], _ number: Int) -> Season? {
        guard seasons.count >= 2, seasons.allSatisfy({ ($0.episodeCount ?? 0) > 0 }) else { return nil }
        var start = 1
        for season in seasons {
            let end = start + season.episodeCount! - 1
            if (start...end).contains(number) { return season }
            start = end + 1
        }
        return nil
    }

    /// Whole-numbered episodes only: clips and recaps ("7.5") are dropped.
    static func episodes(_ root: JSON) -> [Episode] {
        (root.array ?? []).compactMap { row in
            guard row["is_clip"]?.bool != true, let raw = row["episode_number"]?.number, raw >= 1, raw == raw.rounded(),
                  let id = row["content_id"]?.string else { return nil }
            return Episode(number: Int(raw), contentID: id, audioLocales: Set((row["audio_locales"]?.array ?? []).compactMap(\.string)))
        }
    }

    /// The HLS block; nil when there isn't one (`hls_not_ready`). DASH is DRM'd and ignored.
    static func media(_ root: JSON) -> Media? {
        guard let hls = root["hls"], hls.object != nil else { return nil }
        let hard = (hls["hard_subs"]?.array ?? []).first { $0["locale"]?.string == "en-US" }?["playlist"]?.string
        let subtitles = (hls["subtitles"]?.array ?? []).compactMap { row -> SubtitleTrack? in
            guard let text = row["url"]?.string, let url = URL(string: text) else { return nil }
            let label = row["language"]?.string ?? "Subtitle"
            return SubtitleTrack(url: url, label: label, language: label.split(separator: "-").first.map { $0.lowercased() } ?? "und")
        }
        return Media(mediaID: root["media_id"]?.string, playlist: hls["playlist"]?.string, hardSubEnglish: hard, subtitles: subtitles)
    }

    /// A dub takes the clean playlist; a sub takes it only with soft subtitles, else the burnt-in
    /// en-US encode (same media id, so the same key).
    static func playback(_ media: Media, _ audio: AudioTrack) -> Playback? {
        if audio == .dub {
            guard let url = media.playlist ?? media.hardSubEnglish else { return nil }
            return Playback(url: url, subtitles: media.subtitles, burntIn: media.playlist == nil)
        }
        if let clean = media.playlist, !media.subtitles.isEmpty { return Playback(url: clean, subtitles: media.subtitles, burntIn: false) }
        if let hard = media.hardSubEnglish { return Playback(url: hard, subtitles: [], burntIn: true) }
        return media.playlist.map { Playback(url: $0, subtitles: media.subtitles, burntIn: false) }
    }

    /// The segment key: the 32-hex-digit media id as 16 bytes.
    static func key(_ mediaID: String?) -> Data? {
        guard let mediaID, mediaID.count == 32 else { return nil }
        var bytes: [UInt8] = []
        var index = mediaID.startIndex
        while index < mediaID.endIndex {
            let next = mediaID.index(index, offsetBy: 2)
            guard let byte = UInt8(mediaID[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
