import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// RareAnimes (rareanimes.mov, "RareToonsIndia"), ported from the Android app's
/// `RareAnimesProvider`: Hindi, Tamil and Telugu dubs, a declared-Hindi dub server.
///
/// Plain WordPress. Search is read from the RSS feed (`/search/{q}/feed/rss2/`, a fraction of the
/// rendered page), posts are ranked by title and season and then probed, since a movie or stub
/// post can outscore the season post on the name alone. Long series split into per-season posts
/// that each restart at 1 are laid end to end to match AniList's absolute numbering. An episode's
/// WatchMultiQuality link chains through codedew.com (`/zipper/` → `/multiquality/`) to an argon
/// JW Player embed whose stream is gated to the player's own session, so the embed is what plays.
///
/// Not ported: Android's decode of the embed's `_juicycodes` blob, which only checks the page
/// carries a playlist before offering it.
public actor RareAnimes: StreamProvider {
    public nonisolated let id = "rareanimes"
    public nonisolated let name = "RareAnimes (Hindi)"
    public nonisolated var declaredLanguage: String? { "Hindi" }

    struct Catalog: Sendable { var title: String; var episodes: [RareAnimesParser.Episode] }

    static let base = "https://www.rareanimes.mov"
    static let codedew = "https://codedew.com/"
    /// Correct posts scored 0.594–1.0 and wrong ones 0.289–0.388 over twenty titles on Android.
    static let minTitleScore = 0.5
    static let maxSearchQueries = 4
    static let maxSearchPages = 5
    static let feedPageSize = 6
    static let maxProbePosts = 6
    static let maxSeasonPosts = 24
    static let episodeCountSlack = 2
    static let languagePriority = ["hindi", "tamil", "telugu"]
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

    /// Every track is a dub; there's no Japanese audio here.
    public func episodes(for media: Media) async throws -> EpisodeListing {
        guard let catalog = try await catalog(media) else { return .empty }
        let numbers = catalog.episodes.map(\.number).sorted()
        return EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: [], dubbed: Set(numbers))
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard audio == .dub else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        guard let catalog = try await catalog(media) else { throw ProviderError.titleNotFound(provider: name) }
        guard let entry = catalog.episodes.first(where: { $0.number == episode }) else {
            throw ProviderError.episodeNotFound(provider: name, episode: episode)
        }
        // Hindi first: the site's main track and the likeliest to resolve.
        let wanted = entry.languages.compactMap { language, links in RareAnimesParser.preferred(links).map { (language, $0) } }
            .sorted { (Self.languagePriority.firstIndex(of: $0.0) ?? 3, $0.0) < (Self.languagePriority.firstIndex(of: $1.0) ?? 3, $1.0) }
        let resolved = await withTaskGroup(of: (Int, VideoSource?).self) { group in
            for (index, (language, link)) in wanted.enumerated() {
                group.addTask { (index, try? await self.resolve(link.url, language: language)) }
            }
            var found: [(Int, VideoSource)] = []
            for await (index, source) in group { if let source { found.append((index, source)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard !resolved.isEmpty else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        return resolved
    }

    /// codedew's zipper redirects to its multiquality page, which iframes the argon player.
    private func resolve(_ zipper: String, language: String) async throws -> VideoSource? {
        guard let url = URL(string: zipper) else { return nil }
        guard let embed = RareAnimesParser.embedURL(try await text(url, referer: Self.base + "/")).flatMap(URL.init(string:)) else { return nil }
        let label = language.prefix(1).uppercased() + language.dropFirst()
        return VideoSource(url: embed, provider: name, server: "MultiQuality · \(label)", kind: .embed, headers: ["Referer": Self.codedew])
    }

    // MARK: - Catalogue

    private func catalog(_ media: Media) async throws -> Catalog? {
        if let known = catalogs[media.id] { return known }
        if let missed = misses[media.id], Date().timeIntervalSince(missed) < Self.missTTL { return nil }
        let (built, unanswered) = await build(media)
        if let built {
            catalogs[media.id] = built
        } else if let unanswered {
            throw unanswered
        } else {
            misses[media.id] = Date()
        }
        return built
    }

    /// One catalogue pass: the post pages read so far (they're ~450 KB, read once), their
    /// episodes, and the first failure, which says the site never answered.
    private struct Pass {
        var pages: [String: String] = [:]
        var parsed: [String: [RareAnimesParser.Episode]] = [:]
        var unanswered: (any Error)?
    }

    /// The catalogue, or nil and the failure that kept the site from answering (nil and no
    /// failure: the site doesn't have the title).
    private func build(_ media: Media) async -> (Catalog?, (any Error)?) {
        var pass = Pass()
        let candidates = await ranked(media, depth: 1, unanswered: &pass.unanswered)
        guard !candidates.isEmpty else { return (nil, pass.unanswered) }

        // The best-ranked post that carries episodes.
        var single: Catalog?
        for hit in candidates.prefix(Self.maxProbePosts) {
            let found = await episodes(hit, &pass)
            if !found.isEmpty { single = Catalog(title: hit.title, episodes: found); break }
        }
        let expected = AnimeKhor.expectedCount(media)
        if let single, expected == nil || single.episodes.count >= expected! - Self.episodeCountSlack { return (single, nil) }

        // A film's post has no episode headings; only a one-video entry reads a post whole.
        if single == nil, AnimeDekho.isSingleVideo(media) {
            for hit in candidates.prefix(Self.maxProbePosts) {
                if let movie = RareAnimesParser.movie(await page(hit, &pass)) { return (Catalog(title: hit.title, episodes: [movie]), nil) }
            }
        }

        // Season posts of the same series, laid end to end from season 1 without a gap.
        let series = RareAnimesParser.seriesTitle(single?.title ?? candidates[0].title).lowercased()
        let deeper = await ranked(media, depth: Self.maxSearchPages, unanswered: &pass.unanswered)
        let deep = (candidates + deeper).filter { RareAnimesParser.seriesTitle($0.title).lowercased() == series }
        var bySeason: [Int: RareAnimesParser.Hit] = [:]
        for hit in deep { if let season = TitleMatching.seasonNumber(hit.title), bySeason[season] == nil { bySeason[season] = hit } }
        var run: [RareAnimesParser.Hit] = []
        while run.count < Self.maxSeasonPosts, let next = bySeason[run.count + 1] { run.append(next) }
        if run.count >= 2 {
            var absolute: [RareAnimesParser.Episode] = []
            for hit in run {
                for episode in await episodes(hit, &pass).sorted(by: { $0.number < $1.number }) {
                    absolute.append(.init(number: absolute.count + 1, languages: episode.languages))
                }
            }
            if let expected { absolute = Array(absolute.prefix(expected)) }
            if absolute.count > (single?.episodes.count ?? 0) {
                Log.info("rareanimes", "\(media.id): stitched \(absolute.count) episodes from \(run.count) season posts")
                return (Catalog(title: "\(run.count) season posts", episodes: absolute), nil)
            }
        }
        return (single, single == nil ? pass.unanswered : nil)
    }

    private func page(_ hit: RareAnimesParser.Hit, _ pass: inout Pass) async -> String {
        if let known = pass.pages[hit.url] { return known }
        var html = ""
        if let url = URL(string: hit.url) {
            do { html = try await text(url, referer: Self.base + "/") } catch { if pass.unanswered == nil { pass.unanswered = error } }
        }
        pass.pages[hit.url] = html
        return html
    }

    private func episodes(_ hit: RareAnimesParser.Hit, _ pass: inout Pass) async -> [RareAnimesParser.Episode] {
        if let known = pass.parsed[hit.url] { return known }
        let found = RareAnimesParser.episodes(await page(hit, &pass))
        pass.parsed[hit.url] = found
        return found
    }

    /// Search hits across the titles' queries, ranked (see `RareAnimesParser.rank`).
    private func ranked(_ media: Media, depth: Int, unanswered: inout (any Error)?) async -> [RareAnimesParser.Hit] {
        let titles = ProviderSupport.titles(media)
        var seenQueries = Set<String>()
        let queries = titles.flatMap { title in
            [TitleMatching.baseSeriesTitle(title),
             title.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? title,
             title]
        }.filter { $0.count >= 3 && seenQueries.insert($0.lowercased()).inserted }.prefix(Self.maxSearchQueries)
        var hits: [RareAnimesParser.Hit] = []
        var seen = Set<String>()
        for query in queries {
            // Walked from page one and stopped at the first short page: a page past the end
            // answers the whole rendered site, half a megabyte.
            for number in 1...depth {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? query
                guard let url = URL(string: "\(Self.base)/search/\(encoded)/feed/rss2/" + (number > 1 ? "?paged=\(number)" : "")) else { break }
                let body: String
                do { body = try await text(url, referer: Self.base + "/") } catch { if unanswered == nil { unanswered = error }; break }
                guard let results = RareAnimesParser.feed(body) else { break }
                hits += results.filter { seen.insert($0.url).inserted }
                if results.count < Self.feedPageSize { break }
            }
        }
        return RareAnimesParser.rank(titles: titles, hits, episodic: !AnimeDekho.isSingleVideo(media), minScore: Self.minTitleScore)
    }

    private func text(_ url: URL, referer: String) async throws -> String {
        let (status, body) = try await fetch(url, referer)
        guard status == 200 else { throw HTTPError(status: status, "RareAnimes answered HTTP \(status)") }
        return body
    }
}

/// Pure handling for RareAnimes' pages (Android's `RareAnimesParser`).
enum RareAnimesParser {
    struct Hit: Equatable { var url: String; var title: String }
    struct ServerLink: Equatable, Sendable { var url: String; var anchor: String }
    /// Episode number → per-language server links (`hindi`, `tamil`, `telugu`).
    struct Episode: Equatable, Sendable { var number: Int; var languages: [String: [ServerLink]] }

    private static let episodeHead = Pattern(#">\s*Episode\s+0*(\d+)"#)
    private static let language = Pattern(#"\b(Hindi|Tamil|Telugu)\b"#)
    private static let finalSeason = Pattern(#"\bfinal\s+season\b"#)
    private static let titleBoilerplate = Pattern(#"\s*(?:[-–—:|]\s*)?\b(?:Season|Episodes?|Hindi|Tamil|Telugu|Bengali|Malayalam|Dubbed|Dual\s+Audio|Download|Watch|Complete|Uncut|Movie|Film|Series)\b"#)
    private static let selectionBoilerplate = Pattern(#"\s*(?:[-–—:|]\s*)?\b(?:Episodes?|Hindi|Tamil|Telugu|Bengali|Malayalam|Dubbed|Dual\s+Audio|Download|Watch|Complete|Uncut|Film|Series)\b"#)
    private static let zipperLink = Pattern(#"<a\b[^>]*?href="(https?://codedew\.com/zipper/\?url=[^"]+)"[^>]*>([\s\S]*?)</a>"#)
    private static let entryContent = Pattern(#"<div\b[^>]*\bentry-content\b[^>]*>"#)
    private static let entryContentEnd = Pattern(#"herald-related|herald-single-tags|<footer\b"#)
    private static let iframeEmbed = Pattern(#"<iframe\b[^>]*?\bsrc="(https?://[a-z0-9.-]+/embed/[A-Za-z0-9]+)""#)
    private static let bareEmbed = Pattern(#"https://[a-z0-9.-]+/embed/[A-Za-z0-9]+"#, caseInsensitive: false)
    private static let feedItem = Pattern(#"<item>([\s\S]*?)</item>"#)
    private static let feedLink = Pattern(#"<link>([\s\S]*?)</link>"#)
    private static let feedTitle = Pattern(#"<title>([\s\S]*?)</title>"#)

    /// One feed page, or nil when the body isn't a feed (a page past the last one).
    static func feed(_ body: String) -> [Hit]? {
        guard body.drop(while: \.isWhitespace).hasPrefix("<?xml") else { return nil }
        var seen = Set<String>()
        return feedItem.matches(in: body).compactMap { match -> Hit? in
            guard let block = match[1],
                  let url = feedLink.firstMatch(in: block)?[1]?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty,
                  let raw = feedTitle.firstMatch(in: block)?[1] else { return nil }
            let title = HTML.decodeEntities(raw.replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: ""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(url).inserted else { return nil }
            return Hit(url: url, title: title)
        }
    }

    /// Ranked without the network: the season asked for first (a number in the title; "Final
    /// Season" as the last the site has; season 1 when a title is exactly the series name), then
    /// the title score, then the lowest season.
    static func rank(titles: [String], _ hits: [Hit], episodic: Bool, minScore: Double = 0) -> [Hit] {
        guard !titles.isEmpty, !hits.isEmpty else { return [] }
        func score(_ hit: Hit) -> Double {
            titles.map { max(TitleMatching.selectionScore($0, seriesTitle(hit.title)), TitleMatching.selectionScore($0, selectionTitle(hit.title))) }.max() ?? 0
        }
        var seen = Set<String>()
        let qualified = hits.filter { seen.insert($0.url).inserted && score($0) >= minScore }
        let explicit = episodic ? titles.lazy.compactMap(TitleMatching.seasonNumber).first : nil
        let final = episodic && explicit == nil && titles.contains { finalSeason.firstMatch(in: $0) != nil }
            ? qualified.compactMap { TitleMatching.seasonNumber($0.title) }.max() : nil
        let exactBase = episodic && titles.contains { title in
            let normalized = TitleMatching.normalize(title)
            return !normalized.isEmpty && qualified.contains { TitleMatching.normalize(seriesTitle($0.title)) == normalized }
        }
        let requested = explicit ?? final ?? ((exactBase && qualified.contains { TitleMatching.seasonNumber($0.title) == 1 }) ? 1 : nil)
        func priority(_ hit: Hit) -> Int {
            guard let requested else { return 1 }
            switch TitleMatching.seasonNumber(hit.title) {
            case requested?: return 2
            case nil: return 1
            default: return 0
            }
        }
        return qualified.map { ($0, priority($0), score($0), TitleMatching.seasonNumber($0.title) ?? 1) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.2 != b.2 { return a.2 > b.2 }
                return a.3 < b.3
            }
            .map(\.0)
    }

    /// "Demon Slayer Season 1 – Episodes Hindi Dubbed …" → "Demon Slayer".
    static func seriesTitle(_ title: String) -> String { cut(title, titleBoilerplate) }

    /// The post title with its season and arc words but without the site's boilerplate.
    static func selectionTitle(_ title: String) -> String { cut(title, selectionBoilerplate) }

    private static func cut(_ title: String, _ pattern: Pattern) -> String {
        let end = pattern.firstMatch(in: title)?.range.lowerBound ?? title.endIndex
        return String(title[..<end]).trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—:|(["))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Episode blocks run from one `>Episode NN` heading to the next; a language word opens that
    /// language's links, and a block with none is all `fallback` (single-language posts label
    /// their rows by dub source).
    static func episodes(_ html: String, fallback: String = "hindi") -> [Episode] {
        let heads = episodeHead.matches(in: html)
        var seen = Set<Int>()
        return heads.enumerated().compactMap { index, head -> Episode? in
            let end = index + 1 < heads.count ? heads[index + 1].range.lowerBound : html.endIndex
            let block = String(html[head.range.lowerBound..<end])
            guard let number = head[1].flatMap({ Int($0) }) else { return nil }
            let languages = sections(block, fallback: fallback, merging: false, links: links)
            guard !languages.isEmpty, seen.insert(number).inserted else { return nil }
            return Episode(number: number, languages: languages)
        }
    }

    /// A film's post: servers straight under a language heading, no `Episode NN`. Only the post
    /// body is read, and only MultiQuality rows count (prose links get rewritten into codedew
    /// URLs on older posts).
    static func movie(_ html: String, fallback: String = "hindi") -> Episode? {
        var body = html
        if let start = entryContent.firstMatch(in: html) {
            let rest = String(html[start.range.upperBound...])
            body = entryContentEnd.firstMatch(in: rest).map { String(rest[..<$0.range.lowerBound]) } ?? rest
        }
        // A post names its language several times over (blurb, info table, heading): merged.
        let languages = sections(body, fallback: fallback, merging: true, links: decodableLinks)
        return languages.isEmpty ? nil : Episode(number: 1, languages: languages)
    }

    /// Each language word's links up to the next one; a repeated language replaces its earlier
    /// links, or adds to them when `merging` (as Android's episode and movie parses differ).
    private static func sections(_ block: String, fallback: String, merging: Bool, links: (String) -> [ServerLink]) -> [String: [ServerLink]] {
        let labels = language.matches(in: block)
        guard !labels.isEmpty else {
            let found = links(block)
            return found.isEmpty ? [:] : [fallback: found]
        }
        var languages: [String: [ServerLink]] = [:]
        for (index, label) in labels.enumerated() {
            let end = index + 1 < labels.count ? labels[index + 1].range.lowerBound : block.endIndex
            let found = links(String(block[label.range.lowerBound..<end]))
            guard !found.isEmpty, let name = label[1]?.lowercased() else { continue }
            languages[name] = (merging ? languages[name] ?? [] : []) + found
        }
        return languages
    }

    private static func links(_ section: String) -> [ServerLink] {
        zipperLink.matches(in: section).compactMap { match in
            guard let url = match[1] else { return nil }
            return ServerLink(url: HTML.decodeEntities(url), anchor: HTML.stripTags(match[2] ?? ""))
        }
    }

    private static func decodableLinks(_ section: String) -> [ServerLink] {
        links(section).filter { letters($0.anchor).contains("multiquality") || letters($0.anchor).contains("multquality") }
    }

    private static func letters(_ value: String) -> String { String(value.lowercased().filter(\.isLetter)) }

    /// WatchMultiQuality (also spelled WatchMultQuality) is the server that leads to a player.
    static func preferred(_ links: [ServerLink]) -> ServerLink? {
        links.first { letters($0.anchor).contains("multiquality") }
            ?? links.first { letters($0.anchor).contains("multquality") }
            ?? links.first { $0.anchor.lowercased().contains("watch") }
            ?? links.first
    }

    /// The argon (or successor) player iframe on a codedew multiquality page.
    static func embedURL(_ html: String) -> String? {
        iframeEmbed.firstMatch(in: html)?[1] ?? bareEmbed.firstMatch(in: html)?[0]
    }
}
