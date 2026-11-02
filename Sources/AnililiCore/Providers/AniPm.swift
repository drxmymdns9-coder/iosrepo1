import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ani.pm, ported from the Android app's `AniPmProvider`: keyed by AniList id, JSON throughout, and
/// played through its "Settlar" embed service, whose session hands back a plain HLS master.
///
/// ```
/// GET ani.pm/api/anime/anipm-server/_packages?anilistId=                 -> {episodes:{"1":{sub,dub}}}
/// GET ani.pm/api/anime/playback-bootstrap/anilist/{id}?ep=&lang=&core=0  -> settlarSelection
/// GET ani.pm/api/anime/settlar/session?selection=&provider=anipm&ep=&channel= -> embedUrl ?t=
/// GET embed.settlar.io/api/embed/session?t=                              -> source, subtitles
/// ```
///
/// `_packages` is the catalogue because it's what the server actually plays from. All three hosts
/// are behind a Cloudflare TLS and User-Agent gate that a browser User-Agent on the platform's own
/// stack passes; nothing else is needed, no Referer and no cookie.
public actor AniPm: StreamProvider {
    public nonisolated let id = "anipm"
    public nonisolated let name = "Ani.pm"

    static let base = "https://ani.pm"
    static let embed = "https://embed.settlar.io"

    typealias Fetch = @Sendable (URL) async throws -> (Int, Data)

    private let fetch: Fetch

    public init() {
        fetch = { url in
            var request = URLRequest(url: url)
            request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await HTTP.data(for: request)
            return (response.statusCode, data)
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        guard let root = try await json(Self.base + "/api/anime/anipm-server/_packages", ["anilistId": "\(media.id)"]) else { return .empty }
        return AniPmParser.listing(root)
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        let channel = audio == .dub ? "dub" : "sub"
        guard let bootstrap = try await json(Self.base + "/api/anime/playback-bootstrap/anilist/\(media.id)",
                                             ["ep": "\(episode)", "lang": channel, "core": "0"]) else {
            throw ProviderError.episodeNotFound(provider: name, episode: episode)
        }
        // A missing dub isn't refused: the bootstrap answers with the sub and says so only here.
        let effective = bootstrap["effectiveLanguage"]?.string
        guard effective == channel else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        guard let selection = bootstrap["settlarSelection"]?.string else { throw HTTPError("ani.pm offered no selection") }
        let session = try await json(Self.base + "/api/anime/settlar/session",
                                     ["selection": selection, "provider": "anipm", "ep": "\(episode)", "channel": channel, "telemetry": "0"])
        guard let embedText = session?["embedUrl"]?.string,
              let token = URLComponents(string: embedText)?.queryItems?.first(where: { $0.name == "t" })?.value else {
            throw HTTPError("ani.pm's session carried no embed")
        }
        guard let player = try await json(Self.embed + "/api/embed/session", ["t": token]),
              let source = AniPmParser.source(player, provider: name) else {
            throw HTTPError("Settlar's session carried no stream")
        }
        Log.info("anipm", "\(media.id) ep \(episode) \(channel): \(source.subtitles.count) subtitle tracks")
        return [source]
    }

    /// GET with query items; nil for a 404, which is ani.pm's "not here".
    private func json(_ base: String, _ query: [String: String]) async throws -> JSON? {
        var components = URLComponents(string: base)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (status, data) = try await fetch(components.url!)
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw HTTPError(status: status, "ani.pm answered HTTP \(status)") }
        return try? JSON.parse(data)
    }
}

/// Pure payload handling for `AniPm`, kept network-free for tests.
enum AniPmParser {
    static func listing(_ root: JSON) -> EpisodeListing {
        var sub = Set<Int>(), dub = Set<Int>()
        for (key, entry) in root["episodes"]?.object ?? [:] {
            guard let number = Int(key), number > 0 else { continue }
            if entry["sub"]?.bool == true { sub.insert(number) }
            if entry["dub"]?.bool == true { dub.insert(number) }
        }
        let numbers = sub.union(dub).sorted()
        return EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: sub, dubbed: dub)
    }

    /// The master Settlar plays, with its HTTPS subtitles, the default first.
    static func source(_ session: JSON, provider: String) -> VideoSource? {
        guard let text = session["source"]?.string, text.hasPrefix("https://"), let url = URL(string: text) else { return nil }
        var seen = Set<String>()
        let subtitles = (session["subtitles"]?.array ?? [])
            .filter { $0["url"]?.string?.hasPrefix("https://") == true }
            .sorted { ($0["default"]?.bool == true ? 0 : 1) < ($1["default"]?.bool == true ? 0 : 1) }
            .compactMap { track -> SubtitleTrack? in
                guard let address = track["url"]?.string, let url = URL(string: address), seen.insert(address).inserted else { return nil }
                let code = track["srclang"]?.string?.lowercased() ?? ""
                return SubtitleTrack(url: url, label: track["label"]?.string?.trimmingCharacters(in: .whitespaces) ?? "Subtitles",
                                     language: languages[code] ?? (code.isEmpty ? "und" : code), isDefault: track["default"]?.bool ?? false)
            }
        let kind: VideoSource.Kind = session["kind"]?.string == "mp4" ? .mp4 : .hls
        return VideoSource(url: url, provider: provider, server: "Settlar", kind: kind, subtitles: subtitles, softSub: !subtitles.isEmpty)
    }

    /// Settlar mixes two- and three-letter codes in one list.
    static let languages = [
        "ind": "id", "tha": "th", "chi": "zh", "zho": "zh", "kor": "ko", "pol": "pl", "tur": "tr", "jpn": "ja", "eng": "en",
        "spa": "es", "por": "pt", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "ita": "it", "rus": "ru", "ara": "ar",
        "vie": "vi", "may": "ms", "msa": "ms",
    ]
}
