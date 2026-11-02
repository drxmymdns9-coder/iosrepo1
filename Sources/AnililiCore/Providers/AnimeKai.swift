import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AnimeKai (anikai.cc), ported from the Android app's `AnimeKaiProvider`: a site to scrape, on
/// five alternate hostnames, whose servers are iframe embeds. Only the embeds whose page carries
/// its HLS in the open are played (vivibebe/bibiemb first); Android hands the rest to a web view,
/// which iOS doesn't, so an episode with none of those has nothing here.
///
/// The search is bounded the way Android's had to be after a viewer's device spent three minutes
/// in it: two mirrors per cold search (the next starts past them), the later titles skipped once a
/// name match is confident, and at most four cards opened per mirror to confirm a MAL id.
public actor AnimeKai: StreamProvider {
    public nonisolated let id = "animekai"
    public nonisolated let name = "AnimeKai"

    struct Match: Equatable, Sendable {
        var base: String
        var slug: String
    }

    static let mirrors = ["https://www3.anikai.cc", "https://www1.anikai.cc", "https://www2.anikai.cc", "https://www4.anikai.cc", "https://anikai.cc"]
    static let matchMirrors = 2
    static let rankedCards = 7
    static let malProbesPerMirror = 4
    static let maxEmbedAttempts = 8
    static let minMatchScore = 0.35
    static let budget: TimeInterval = 20

    typealias Fetch = @Sendable (URL, [String: String]) async throws -> (Int, String)

    private let fetch: Fetch
    private let mirrors: [String]
    private var matches: [Int: Match] = [:]
    private var cursor = 0

    public init() {
        mirrors = Self.mirrors
        fetch = { url, headers in
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await HTTP.data(for: request)
            return (response.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    init(mirrors: [String], fetch: @escaping Fetch) {
        self.mirrors = mirrors
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        let deadline = Date().addingTimeInterval(Self.budget)
        guard let match = try await match(for: media, deadline: deadline) else { return .empty }
        let (sub, dub) = AnimeKaiParser.episodes(try await page("\(match.base)/watch/\(match.slug)", referer: match.base + "/"))
        let numbers = sub.union(dub).sorted()
        return EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: sub, dubbed: dub)
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        let deadline = Date().addingTimeInterval(Self.budget)
        guard let match = try await match(for: media, deadline: deadline) else { throw ProviderError.titleNotFound(provider: name) }
        let (base, html) = try await episodePage(match, episode, deadline: deadline)
        let wanted = audio == .dub ? ["dub"] : ["hsub", "sub", "softsub"]
        let pool = AnimeKaiParser.servers(html).filter { wanted.contains($0.language) }
            .sorted { AnimeKaiParser.rank($0.video) > AnimeKaiParser.rank($1.video) }
        guard !pool.isEmpty else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        let groupSubtitles = pool.flatMap { AnimeKaiParser.embedSubtitles($0.video) }
        for server in pool.prefix(Self.maxEmbedAttempts) where Date() < deadline {
            if let source = try? await resolve(server, base: base, groupSubtitles: groupSubtitles) {
                Log.info("animekai", "\(media.id) ep \(episode) \(audio.rawValue): \(source.label)")
                return [source]
            }
        }
        // None read: the servers' own player pages, as Android falls back to.
        var seen = Set<URL>()
        let pages = pool.compactMap { server -> VideoSource? in
            guard let url = URL(string: AnimeKaiParser.absolute(base, server.video)), seen.insert(url).inserted else { return nil }
            return VideoSource(url: url, provider: name, server: server.name, kind: .embed, headers: ["Referer": base + "/"])
        }
        guard !pages.isEmpty else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        Log.info("animekai", "\(media.id) ep \(episode) \(audio.rawValue): no stream read; \(pages.count) player pages")
        return pages
    }

    // MARK: - Steps

    private func match(for media: Media, deadline: Date) async throws -> Match? {
        if let known = matches[media.id] { return known }
        let titles = [media.title.english, media.title.romaji, media.title.native].compactMap { $0?.nonBlank }
        for offset in 0..<min(Self.matchMirrors, mirrors.count) where Date() < deadline {
            let base = mirrors[(cursor + offset) % mirrors.count]
            var seen = Set<String>()
            var probes = 0
            var best: (slug: String, score: Double)?
            for title in titles where Date() < deadline {
                guard var components = URLComponents(string: base + "/browser") else { continue }
                components.queryItems = [URLQueryItem(name: "keyword", value: title)]
                guard let url = components.url, let html = try? await page(url.absoluteString, referer: base + "/") else { continue }
                let cards = AnimeKaiParser.cards(html).filter { seen.insert($0.slug).inserted }
                    .sorted { score(media, $0.title) > score(media, $1.title) }.prefix(Self.rankedCards)
                for card in cards {
                    let value = score(media, card.title)
                    if best == nil || value > best!.score { best = (card.slug, value) }
                    guard let mal = media.idMal, probes < Self.malProbesPerMirror, Date() < deadline else { continue }
                    probes += 1
                    if let watch = try? await page("\(base)/watch/\(card.slug)", referer: base + "/"), AnimeKaiParser.malID(watch) == mal {
                        return settle(media.id, Match(base: base, slug: card.slug))
                    }
                }
                // Without a MAL id the name score is the answer; the other titles would search the
                // same site for the same series.
                if media.idMal == nil, (best?.score ?? 0) >= Self.minMatchScore { break }
            }
            if let best, best.score >= Self.minMatchScore { return settle(media.id, Match(base: base, slug: best.slug)) }
        }
        cursor = (cursor + Self.matchMirrors) % mirrors.count
        return nil
    }

    private func settle(_ mediaID: Int, _ match: Match) -> Match {
        if let index = mirrors.firstIndex(of: match.base) { cursor = index }
        matches[mediaID] = match
        return match
    }

    private func episodePage(_ match: Match, _ episode: Int, deadline: Date) async throws -> (String, String) {
        var bases = [match.base, mirrors[cursor]] + mirrors
        var seen = Set<String>()
        bases = bases.filter { seen.insert($0).inserted }
        for base in bases where Date() < deadline {
            if let html = try? await page("\(base)/watch/\(match.slug)/ep-\(episode)", referer: "\(base)/watch/\(match.slug)"),
               !AnimeKaiParser.servers(html).isEmpty {
                _ = settle(-1, Match(base: base, slug: match.slug))
                return (base, html)
            }
        }
        throw ProviderError.episodeNotFound(provider: name, episode: episode)
    }

    /// An embed whose page names its HLS, confirmed to answer a playlist.
    private func resolve(_ server: AnimeKaiParser.Server, base: String, groupSubtitles: [SubtitleTrack]) async throws -> VideoSource? {
        var embed = AnimeKaiParser.absolute(base, server.video)
        if embed.range(of: #"anikai\.(?:to|cc)/iframe/"#, options: [.regularExpression, .caseInsensitive]) != nil,
           let wrapper = try? await page(embed, referer: base + "/"),
           let nested = Pattern(#"<iframe\b[^>]*src=["']([^"']+)["']"#).firstMatch(in: wrapper)?[1] {
            embed = AnimeKaiParser.absolute(embed, nested)
        }
        guard let embedURL = URL(string: embed), let origin = AnimeKaiParser.origin(embedURL) else { return nil }
        let html = try await page(embed, referer: base + "/", accept: "text/html,*/*")
        guard let found = AnimeKaiParser.findHLS(html), let hls = URL(string: AnimeKaiParser.absolute(embed, found)) else { return nil }
        let headers = ["Referer": origin + "/", "Origin": origin]
        let (status, body) = try await fetch(hls, headers.merging(["User-Agent": HTTP.browserUserAgent]) { $1 })
        guard status == 200, body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return nil }
        var seen = Set<URL>()
        let subtitles = (AnimeKaiParser.embedSubtitles(embed) + AnimeKaiParser.pageSubtitles(html) + groupSubtitles).filter { seen.insert($0.url).inserted }
        return VideoSource(url: hls, provider: name, server: server.name, kind: .hls, headers: headers, subtitles: subtitles, softSub: !subtitles.isEmpty)
    }

    private func score(_ media: Media, _ candidate: String) -> Double {
        [media.title.english, media.title.romaji, media.title.native].compactMap { $0?.nonBlank }
            .map { TitleMatching.selectionScore($0, candidate) }.max() ?? 0
    }

    private func page(_ address: String, referer: String, accept: String = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8") async throws -> String {
        guard let url = URL(string: address) else { throw HTTPError("Bad AnimeKai URL") }
        let (status, text) = try await fetch(url, ["User-Agent": HTTP.browserUserAgent, "Referer": referer, "Accept": accept, "Accept-Language": "en-US,en;q=0.9"])
        guard status == 200 else { throw HTTPError(status: status, "AnimeKai answered HTTP \(status)") }
        return text
    }
}

/// Pure HTML handling for `AnimeKai` (Android's `AnimeKaiParser`).
enum AnimeKaiParser {
    struct Card: Equatable {
        var slug: String
        var title: String
    }

    struct Server: Equatable {
        var language: String
        var name: String
        var video: String
    }

    private static let cardStart = Pattern(#"<div\b[^>]*class=["'][^"']*\baitem\b[^"']*["'][^>]*>"#)
    private static let watchHref = Pattern(#"href=["'](/watch/[^"']+)["']"#)
    private static let watchSlug = Pattern(#"/watch/([a-z0-9][a-z0-9-]*)"#)
    private static let titleTag = Pattern(#"<a\b[^>]*class=["'][^"']*\btitle\b[^"']*["'][^>]*>"#)
    private static let titleText = Pattern(#"<a\b[^>]*class=["'][^"']*\btitle\b[^"']*["'][^>]*>([\s\S]*?)</a>"#)
    private static let malLink = Pattern(#"myanimelist\.net/anime/(\d+)"#)
    private static let malData = Pattern(#"data-mal(?:-id)?=["'](\d+)["']"#)
    private static let anyTag = Pattern(#"<[a-z0-9]+\b[^>]*>"#)
    private static let serverClass = Pattern(#"(?:^|\s)server-items(?:\s|$)"#)
    private static let videoTag = Pattern(#"<(?:span|div|li|a)\b[^>]*\bdata-video\s*=\s*(["']).*?\1[^>]*>"#, dotAll: true)
    private static let episodeAnchor = Pattern(#"<a\b[^>]*\bdata-(?:num|slug)\s*=\s*(["'])\d+\1[^>]*>"#)
    private static let pageTrack = Pattern(#"file\s*:\s*["']([^"']+\.vtt[^"']*)["'][\s\S]{0,100}?label\s*:\s*["']([^"']*)["']"#)
    private static let constSrc = Pattern(#"const\s+src\s*=\s*["']([^"']+\.m3u8[^"']*)["']"#)
    private static let fileKey = Pattern(#"(?:["']file["']|file)\s*:\s*["']([^"']+\.m3u8[^"']*)["']"#)
    private static let anyHLS = Pattern(#"(?:https?:)?(?:\\/|/)[^"'\s<>]+?\.m3u8[^"'\s<>]*"#)

    static func cards(_ html: String) -> [Card] {
        let starts = cardStart.matches(in: html).map(\.range.lowerBound)
        var seen = Set<String>()
        return starts.enumerated().compactMap { index, start -> Card? in
            let end = index + 1 < starts.count ? starts[index + 1] : (html.index(start, offsetBy: 5_000, limitedBy: html.endIndex) ?? html.endIndex)
            let block = String(html[start..<end])
            guard let href = watchHref.firstMatch(in: block)?[1], let slug = watchSlug.firstMatch(in: href)?[1] else { return nil }
            let tag = titleTag.firstMatch(in: block).map { String(block[$0.range]) } ?? ""
            let title = HTML.attr(tag, "data-en").nonBlank ?? HTML.attr(tag, "title").nonBlank
                ?? titleText.firstMatch(in: block)?[1].map(HTML.stripTags)?.nonBlank ?? slug.replacingOccurrences(of: "-", with: " ")
            return seen.insert(slug).inserted ? Card(slug: slug, title: title) : nil
        }
    }

    static func malID(_ html: String) -> Int? {
        (malLink.firstMatch(in: html)?[1] ?? malData.firstMatch(in: html)?[1]).flatMap(Int.init)
    }

    /// Each `server-items` group (its `data-id` is the audio: hsub, sub, softsub, dub) and the
    /// `server` elements in it carrying a `data-video`.
    static func servers(_ html: String) -> [Server] {
        let groups = anyTag.matches(in: html).filter { match in
            let tag = String(html[match.range])
            return serverClass.contains(in: HTML.attr(tag, "class")) && !HTML.attr(tag, "data-id").isEmpty
        }
        var servers: [Server] = []
        var seen = Set<String>()
        for (index, group) in groups.enumerated() {
            let tag = String(html[group.range])
            let language = HTML.attr(tag, "data-id").lowercased()
            let end = index + 1 < groups.count ? groups[index + 1].range.lowerBound : html.endIndex
            let block = String(html[group.range.upperBound..<end])
            for match in videoTag.matches(in: block) {
                let element = String(block[match.range])
                let video = HTML.attr(element, "data-video")
                guard !video.isEmpty, HTML.attr(element, "class").localizedCaseInsensitiveContains("server") else { continue }
                let name = HTML.attr(element, "data-name").nonBlank ?? HTML.attr(element, "title").nonBlank ?? "Server"
                if seen.insert("\(language):\(video)").inserted { servers.append(Server(language: language, name: name, video: video)) }
            }
        }
        return servers
    }

    /// The watch page's episode anchors: `data-num`, and `data-sub`/`data-hsub`/`data-dub` flags.
    static func episodes(_ html: String) -> (sub: Set<Int>, dub: Set<Int>) {
        var sub = Set<Int>(), dub = Set<Int>()
        for match in episodeAnchor.matches(in: html) {
            let tag = String(html[match.range])
            guard let number = Int(HTML.attr(tag, "data-num")) ?? Int(HTML.attr(tag, "data-slug")) else { continue }
            if HTML.attr(tag, "data-sub") == "1" || HTML.attr(tag, "data-hsub") == "1" { sub.insert(number) }
            if HTML.attr(tag, "data-dub") == "1" { dub.insert(number) }
        }
        return (sub, dub)
    }

    /// Embeds whose page carries the playlist in the open lead (vivibebe and its siblings);
    /// megaup's need their player run and come last.
    static func rank(_ url: String) -> Int {
        if url.range(of: #"vivibebe\.|bibiemb\.|vibeplayer\."#, options: [.regularExpression, .caseInsensitive]) != nil { return 3 }
        if url.range(of: #"megaup|4spromax"#, options: [.regularExpression, .caseInsensitive]) != nil { return 1 }
        return 2
    }

    static func embedSubtitles(_ embed: String) -> [SubtitleTrack] {
        let decoded = HTML.decodeEntities(embed)
        guard let items = URLComponents(string: decoded)?.queryItems else { return [] }
        func value(_ names: [String]) -> String? { names.lazy.compactMap { name in items.first { $0.name.lowercased() == name }?.value }.first }
        guard let address = value(["sub", "caption_1", "c1_file", "sub_file", "subtitle"]), address.hasPrefix("http"), let url = URL(string: address) else { return [] }
        let label = value(["sub_1", "c1_label", "caption_label"]) ?? "English"
        return [SubtitleTrack(url: url, label: label, language: language(label))]
    }

    static func pageSubtitles(_ html: String) -> [SubtitleTrack] {
        var seen = Set<String>()
        return pageTrack.matches(in: html).compactMap { match in
            guard let raw = match[1] else { return nil }
            let address = decodeJavaScript(raw)
            guard let url = URL(string: address), seen.insert(address).inserted else { return nil }
            let label = HTML.decodeEntities(match[2] ?? "").nonBlank ?? "Subtitle"
            return SubtitleTrack(url: url, label: label, language: language(label))
        }
    }

    static func findHLS(_ html: String) -> String? {
        if let found = constSrc.firstMatch(in: html)?[1] ?? fileKey.firstMatch(in: html)?[1] { return decodeJavaScript(found) }
        guard let raw = anyHLS.firstMatch(in: html)?[0] else { return nil }
        let url = HTML.decodeEntities(raw).replacingOccurrences(of: "\\/", with: "/")
        return url.hasPrefix("//") ? "https:" + url : url
    }

    static func absolute(_ base: String, _ value: String) -> String {
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return value }
        return URL(string: value, relativeTo: URL(string: base))?.absoluteString ?? value
    }

    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    static func decodeJavaScript(_ value: String) -> String {
        HTML.decodeEntities(value).replacingOccurrences(of: "\\u0026", with: "&", options: .caseInsensitive).replacingOccurrences(of: "\\/", with: "/")
    }

    static func language(_ label: String) -> String {
        let lower = label.lowercased()
        for (word, code) in [("english", "en"), ("spanish", "es"), ("french", "fr"), ("german", "de"), ("portuguese", "pt")] where lower.contains(word) {
            return code
        }
        return "und"
    }
}
