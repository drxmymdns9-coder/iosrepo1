import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AnimeAV1 (animeav1.com), ported from the Android app's `AnimeAv1Provider`: Spanish subtitles
/// and, where there is one, a Spanish dub. Declared Spanish, so it only plays automatically for a
/// viewer whose language settings ask for Spanish (see `SourceHub`); picked by hand, it always
/// plays.
///
/// A SvelteKit site: every page has a `__data.json` twin, "devalue"-flattened (see
/// `AnimeAV1Parser.pageData`). The title page carries the MAL id, so a search hit is confirmed.
/// Of the embeds an episode lists, VOE (an HLS master in an encoded config, no Referer) and
/// YourUpload (`og:video`, an MP4 behind its Referer) are read; MP4Upload, the others' slow
/// fallback on Android, isn't ported.
public actor AnimeAV1: StreamProvider {
    public nonisolated let id = "animeav1"
    public nonisolated let name = "AnimeAV1 (Español)"
    public nonisolated var declaredLanguage: String? { "Spanish" }

    struct Entry: Sendable { var slug: String; var episodes: [Int] }

    static let base = "https://animeav1.com"
    static let confirmLimit = 3

    typealias Fetch = @Sendable (URL, String) async throws -> (Int, String)

    private let fetch: Fetch
    private var entries: [Int: Entry] = [:]

    public init() {
        fetch = { url, referer in
            var request = URLRequest(url: url)
            request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(referer, forHTTPHeaderField: "Referer")
            let (data, response) = try await HTTP.data(for: request)
            return (response.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        guard let entry = try await entry(media), let first = entry.episodes.first else { return .empty }
        // The dub is stated per episode; the first episode's claim is trusted across the run.
        let dubbed = (try? AnimeAV1Parser.variants(try await data("media/\(entry.slug)/\(first)")))?.contains("DUB") == true
        let numbers = Set(entry.episodes)
        return EpisodeListing(episodes: entry.episodes.map(EpisodeInfo.init(number:)), subbed: numbers, dubbed: dubbed ? numbers : [])
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard let entry = try await entry(media), entry.episodes.contains(episode) else {
            throw ProviderError.episodeNotFound(provider: name, episode: episode)
        }
        let embeds = AnimeAV1Parser.embeds(try await data("media/\(entry.slug)/\(episode)"), audio == .dub ? "DUB" : "SUB")
            .filter { AnimeAV1Parser.hostRank($0.server) != nil }
            .sorted { AnimeAV1Parser.hostRank($0.server)! < AnimeAV1Parser.hostRank($1.server)! }
        for embed in embeds {
            if let source = try? await resolve(embed, audio: audio) { return [source] }
        }
        throw ProviderError.noStreams(episode: episode, audio: audio)
    }

    private func resolve(_ embed: AnimeAV1Parser.Embed, audio: AudioTrack) async throws -> VideoSource? {
        guard let url = URL(string: embed.url) else { return nil }
        switch AnimeAV1Parser.hostRank(embed.server) {
        case 0?:
            var page = try await text(url, referer: Self.base + "/")
            if AnimeAV1Parser.voeConfig(page) == nil, let next = AnimeAV1Parser.voeRedirect(page).flatMap(URL.init(string:)) {
                page = try await text(next, referer: Self.base + "/")
            }
            guard let source = AnimeAV1Parser.voeConfig(page)?["source"]?.string, source.hasPrefix("http"), let stream = URL(string: source) else { return nil }
            return VideoSource(url: stream, provider: name, server: "VOE", kind: .hls)
        case 1?:
            guard let file = AnimeAV1Parser.ogVideo(try await text(url, referer: Self.base + "/")), let stream = URL(string: file) else { return nil }
            return VideoSource(url: stream, provider: name, server: "YourUpload", kind: .mp4, headers: ["Referer": "https://www.yourupload.com/"])
        default:
            return nil
        }
    }

    /// Found by title (romaji first: the site files them so), confirmed by the MAL id; without
    /// one, only an exact title is taken.
    private func entry(_ media: Media) async throws -> Entry? {
        if let known = entries[media.id] { return known }
        var seen = Set<String>()
        let titles = [media.title.romaji, media.title.english, media.title.userPreferred].compactMap { $0?.nonBlank }.filter { seen.insert($0).inserted }
        var hits: [AnimeAV1Parser.Hit] = []
        var slugs = Set<String>()
        for title in titles where hits.count < Self.confirmLimit {
            let page = try? await data("catalogo", query: ["search": title])
            hits += (page.map(AnimeAV1Parser.searchResults) ?? []).filter { slugs.insert($0.slug).inserted }
        }
        for hit in hits.prefix(Self.confirmLimit) {
            if media.idMal == nil, !titles.contains(where: { TitleMatching.normalize($0) == TitleMatching.normalize(hit.title) }) { continue }
            guard let detail = try? AnimeAV1Parser.detail(try await data("media/\(hit.slug)")) else { continue }
            if let mal = media.idMal, detail.malID != mal { continue }
            let entry = Entry(slug: hit.slug, episodes: detail.episodes)
            entries[media.id] = entry
            return entry
        }
        return nil
    }

    private func data(_ path: String, query: [String: String] = [:]) async throws -> JSON {
        var components = URLComponents(string: "\(Self.base)/\(path)/__data.json")!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let page = AnimeAV1Parser.pageData(try JSON.parse(Data(try await text(components.url!, referer: Self.base + "/").utf8))) else {
            throw HTTPError("AnimeAV1 returned no page data for \(path)")
        }
        return page
    }

    private func text(_ url: URL, referer: String) async throws -> String {
        let (status, body) = try await fetch(url, referer)
        guard status == 200 else { throw HTTPError(status: status, "AnimeAV1 answered HTTP \(status)") }
        return body
    }
}

/// Pure handling for AnimeAV1's pages (Android's `AnimeAv1Parser`).
enum AnimeAV1Parser {
    struct Hit: Equatable { var slug: String; var title: String }
    struct Detail: Equatable { var malID: Int?; var episodes: [Int] }
    struct Embed: Equatable { var server: String; var url: String }

    /// The route's own data out of a SvelteKit `__data.json`: the last `data` node, whose `data`
    /// array is devalue-flattened (every value in an object or array is the index of the real one;
    /// negative indices are undefined and the like).
    static func pageData(_ root: JSON) -> JSON? {
        guard let flat = root["nodes"]?.array?.last(where: { $0["type"]?.string == "data" })?["data"]?.array else { return nil }
        let value = hydrate(flat, 0, depth: 0)
        return value.object != nil ? value : nil
    }

    private static func hydrate(_ flat: [JSON], _ index: Int, depth: Int) -> JSON {
        guard index >= 0, index < flat.count, depth <= 64 else { return .null }
        switch flat[index] {
        case .object(let object):
            return .object(object.mapValues { reference($0, flat, depth) })
        case .array(let items):
            // A typed value (["Date", "…"]) carries literals, not references.
            if case .string? = items.first { return .array(items) }
            return .array(items.map { reference($0, flat, depth) })
        case let other:
            return other
        }
    }

    private static func reference(_ value: JSON, _ flat: [JSON], _ depth: Int) -> JSON {
        guard case .number(let index) = value else { return .null }
        return hydrate(flat, Int(index), depth: depth + 1)
    }

    static func searchResults(_ page: JSON) -> [Hit] {
        (page["results"]?.array ?? []).compactMap { row in row["slug"]?.string.map { Hit(slug: $0, title: row["title"]?.string ?? "") } }
    }

    /// The MAL id and the whole-numbered episodes (recaps are "12.5").
    static func detail(_ page: JSON) throws -> Detail {
        guard let media = page["media"], media.object != nil else { throw HTTPError("AnimeAV1 page carried no media") }
        let numbers = (media["episodes"]?.array ?? []).compactMap { row -> Int? in
            guard case .number(let value)? = row["number"], value > 0, value == value.rounded() else { return nil }
            return Int(value)
        }
        var malID: Int?
        if case .number(let value)? = media["malId"] { malID = Int(value) }
        return Detail(malID: malID, episodes: Array(Set(numbers)).sorted())
    }

    static func variants(_ page: JSON) -> Set<String> {
        Set((page["episode"]?["variants"]?.object ?? [:]).filter { ($0.value.number ?? 0) > 0 }.keys)
    }

    static func embeds(_ page: JSON, _ category: String) -> [Embed] {
        (page["embeds"]?[category]?.array ?? []).compactMap { row in
            guard let server = row["server"]?.string, let url = row["url"]?.string else { return nil }
            return Embed(server: server, url: url)
        }
    }

    /// The hosts that resolve without a browser, in the order worth trying: VOE, YourUpload.
    static func hostRank(_ server: String) -> Int? {
        switch server.trimmingCharacters(in: .whitespaces).lowercased() {
        case "voe": return 0
        case "yourupload": return 1
        default: return nil
        }
    }

    /// VOE's player config, hidden in `<script type="application/json">["…"]</script>`: ROT13,
    /// junk tokens, base64, every character shifted up by three, reversed, base64 again, undone in
    /// that order. Nil when VOE changes the scheme.
    static func voeConfig(_ html: String) -> JSON? {
        let tag = #"<script type="application/json">"#
        guard let open = html.range(of: tag), let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex),
              let encoded = (try? JSON.parse(Data(html[open.upperBound..<close.lowerBound].utf8)))?.array?.first?.string else { return nil }
        var text = rot13(encoded)
        for junk in ["@$", "^^", "~@", "%?", "*~", "!!", "#&"] { text = text.replacingOccurrences(of: junk, with: "") }
        guard let first = Data(base64Encoded: pad(text)) else { return nil }
        let shifted = String(first.map { Character(Unicode.Scalar(UInt8(truncatingIfNeeded: Int($0) - 3))) }.reversed())
        guard let second = Data(base64Encoded: pad(shifted)), let config = try? JSON.parse(second), config.object != nil else { return nil }
        return config
    }

    /// Where voe.sx's stub sends the browser: the first absolute `window.location.href = '…'`
    /// assignment (a read of the same property comes first and must be skipped).
    static func voeRedirect(_ html: String) -> String? {
        Pattern(#"window\.location\.href\s*=(?!=)\s*['"](https://[^'"]+)['"]"#).firstMatch(in: html)?[1]
    }

    static func ogVideo(_ html: String) -> String? {
        guard let marker = html.range(of: "og:video\""), let content = html.range(of: "content=\"", range: marker.upperBound..<html.endIndex),
              let end = html[content.upperBound...].firstIndex(of: "\"") else { return nil }
        let value = String(html[content.upperBound..<end])
        return value.hasPrefix("http") && !value.hasSuffix("/novideo.mp4") ? value : nil
    }

    static func rot13(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z": return Character(Unicode.Scalar((scalar.value - 97 + 13) % 26 + 97)!)
            case "A"..."Z": return Character(Unicode.Scalar((scalar.value - 65 + 13) % 26 + 65)!)
            default: return Character(scalar)
            }
        })
    }

    static func pad(_ value: String) -> String { value + String(repeating: "=", count: (4 - value.count % 4) % 4) }
}
