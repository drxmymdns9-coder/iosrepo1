import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AnimeGG (animegg.org), ported from the Android app's `AnivexaClient.animegg`: a series page
/// listing every episode with sub and dub buttons, and per episode a few mirror tabs whose embeds
/// serve progressive MP4 through jwplayer (`file: "/play/…/video.mp4?for=…"`), sometimes HLS.
public actor AnimeGG: StreamProvider {
    public nonisolated let id = "animegg"
    public nonisolated let name = "AnimeGG"

    static let base = "https://www.animegg.org"
    static let maxTabs = 4

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
        let (sub, dub) = AnimeGGParser.episodes(try await page("/series/\(slug)"))
        let numbers = sub.union(dub).sorted()
        return EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: sub, dubbed: dub)
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard let slug = await slug(media) else { throw ProviderError.titleNotFound(provider: name) }
        guard let episodePath = AnimeGGParser.episodePath(try await page("/series/\(slug)"), episode) else {
            throw ProviderError.episodeNotFound(provider: name, episode: episode)
        }
        let watch = try await page("/" + episodePath, referer: Self.base)
        var sources: [VideoSource] = []
        for tab in AnimeGGParser.tabs(watch, audio: audio).prefix(Self.maxTabs) {
            let embed = "\(Self.base)/embed/\(tab.id)"
            guard let html = try? await page("/embed/\(tab.id)", referer: Self.base) else { continue }
            let headers = ["Referer": embed]
            for hls in ProviderSupport.hlsURLs(html) {
                if let url = URL(string: AnimeKaiParser.absolute(Self.base, hls)) {
                    sources.append(VideoSource(url: url, provider: name, server: tab.mirror, kind: .hls, headers: headers))
                }
            }
            for mp4 in AnimeGGParser.mp4Files(html) {
                if let url = URL(string: AnimeKaiParser.absolute(Self.base, mp4)) {
                    sources.append(VideoSource(url: url, provider: name, server: tab.mirror, kind: .mp4, headers: headers))
                }
            }
        }
        var seen = Set<URL>()
        sources = sources.filter { seen.insert($0.url).inserted }
        guard !sources.isEmpty else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        return sources
    }

    private func slug(_ media: Media) async -> String? {
        if let known = slugs[media.id] { return known }
        let found = await ProviderSupport.bestSlug(media) { query in
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
            return AnimeGGParser.search(try await self.page("/search/?q=\(encoded)"))
        }
        if let found { slugs[media.id] = found }
        return found
    }

    private func page(_ path: String, referer: String? = nil) async throws -> String {
        guard let url = URL(string: Self.base + path) else { throw HTTPError("Bad AnimeGG path") }
        let (status, html) = try await fetch(url, referer.map { ["Referer": $0] } ?? [:])
        guard status == 200 else { throw HTTPError(status: status, "AnimeGG answered HTTP \(status)") }
        return html
    }
}

/// Pure HTML handling for `AnimeGG`.
enum AnimeGGParser {
    struct Tab: Equatable {
        var id: String
        var mirror: String
    }

    private static let searchCard = Pattern(#"<a\b([^>]*class=["'][^"']*\bmse\b[^"']*["'][^>]*)>([\s\S]*?)</a>"#)
    private static let seriesHref = Pattern(#"^/series/([^/?#]+)"#)
    private static let strong = Pattern(#"<strong[^>]*>([\s\S]*?)</strong>"#)
    private static let listItem = Pattern(#"<li\b[^>]*>([\s\S]*?)</li>"#)
    private static let strongNumber = Pattern(#"<strong[^>]*>[\s\S]*?(\d+)\s*</strong>"#)
    private static let detailAnchor = Pattern(#"<a\b[^>]*class=["'][^"']*anm_det_pop[^"']*["'][^>]*>"#)
    private static let tabAnchor = Pattern(#"<a\b[^>]*data-toggle=["']tab["'][^>]*>"#)
    private static let mp4File = Pattern(#"file:\s*["']([^"']+\.mp4[^"']*)["']"#)

    static func search(_ html: String) -> [ProviderSupport.Candidate] {
        searchCard.matches(in: html).compactMap { match in
            guard let attributes = match[1], let slug = seriesHref.firstMatch(in: HTML.attr("<a \(attributes)>", "href"))?[1] else { return nil }
            let title = (match[2]).flatMap { strong.firstMatch(in: $0)?[1] }.map(HTML.stripTags)?.nonBlank ?? slug.replacingOccurrences(of: "-", with: " ")
            return ProviderSupport.Candidate(slug: slug, title: title)
        }
    }

    /// The series page's rows: each `anm_det_pop` item's number, and its subbed/dubbed buttons.
    static func episodes(_ html: String) -> (sub: Set<Int>, dub: Set<Int>) {
        var sub = Set<Int>(), dub = Set<Int>()
        for match in listItem.matches(in: html) {
            guard let block = match[1], block.contains("anm_det_pop"), let number = strongNumber.firstMatch(in: block)?[1].flatMap(Int.init) else { continue }
            if block.range(of: "btn-subbed", options: .caseInsensitive) != nil { sub.insert(number) }
            if block.range(of: "btn-dubbed", options: .caseInsensitive) != nil { dub.insert(number) }
        }
        return (sub, dub)
    }

    static func episodePath(_ html: String, _ episode: Int) -> String? {
        for match in listItem.matches(in: html) {
            guard let block = match[1], block.contains("anm_det_pop"),
                  strongNumber.firstMatch(in: block)?[1].flatMap(Int.init) == episode,
                  let anchor = detailAnchor.firstMatch(in: block) else { continue }
            let href = HTML.attr(String(block[anchor.range]), "href")
            let trimmed = href.drop { $0 == "/" }
            return String(trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        }
        return nil
    }

    /// The watch page's mirror tabs for one audio (`data-version` starting "dub" is the dub).
    static func tabs(_ html: String, audio: AudioTrack) -> [Tab] {
        tabAnchor.matches(in: html).compactMap { match in
            let tag = String(html[match.range])
            guard let id = HTML.attr(tag, "data-id").nonBlank else { return nil }
            let isDub = HTML.attr(tag, "data-version").lowercased().hasPrefix("dub")
            guard isDub == (audio == .dub) else { return nil }
            return Tab(id: id, mirror: HTML.attr(tag, "data-mirror").nonBlank ?? "AnimeGG")
        }
    }

    static func mp4Files(_ html: String) -> [String] {
        mp4File.matches(in: html).compactMap { $0[1] }
    }
}
