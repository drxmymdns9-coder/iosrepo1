import Foundation

/// Miruro's catalog API: AniList id → Miruro title → episodes → every server for an episode.
/// A port of the desktop's `crates/core/src/miruro.rs`, which follows the Android app.
///
/// Plain GETs under `{mirror}/api/`. The catalog paths answer `application/octet-stream`: the
/// bytes XOR'd with the ASCII of `miruro/catalog`, then gzip. Traps, learned on Android:
///
/// - an unrecognised query is `400 Unsupported catalog request`, so the query strings are literal
///   requirements: `limit=100` for the title lookup, and `limit=10000` alone for the episodes;
/// - specials come in the episode list with numbers of their own (20001…) and are filtered out;
/// - 4xx is the API's answer and every mirror serves the same API, so only transport failures and
///   5xx move on to the next mirror.
///
/// Measured from this PC on 2026-10-11: the API answers an iPhone Safari User-Agent, and the HLS
/// it hands out plays with the per-server `headers` alone (a Referer, sometimes an Origin).
public actor Miruro: StreamProvider {
    public nonisolated let id = "miruro"
    public nonisolated let name = "Miruro"

    public static let mirrors = [
        "https://www.miruro.to", "https://www.miruro.tv", "https://www.miruro.bz",
        "https://www.miruro.ru", "https://www.miruro.cx",
    ]
    static let catalogKey = Array("miruro/catalog".utf8)
    static let configTTL: TimeInterval = 60 * 60
    static let listingTTL: TimeInterval = 15 * 60

    /// Providers whose streams the app can't open. Empty since 2026-10-12: animepahe's Kwik CDN
    /// answers with the Referer Miruro names (it refused on 2026-10-11), and the IVs its playlists
    /// leave implicit are written out by the app's stream proxy (`StreamRewrite.explicitKwikIVs`).
    static let unplayable: Set<String> = []

    struct ProviderConfig: Equatable, Sendable {
        var key: String
        var label: String
        var visible: Bool
        /// An `embed` entry (`relationship: "embed"`) shows its `parent` provider's servers as the
        /// site's own web players rather than streams.
        var parent: String? = nil
        var isEmbed = false
    }

    struct Title: Equatable, Sendable {
        var id: String
        var subCount: Int?
        var dubCount: Int?
    }

    typealias Fetch = @Sendable (URL, [String: String]) async throws -> (Data, String?)

    private let fetch: Fetch
    private var preferredMirror: String?
    private var config: (at: Date, entries: [ProviderConfig])?
    private var titles: [Int: Title?] = [:]
    private var listings: [Int: (at: Date, listing: EpisodeListing)] = [:]

    public init() {
        fetch = { url, headers in
            let (data, response) = try await HTTP.data(url, headers: headers)
            guard (200..<300).contains(response.statusCode) else {
                throw HTTPError(status: response.statusCode, "Miruro answered HTTP \(response.statusCode)")
            }
            return (data, response.value(forHTTPHeaderField: "Content-Type"))
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        if let cached = listings[media.id], Date().timeIntervalSince(cached.at) < Self.listingTTL {
            return cached.listing
        }
        guard let title = try await title(media.id) else { return .empty }
        let root = try await get("v1/anime/\(title.id)/episodes?limit=10000")
        let listing = Self.listing(episodes: Self.parseEpisodes(root), title: title)
        Log.info("miruro", "\(media.id): \(listing.episodes.count) episodes, \(listing.subbed.count) sub, \(listing.dubbed.count) dub")
        listings[media.id] = (Date(), listing)
        return listing
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard let title = try await title(media.id) else { throw ProviderError.titleNotFound(provider: name) }
        let config = try await providerConfig()
        let play = try await get("v1/anime/\(title.id)/episodes/\(episode)/play")
        let sources = Self.parseSources(config: config, play: play, audio: audio)
        let offered = (play["tracks"]?.array ?? []).compactMap { track -> String? in
            guard let name = track["track"]?.string else { return nil }
            let providers = (track["providers"]?.array ?? []).compactMap { $0["provider"]?.string }
            return "\(name)[\(providers.joined(separator: ","))]"
        }
        Log.info("miruro", "\(media.id) ep \(episode) \(audio.rawValue): \(sources.count) playable of \(offered.joined(separator: " ")) → \(sources.map(\.label).joined(separator: ", "))")
        return sources
    }

    /// Every source including the ones `unplayable` leaves out, for the server probe.
    func everySource(anilistID: Int, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard let title = try await title(anilistID) else { return [] }
        let play = try await get("v1/anime/\(title.id)/episodes/\(episode)/play")
        return Self.parseSources(config: try await providerConfig(), play: play, audio: audio, skipping: [])
    }

    /// Every provider, server and stream an episode's play response offers, unfiltered: what the
    /// server probe prints to see what the parser leaves out.
    func rawPlay(anilistID: Int, episode: Int) async throws -> [String] {
        guard let title = try await title(anilistID) else { return [] }
        let play = try await get("v1/anime/\(title.id)/episodes/\(episode)/play")
        var lines: [String] = []
        for track in play["tracks"]?.array ?? [] {
            let name = track["track"]?.string ?? "?"
            for provider in track["providers"]?.array ?? [] {
                let key = provider["provider"]?.string ?? "?"
                let fields = (provider.object ?? [:]).keys.sorted().joined(separator: ",")
                let servers = (provider["servers"]?.array ?? []).map { server -> String in
                    let streams = (server["streams"]?.array ?? []).map { stream -> String in
                        let host = stream["url"]?.string.flatMap { URL(string: $0)?.host } ?? "?"
                        let streamFields = (stream.object ?? [:]).keys.sorted().joined(separator: "/")
                        return "\(stream["format"]?.string ?? stream["type"]?.string ?? "?"):\(host){\(streamFields)}"
                    }
                    let headers = (server["headers"]?.object ?? [:]).keys.sorted().joined(separator: "/")
                    return "\(server["server"]?.string ?? "?")[\(headers)](\(streams.joined(separator: ",")))"
                }
                lines.append("\(name) \(key) {\(fields)}: \(servers.joined(separator: " "))")
            }
        }
        return lines
    }

    // MARK: - Requests

    private func title(_ anilistID: Int) async throws -> Title? {
        if let cached = titles[anilistID] { return cached }
        let title = Self.parseTitle(try await get("v1/anime?anilist_id_in=\(anilistID)&limit=100"))
        if let title {
            Log.info("miruro", "\(anilistID) → \(title.id) (sub \(title.subCount.map(String.init) ?? "?"), dub \(title.dubCount.map(String.init) ?? "?"))")
        } else {
            Log.info("miruro", "\(anilistID): no Miruro entry")
        }
        titles[anilistID] = title
        return title
    }

    private func providerConfig() async throws -> [ProviderConfig] {
        if let config, Date().timeIntervalSince(config.at) < Self.configTTL { return config.entries }
        let entries = Self.parseConfig(try await get("config"))
        config = (Date(), entries)
        return entries
    }

    /// GET `{mirror}/api/{path}`, decoded to JSON, walking mirrors on transport failure or 5xx.
    private func get(_ path: String) async throws -> JSON {
        let order = [preferredMirror].compactMap { $0 } + Self.mirrors.filter { $0 != preferredMirror }
        var lastError: Error?
        for origin in order {
            guard let url = URL(string: "\(origin)/api/\(path)") else { continue }
            let headers = [
                "User-Agent": HTTP.safariUserAgent,
                "Referer": "\(origin)/",
                "Accept": "application/json, application/octet-stream;q=0.9, */*;q=0.8",
                "Sec-Fetch-Site": "same-origin",
                "Sec-Fetch-Mode": "cors",
                "Sec-Fetch-Dest": "empty",
            ]
            let (body, contentType): (Data, String?)
            do {
                (body, contentType) = try await fetch(url, headers)
            } catch let error as HTTPError where (error.status ?? 500) < 500 {
                Log.warning("miruro", "\(path) refused by \(origin): \(Log.describe(error))")
                throw error
            } catch {
                Log.warning("miruro", "mirror \(origin) failed for \(path): \(Log.describe(error)); trying the next")
                lastError = error
                continue
            }
            preferredMirror = origin
            do {
                let text = contentType?.hasPrefix("application/octet-stream") == true
                    ? try Self.decodeCatalogBody(body)
                    : body
                return try JSON.parse(text)
            } catch {
                Log.error("miruro", "\(path): unreadable \(contentType ?? "?") body of \(body.count)B: \(error)")
                throw error
            }
        }
        throw lastError ?? HTTPError("No Miruro mirror answered")
    }

    // MARK: - Parsing

    static func decodeCatalogBody(_ body: Data) throws -> Data {
        var bytes = [UInt8](body)
        for index in bytes.indices { bytes[index] ^= catalogKey[index % catalogKey.count] }
        return try Gzip.decompress(Data(bytes))
    }

    /// `streaming` entries in `providerOrder`; unknown keys sort last.
    static func parseConfig(_ root: JSON) -> [ProviderConfig] {
        let order = (root["providerOrder"]?.array ?? []).compactMap(\.string)
        let entries = (root["streaming"]?.object ?? [:]).compactMap { key, value -> ProviderConfig? in
            guard value.object != nil else { return nil }
            return ProviderConfig(
                key: key,
                label: value["label"]?.string ?? key,
                visible: value["visible"]?.bool ?? true,
                parent: value["parent"]?.string,
                isEmbed: value["relationship"]?.string == "embed"
            )
        }
        func rank(_ key: String) -> Int { order.firstIndex(of: key) ?? Int.max }
        return entries.sorted { (rank($0.key), $0.key) < (rank($1.key), $1.key) }
    }

    static func parseTitle(_ root: JSON) -> Title? {
        guard let first = root["data"]?.array?.first, let id = first["id"]?.string else { return nil }
        let counts = first["episode_counts"]
        return Title(id: id, subCount: counts?["sub"]?.number.map(Int.init), dubCount: counts?["dub"]?.number.map(Int.init))
    }

    static func parseEpisodes(_ root: JSON) -> [EpisodeInfo] {
        var seen = Set<Int>()
        let episodes = (root["data"]?.array ?? []).compactMap { row -> EpisodeInfo? in
            // The numbered run only; a row without a kind is taken as regular.
            if let kind = row["kind"]?.string, kind != "regular" { return nil }
            guard let value = row["episode_number"]?.number, value >= 1, value == value.rounded() else { return nil }
            var episode = EpisodeInfo(number: Int(value))
            episode.title = row["title"]?.string
            episode.synopsis = row["synopsis"]?.string
            episode.thumbnail = row["thumbnail_url"]?.string.flatMap(URL.init(string:))
            episode.airedOn = row["aired_on"]?.string
            episode.duration = row["duration_seconds"]?.number
            episode.isFiller = row["canon_type"]?.string?.contains("filler") == true
            episode.skip = parseSkip(row["skip_times"])
            return seen.insert(episode.number).inserted ? episode : nil
        }
        return episodes.sorted { $0.number < $1.number }
    }

    /// Kinds seen: `op`, `ed`, `mixed_op`, `mixed_ed`. The plain kind wins: a mixed window
    /// overlaps the episode's own content.
    static func parseSkip(_ windows: JSON?) -> SkipTimes? {
        let rows = windows?.array ?? []
        func window(_ kind: String) -> SkipTimes.Window? {
            for candidate in [kind, "mixed_\(kind)"] {
                if let row = rows.first(where: { $0["kind"]?.string == candidate }),
                   let start = row["start_seconds"]?.number, let end = row["end_seconds"]?.number, end > start {
                    return .init(start: start, end: end)
                }
            }
            return nil
        }
        let skip = SkipTimes(intro: window("op"), outro: window("ed"))
        return skip.intro == nil && skip.outro == nil ? nil : skip
    }

    /// The first `sub_count` episodes are out subbed and the first `dub_count` dubbed. An airing
    /// show lists episodes before they air, so the counts, not the list, say what plays.
    static func listing(episodes: [EpisodeInfo], title: Title) -> EpisodeListing {
        func firstNumbers(_ count: Int?) -> Set<Int> {
            guard let count else { return Set(episodes.map(\.number)) }
            return Set(episodes.prefix(max(0, count)).map(\.number))
        }
        return EpisodeListing(episodes: episodes, subbed: firstNumbers(title.subCount), dubbed: firstNumbers(title.dubCount ?? 0))
    }

    /// One source per server for the asked audio, in the site's provider order. DASH, hidden
    /// providers and `unplayable` ones are left out. Sub also takes the soft-subbed (`ssub`)
    /// servers, after every hard-subbed one: the hard subs play with nothing to load beside them,
    /// the soft subs bring their subtitle files. The visible `embed` entries follow, as Android
    /// shows them: their parent's server pages (`embed.url`), played in the web view.
    static func parseSources(config: [ProviderConfig], play: JSON, audio: AudioTrack, skipping: Set<String> = unplayable) -> [VideoSource] {
        var ranked: [(rank: Int, order: Int, source: VideoSource)] = []
        let wanted: [String] = audio == .sub ? ["sub", "ssub"] : ["dub"]
        for track in play["tracks"]?.array ?? [] {
            guard let name = track["track"]?.string, let trackRank = wanted.firstIndex(of: name) else { continue }
            let soft = name == "ssub"
            for provider in track["providers"]?.array ?? [] {
                guard let key = provider["provider"]?.string, !skipping.contains(key) else { continue }
                let configRank = config.firstIndex { $0.key == key }
                let entry = configRank.map { config[$0] }
                if entry?.visible == false { continue }
                let rank = trackRank * 1_000 + (configRank ?? 999)
                let subtitles = parseSubtitles(provider["subtitles"])
                for server in provider["servers"]?.array ?? [] {
                    let headers = (server["headers"]?.object ?? [:]).compactMapValues(\.string)
                    for stream in server["streams"]?.array ?? [] {
                        guard let text = stream["url"]?.string, let url = URL(string: text) else { continue }
                        let format = stream["format"]?.string
                            ?? (text.contains(".mpd") ? "dash" : text.contains(".mp4") ? "mp4" : "hls")
                        guard let kind = VideoSource.Kind(rawValue: format), kind != .embed else { continue }
                        let source = VideoSource(
                            url: url,
                            provider: entry?.label ?? key,
                            server: server["server"]?.string ?? key,
                            kind: kind,
                            headers: headers,
                            subtitles: subtitles,
                            softSub: soft
                        )
                        ranked.append((rank, ranked.count, source))
                        break
                    }
                }
            }
        }
        return ranked.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }.map(\.source) + parseEmbeds(config: config, play: play, audio: audio)
    }

    /// Android's `MiruroCatalog.sources` for an embed entry: the first wanted track carrying the
    /// parent provider, every server's (and stream's) `embed.url` on it, with the server's headers.
    static func parseEmbeds(config: [ProviderConfig], play: JSON, audio: AudioTrack) -> [VideoSource] {
        let wanted: [String] = audio == .sub ? ["sub", "ssub"] : ["dub"]
        let tracks = play["tracks"]?.array ?? []
        var seen = Set<URL>()
        var sources: [VideoSource] = []
        for entry in config where entry.isEmbed && entry.visible {
            guard let parent = entry.parent, let provider = wanted.lazy.compactMap({ name in
                tracks.first { $0["track"]?.string == name }?["providers"]?.array?.first { $0["provider"]?.string == parent }
            }).first else { continue }
            for server in provider["servers"]?.array ?? [] {
                let headers = (server["headers"]?.object ?? [:]).compactMapValues(\.string)
                let pages = [server["embed"]] + (server["streams"]?.array ?? []).map { $0["embed"] }
                for page in pages {
                    guard let text = page?["url"]?.string ?? page?.string, let url = URL(string: text), seen.insert(url).inserted else { continue }
                    sources.append(VideoSource(url: url, provider: entry.label, server: server["server"]?.string ?? parent, kind: .embed, headers: headers))
                }
            }
        }
        return sources
    }

    /// A provider's subtitle files: `{file|url, label, language, default}`.
    static func parseSubtitles(_ list: JSON?) -> [SubtitleTrack] {
        (list?.array ?? []).compactMap { row in
            guard let text = row["file"]?.string ?? row["url"]?.string, let url = URL(string: text) else { return nil }
            let language = row["language"]?.string ?? "en"
            return SubtitleTrack(url: url, label: row["label"]?.string ?? language.uppercased(), language: language, isDefault: row["default"]?.bool ?? false)
        }
    }
}
