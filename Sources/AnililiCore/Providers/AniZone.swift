import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AniZone (anizone.to), ported from the Android app's `AnivexaClient.anizone`: a search page, a
/// title page that says "N Episodes", and an episode page whose `<media-player>` names its HLS
/// with `<track>` subtitles beside it. Sub only.
public actor AniZone: StreamProvider {
    public nonisolated let id = "anizone"
    public nonisolated let name = "AniZone"

    static let base = "https://anizone.to"

    typealias Fetch = @Sendable (URL, [String: String]) async throws -> (Int, String)

    private let fetch: Fetch
    private var slugs: [Int: String] = [:]

    public init() {
        fetch = { url, headers in
            var request = URLRequest(url: url)
            request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/json,*/*", forHTTPHeaderField: "Accept")
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await HTTP.data(for: request)
            return (response.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        guard let slug = await slug(media) else { return .empty }
        guard let count = AniZoneParser.episodeCount(try await page("/anime/\(slug)", referer: nil)), count > 0 else { return .empty }
        let aired = ProviderSupport.airedCount(media)
        return ProviderSupport.counts(sub: aired > 0 ? min(count, aired) : count, dub: 0)
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard audio == .sub else { return [] }
        guard let slug = await slug(media) else { throw ProviderError.titleNotFound(provider: name) }
        let path = "/anime/\(slug)/\(episode)"
        let html = try await page(path, referer: "\(Self.base)/anime/\(slug)")
        guard let hls = AniZoneParser.hls(html), let url = URL(string: hls) else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        let subtitles = AniZoneParser.subtitles(html)
        return [VideoSource(url: url, provider: name, server: "AniZone", kind: .hls, headers: ["Referer": Self.base + path],
                            subtitles: subtitles, softSub: !subtitles.isEmpty)]
    }

    private func slug(_ media: Media) async -> String? {
        if let known = slugs[media.id] { return known }
        let found = await ProviderSupport.bestSlug(media) { query in
            var components = URLComponents(string: Self.base + "/anime")!
            components.queryItems = [URLQueryItem(name: "search", value: query)]
            return AniZoneParser.search(try await self.page(components.url!.absoluteString.replacingOccurrences(of: Self.base, with: ""), referer: nil))
        }
        if let found { slugs[media.id] = found }
        return found
    }

    private func page(_ path: String, referer: String?) async throws -> String {
        guard let url = URL(string: Self.base + path) else { throw HTTPError("Bad AniZone path") }
        let (status, html) = try await fetch(url, referer.map { ["Referer": $0] } ?? [:])
        guard status == 200 else { throw HTTPError(status: status, "AniZone answered HTTP \(status)") }
        return html
    }
}

/// Pure HTML handling for `AniZone`.
enum AniZoneParser {
    private static let animeLink = Pattern(#"href=["'](?:https://anizone\.to)?/anime/([a-z0-9-]+)(?:[/?#][^"']*)?["']"#)
    private static let alpineTitle = Pattern(#"getTitle\(this\.anmTitles,\s*'((?:\\'|[^'])*)'\)"#)
    private static let player = Pattern(#"<media-player[^>]+src=["']([^"']+\.m3u8[^"']*)["']"#)
    private static let track = Pattern(#"<track\b([^>]*)>"#)
    private static let count = Pattern(#"\b(\d+)\s+Episodes\b"#)

    /// The search results. Since 2026-10 they're a JSON array in an Alpine attribute,
    /// `x-data="{ items: JSON.parse('[{"slug":…,"main_title":…,"title_list":{…}}]') }"`, one
    /// candidate per title a result goes by; the older markup, anime links titled by the
    /// `getTitle(…, 'Name')` call before each, is still read when that array isn't there.
    static func search(_ html: String) -> [ProviderSupport.Candidate] {
        let decoded = HTML.decodeEntities(html)
        if let start = decoded.range(of: "JSON.parse('"), let end = decoded.range(of: "')", range: start.upperBound..<decoded.endIndex),
           let items = try? JSON.parse(Data(unescapeJavaScript(String(decoded[start.upperBound..<end.lowerBound])).utf8)).array {
            return items.flatMap { item -> [ProviderSupport.Candidate] in
                guard let slug = item["slug"]?.string else { return [] }
                var seen = Set<String>()
                let titles = ([item["main_title"]?.string] + (item["title_list"]?.object ?? [:]).sorted { $0.key < $1.key }.map { $0.value.string })
                    .compactMap { $0 }.filter { seen.insert($0).inserted }
                return titles.map { ProviderSupport.Candidate(slug: slug, title: $0) }
            }
        }
        var seen = Set<String>()
        return animeLink.matches(in: html).compactMap { link in
            guard let slug = link[1], seen.insert(slug).inserted else { return nil }
            let start = html.index(link.range.lowerBound, offsetBy: -3_000, limitedBy: html.startIndex) ?? html.startIndex
            let title = alpineTitle.matches(in: html, range: start..<link.range.lowerBound).last?[1]?.replacingOccurrences(of: "\\'", with: "'")
                ?? slug.replacingOccurrences(of: "-", with: " ")
            return ProviderSupport.Candidate(slug: slug, title: title)
        }
    }

    /// A single-quoted JavaScript string's escapes undone: `\uXXXX` (AniZone writes every quote
    /// as `"`), `\\` and `\'`. The rest (`\n`, `\/`…) are left for the JSON parser, which
    /// reads them the same way.
    static func unescapeJavaScript(_ text: String) -> String {
        var out = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\\", index + 1 < scalars.count else { out.unicodeScalars.append(scalar); index += 1; continue }
            let next = scalars[index + 1]
            switch next {
            case "\\": out.append("\\"); index += 2
            case "'": out.append("'"); index += 2
            case "u" where index + 5 < scalars.count:
                let hex = String(String.UnicodeScalarView(scalars[(index + 2)...(index + 5)]))
                if let value = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(value) {
                    out.unicodeScalars.append(decoded)
                    index += 6
                } else {
                    out.append("\\u"); index += 2
                }
            default: out.unicodeScalars.append(scalar); out.unicodeScalars.append(next); index += 2
            }
        }
        return out
    }

    static func episodeCount(_ html: String) -> Int? { count.firstMatch(in: html)?[1].flatMap(Int.init) }

    /// The page's Livewire data with its escapes undone: quotes are `"` and slashes `\\\/`.
    static func unwrapped(_ html: String) -> String {
        HTML.decodeEntities(html).replacingOccurrences(of: "\\\\\\/", with: "/").replacingOccurrences(of: "\\\\/", with: "/")
            .replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\u0022", with: "\"")
    }

    private static let streamURL = Pattern(#"https?://[^"\s<>\\]+?\.m3u8[^"\s<>\\]*"#)
    private static let dataTrack = Pattern(#"\{"title":"([^"]*)","format":"(\w+)","language":"([^"]*)","default":(true|false)[^}]*?"file":"([^"]+)"\}"#)

    /// The `<media-player src>` where the page still has one; since 2026-10 the master is only
    /// in the Livewire data (`"https://seiryuu.vid-cdn.xyz/<uuid>/master.m3u8"`).
    static func hls(_ html: String) -> String? {
        if let tag = player.firstMatch(in: html)?[1] { return HTML.decodeEntities(tag) }
        return streamURL.firstMatch(in: unwrapped(html))?[0]
    }

    /// `<track kind="subtitles">` tags, or the Livewire data's `subtitles` list (ASS files, read
    /// by `Subtitles.parseASS`), the default first.
    static func subtitles(_ html: String) -> [SubtitleTrack] {
        let fromData = dataTrack.matches(in: unwrapped(html)).compactMap { match -> SubtitleTrack? in
            guard let file = match[5], let url = URL(string: file) else { return nil }
            let label = match[1]?.nonBlank ?? "Subtitle"
            let code = (match[3] ?? "").split(separator: "-").first.map { String($0).lowercased() } ?? "und"
            return SubtitleTrack(url: url, label: label, language: code.isEmpty ? "und" : code, isDefault: match[4] == "true")
        }
        if !fromData.isEmpty {
            var seen = Set<URL>()
            return fromData.filter { seen.insert($0.url).inserted }.sorted { ($0.isDefault ? 0 : 1) < ($1.isDefault ? 0 : 1) }
        }
        return track.matches(in: html).compactMap { match in
            let tag = String(html[match.range])
            guard HTML.attr(tag, "kind").lowercased() == "subtitles", let src = HTML.attr(tag, "src").nonBlank,
                  let url = URL(string: src, relativeTo: URL(string: AniZone.base))?.absoluteURL else { return nil }
            let label = HTML.attr(tag, "label").nonBlank ?? "Subtitle"
            return SubtitleTrack(url: url, label: label, language: HTML.attr(tag, "srclang").nonBlank ?? MegaPlayParser.language(label))
        }
    }
}
