import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AnimeDekho (animedekho.tv, formerly .app), ported from the Android app's
/// `AnimeDekhoProvider`: Hindi (and multi-audio) dubs, so it's a declared-Hindi dub server.
///
/// A WordPress catalogue: a series page holds every season, one page per episode; the episode's
/// mirrors come from its `?trdekho=<n>&trid=<term>&trtype=<type>` endpoints, one iframe each.
/// Several mirror hosts run their own browser handshake before the video starts, so, as on
/// Android, they are web players rather than extracted streams.
public actor AnimeDekho: StreamProvider {
    public nonisolated let id = "animedekho"
    public nonisolated let name = "AnimeDekho (Hindi)"
    public nonisolated var declaredLanguage: String? { "Hindi" }

    struct Catalog: Sendable { var title: String; var episodes: [AnimeDekhoParser.Episode] }

    static let base = "https://animedekho.tv"
    static let minTitleScore = 0.28
    static let maxSearchQueries = 3
    static let maxProbePages = 4
    static let serverIndexes = Array(0...10)
    static let concurrency = 4
    static let missTTL: TimeInterval = 6 * 60 * 60

    typealias Fetch = @Sendable (URL, String) async throws -> (Int, String)

    private let fetch: Fetch
    private var catalogs: [Int: Catalog] = [:]
    private var misses: [Int: Date] = [:]

    public init() {
        fetch = { url, referer in
            var request = URLRequest(url: url)
            request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,*/*", forHTTPHeaderField: "Accept")
            request.setValue(referer, forHTTPHeaderField: "Referer")
            let (data, response) = try await HTTP.data(for: request)
            return (response.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// Filed as dubs: a Japanese track, when there is one, is in the same multi-audio file.
    public func episodes(for media: Media) async throws -> EpisodeListing {
        guard let catalog = try await catalog(media) else { return .empty }
        let numbers = catalog.episodes.map(\.number)
        return EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: [], dubbed: Set(numbers))
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard audio == .dub else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        guard let catalog = try await catalog(media) else { throw ProviderError.titleNotFound(provider: name) }
        guard let entry = catalog.episodes.first(where: { $0.number == episode }), let page = URL(string: entry.url) else {
            throw ProviderError.episodeNotFound(provider: name, episode: episode)
        }
        guard let term = AnimeDekhoParser.termID(try await text(page, referer: Self.base + "/")) else {
            throw HTTPError("AnimeDekho episode \(episode) has no resolver id")
        }
        // The eleven mirror slots, four at a time, in slot order.
        var found: [Int: [String]] = [:]
        for batch in stride(from: 0, to: Self.serverIndexes.count, by: Self.concurrency) {
            let slots = Self.serverIndexes[batch..<min(batch + Self.concurrency, Self.serverIndexes.count)]
            await withTaskGroup(of: (Int, [String]).self) { group in
                for slot in slots {
                    group.addTask {
                        let endpoint = URL(string: "\(Self.base)/?trdekho=\(slot)&trid=\(term)&trtype=\(entry.mediaType)")!
                        let html = (try? await self.text(endpoint, referer: entry.url)) ?? ""
                        return (slot, AnimeDekhoParser.iframes(html, base: Self.base))
                    }
                }
                for await (slot, urls) in group { found[slot] = urls }
            }
        }
        // The site's own `/aaa/down/` page only says "This Server is Down" (Android keeps it last
        // in the list; here it isn't offered).
        let mirrors = AnimeDekhoParser.orderMirrors(Self.serverIndexes.flatMap { found[$0] ?? [] }, base: Self.base)
            .filter { !AnimeDekhoParser.isDownPlaceholder($0) }
        guard !mirrors.isEmpty else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        return mirrors.enumerated().compactMap { index, mirror in
            URL(string: mirror).map {
                VideoSource(url: $0, provider: name, server: AnimeDekhoParser.mirrorLabel(mirror, index), kind: .embed,
                            headers: ["Referer": entry.url])
            }
        }
    }

    /// The season of the best-matching series page; nil only for a title the site was asked
    /// about and didn't have (a failed request throws, so nothing is learned from it).
    private func catalog(_ media: Media) async throws -> Catalog? {
        if let known = catalogs[media.id] { return known }
        if let missed = misses[media.id], Date().timeIntervalSince(missed) < Self.missTTL { return nil }
        var unanswered: (any Error)?
        var candidates: [AnimeDekhoParser.Hit] = []
        for query in Self.searchQueries(media) {
            var components = URLComponents(string: Self.base + "/")!
            components.queryItems = [URLQueryItem(name: "s", value: query)]
            do {
                candidates = AnimeDekhoParser.search(try await text(components.url!, referer: Self.base + "/"))
            } catch {
                unanswered = error
            }
            if !candidates.isEmpty { break }
        }
        if candidates.isEmpty, let unanswered { throw unanswered }
        var seen = Set<String>()
        let ranked = candidates.filter { seen.insert($0.url).inserted }
            .map { ($0, Self.score(media, $0)) }
            .filter { $0.1 >= Self.minTitleScore }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.maxProbePages)
        let expected = AnimeKhor.expectedCount(media)
        let hint = TitleMatching.seasonHint(ProviderSupport.titles(media))
        for (candidate, _) in ranked {
            guard let url = URL(string: candidate.url) else { continue }
            let html: String
            do { html = try await text(url, referer: Self.base + "/") } catch { unanswered = error; continue }
            let seasons = AnimeDekhoParser.seasons(html)
            if let season = AnimeDekhoParser.selectSeason(seasons, hint: hint, expected: expected, year: media.seasonYear), !season.episodes.isEmpty {
                let catalog = Catalog(title: candidate.title, episodes: expected.map { Array(season.episodes.prefix($0)) } ?? season.episodes)
                catalogs[media.id] = catalog
                return catalog
            }
            if seasons.isEmpty, Self.isSingleVideo(media), AnimeDekhoParser.termID(html) != nil {
                let catalog = Catalog(title: candidate.title, episodes: [.init(number: 1, url: candidate.url, mediaType: 1)])
                catalogs[media.id] = catalog
                return catalog
            }
        }
        if let unanswered { throw unanswered }
        misses[media.id] = Date()
        return nil
    }

    static func isSingleVideo(_ media: Media) -> Bool {
        media.format?.uppercased() == "MOVIE" || AnimeKhor.expectedCount(media) == 1
    }

    static func score(_ media: Media, _ hit: AnimeDekhoParser.Hit) -> Double {
        var score = ProviderSupport.titles(media).map { TitleMatching.selectionScore($0, hit.title) }.max() ?? 0
        let movie = isSingleVideo(media)
        let path = hit.url.lowercased()
        if path.contains("/movie") { score *= movie ? 1.12 : 0.65 } else if path.contains("/series") { score *= movie ? 0.65 : 1.12 }
        return min(score, 1)
    }

    /// The season-stripped name first: every season lives in one post filed under the base
    /// series, and a "Season 2" search finds nothing.
    static func searchQueries(_ media: Media) -> [String] {
        var seen = Set<String>()
        return ProviderSupport.titles(media)
            .flatMap { title in
                [TitleMatching.baseSeriesTitle(title),
                 title.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? title,
                 title]
            }
            .filter { $0.count >= 3 && seen.insert($0.lowercased()).inserted }
            .prefix(maxSearchQueries)
            .map { $0 }
    }

    private func text(_ url: URL, referer: String) async throws -> String {
        let (status, body) = try await fetch(url, referer)
        guard status == 200 else { throw HTTPError(status: status, "AnimeDekho answered HTTP \(status)") }
        return body
    }
}

/// Pure handling for AnimeDekho's pages (Android's `AnimeDekhoParser`).
enum AnimeDekhoParser {
    struct Hit: Equatable { var url: String; var title: String }
    struct Episode: Equatable, Sendable { var number: Int; var url: String; var mediaType = 2 }
    struct Season: Equatable { var number: Int?; var year: Int?; var episodes: [Episode] }

    private static let article = Pattern(#"<article\b[^>]*>([\s\S]*?)</article>"#)
    private static let anchor = Pattern(#"<a\b[^>]*>"#)
    private static let heading = Pattern(#"<h2\b[^>]*>([\s\S]*?)</h2>"#)
    private static let seasonStart = Pattern(#"<div\b[^>]*class=["'][^"']*\bseasons-bx\b[^"']*["'][^>]*>"#)
    private static let listStart = Pattern(#"<ul\b[^>]*class=["'][^"']*\bseasons-lst\b[^"']*["'][^>]*>"#)
    private static let item = Pattern(#"<li\b[^>]*>([\s\S]*?)</li>"#)
    private static let iframe = Pattern(#"<iframe\b[^>]*>"#)
    private static let episodeLabel = Pattern(#"\bS(\d+)\s*[-–]\s*E(\d+)\b"#)
    private static let episodePath = Pattern(#"-(\d+)x(\d+)(?:/|$)"#)
    private static let seasonNumber = Pattern(#"\bSeason\s*(?:<[^>]+>\s*)*(\d+)"#)
    private static let yearPattern = Pattern(#"\b(?:19|20)\d{2}\b"#)
    private static let body = Pattern(#"<body\b[^>]*>"#)
    private static let term = Pattern(#"(?:term|postid)-(\d+)"#)

    static func search(_ html: String) -> [Hit] {
        var seen = Set<String>()
        return article.matches(in: html).compactMap { match -> Hit? in
            guard let block = match[1],
                  let link = anchor.matches(in: block).compactMap({ $0[0] }).first(where: {
                      HTML.attr($0, "class").split(whereSeparator: \.isWhitespace).contains { $0.caseInsensitiveCompare("lnk-blk") == .orderedSame }
                  }) else { return nil }
            let url = HTML.attr(link, "href")
            let title = HTML.stripTags(heading.firstMatch(in: block)?[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, !title.isEmpty, seen.insert(url).inserted else { return nil }
            return Hit(url: url, title: title)
        }
    }

    static func seasons(_ html: String) -> [Season] {
        let starts = seasonStart.matches(in: html).map(\.range)
        return starts.enumerated().compactMap { index, start -> Season? in
            let end = index + 1 < starts.count ? starts[index + 1].lowerBound : html.endIndex
            let segment = String(html[start.lowerBound..<end])
            guard let list = listStart.firstMatch(in: segment) else { return nil }
            let header = String(segment[..<list.range.lowerBound])
            let rest = segment[list.range.upperBound...]
            let items = String(rest[..<(rest.range(of: "</ul>", options: .caseInsensitive)?.lowerBound ?? rest.endIndex)])
            let number = seasonNumber.firstMatch(in: header)?[1].flatMap { Int($0) }
            let year = yearPattern.firstMatch(in: header)?[0].flatMap { Int($0) }
            var seen = Set<Int>()
            let episodes = item.matches(in: items).compactMap { match -> Episode? in
                guard let block = match[1],
                      let url = anchor.matches(in: block).compactMap({ $0[0].map { HTML.attr($0, "href") } }).first(where: { $0.lowercased().contains("/epi/") }) else { return nil }
                let label = episodeLabel.firstMatch(in: HTML.stripTags(block))
                let path = episodePath.firstMatch(in: url)
                let season = (label?[1] ?? path?[1]).flatMap { Int($0) }
                guard let episode = (label?[2] ?? path?[2]).flatMap({ Int($0) }) else { return nil }
                if let number, let season, number != season { return nil }
                return seen.insert(episode).inserted ? Episode(number: episode, url: url) : nil
            }.sorted { $0.number < $1.number }
            return episodes.isEmpty ? nil : Season(number: number, year: year, episodes: episodes)
        }
    }

    /// The season the AniList entry is: its number in the title, else the only one from its
    /// year, else the only one of its length, else the first.
    static func selectSeason(_ seasons: [Season], hint: Int?, expected: Int?, year: Int?) -> Season? {
        guard !seasons.isEmpty else { return nil }
        if let hint, let season = seasons.first(where: { $0.number == hint }) { return season }
        if let year, case let matching = seasons.filter({ $0.year == year }), matching.count == 1 { return matching[0] }
        if let expected, case let matching = seasons.filter({ $0.episodes.count == expected }), matching.count == 1 { return matching[0] }
        if seasons.count == 1 { return seasons[0] }
        return seasons.first { $0.number == 1 } ?? seasons[0]
    }

    static func termID(_ html: String) -> String? {
        guard let tag = body.firstMatch(in: html)?[0] else { return nil }
        return term.firstMatch(in: tag)?[1]
    }

    static func iframes(_ html: String, base: String) -> [String] {
        var seen = Set<String>()
        return iframe.matches(in: html).compactMap { match -> String? in
            guard let tag = match[0] else { return nil }
            var source = HTML.attr(tag, "src")
            if source.isEmpty { source = HTML.attr(tag, "data-src") }
            source = source.trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty else { return nil }
            let url = source.hasPrefix("//") ? "https:" + source : AnimeKaiParser.absolute(base, source)
            return seen.insert(url).inserted ? url : nil
        }
    }

    /// Upload order isn't health order: the established player hosts first, the site's own
    /// dead-server placeholder (`/aaa/down/`, a 200 saying the server is down) last.
    static func orderMirrors(_ urls: [String], base: String) -> [String] {
        let baseHost = URL(string: base)?.host ?? ""
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }.enumerated()
            .sorted { (priority($0.element, baseHost), $0.offset) < (priority($1.element, baseHost), $1.offset) }
            .map(\.element)
    }

    private static func priority(_ url: String, _ baseHost: String) -> Int {
        guard let parsed = URL(string: url) else { return 80 }
        var host = parsed.host ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = parsed.path.lowercased()
        if host.contains("abyssplayer") { return 0 }
        if host.contains("vidmoly") { return 1 }
        if host.contains("gdmirror") { return 2 }
        if host.contains("vidcloud") { return 3 }
        if host.contains("emturbovid") { return 4 }
        if host != baseHost { return 20 }
        if path.contains("/aaa/pixel/") { return 40 }
        if path.contains("/aaa/down/") { return 100 }
        return 50
    }

    static func isDownPlaceholder(_ url: String) -> Bool {
        URL(string: url)?.path.lowercased().contains("/aaa/down/") == true
    }

    static func mirrorLabel(_ url: String, _ index: Int) -> String {
        var host = URL(string: url)?.host ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.contains("abyssplayer") { return "AbyssPlayer" }
        if host.contains("vidmoly") { return "VidMoly" }
        if host.contains("vidcloud") { return "VidCloud" }
        if host.contains("emturbovid") { return "TurboVid" }
        if host.contains("gdmirror") { return "GDMirror" }
        guard let first = host.split(separator: ".").first, !first.isEmpty else { return "Mirror \(index + 1)" }
        return first.prefix(1).uppercased() + first.dropFirst()
    }
}
