import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ToonHub4u (toonhub4u.live, formerly .co), ported from the Android app's `ToonHubProvider`:
/// Hindi (and multi-audio) dubs, a declared-Hindi dub server.
///
/// Each post is one season (or movie) and groups, per episode, a ToonStream watch link and the
/// post's own mirrors. The ToonStream page iframes its players (rubystm, vidmoly, AbyssPlayer …),
/// sometimes inside a same-host `/embed/` wrapper that is peeled here; the post's mirrors follow
/// them, since ToonStream's domains rotate and not every one answers. All are web players.
/// The watch link may hide behind ToonHub's base64 redirector, and a post sometimes repeats
/// episode one's link in every block, so the episode suffix is repaired from the heading.
public actor ToonHub: StreamProvider {
    public nonisolated let id = "toonhub"
    public nonisolated let name = "ToonHub4u (Hindi)"
    public nonisolated var declaredLanguage: String? { "Hindi" }

    struct Catalog: Sendable { var title: String; var page: String; var episodes: [ToonHubParser.Episode] }

    static let base = "https://toonhub4u.live"
    static let minTitleScore = 0.28
    static let maxSearchQueries = 3
    static let searchPageSize = 20
    static let maxProbePages = 5
    static let missTTL: TimeInterval = 6 * 60 * 60

    /// Status, body and the URL the answer came from (after redirects).
    typealias Fetch = @Sendable (URL, String) async throws -> (Int, String, URL)

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
            return (response.statusCode, String(decoding: data, as: UTF8.self), response.url ?? url)
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        guard let catalog = try await catalog(media) else { return .empty }
        let numbers = catalog.episodes.map(\.number).sorted()
        return EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: [], dubbed: Set(numbers))
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard audio == .dub else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        guard let catalog = try await catalog(media) else { throw ProviderError.titleNotFound(provider: name) }
        guard let entry = catalog.episodes.first(where: { $0.number == episode }), !entry.links.isEmpty else {
            throw ProviderError.episodeNotFound(provider: name, episode: episode)
        }
        var links: [(ToonHubParser.Link, String)] = []
        for watch in entry.links where ToonHubParser.isWatchLink(watch.url) {
            links += (try? await players(watch.url, referer: catalog.page)) ?? []
        }
        links += entry.links.filter { !ToonHubParser.isWatchLink($0.url) && !ToonHubParser.redirectsToAds($0.url) }.map { ($0, catalog.page) }
        var seen = Set<String>()
        let sources = links.filter { seen.insert($0.0.url).inserted }.compactMap { link, referer in
            URL(string: link.url).map { VideoSource(url: $0, provider: name, server: link.label, kind: .embed, headers: ["Referer": referer]) }
        }
        guard !sources.isEmpty else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        return sources
    }

    /// A ToonStream episode page's players, each with the Referer it is shown under; a
    /// same-host wrapper is opened for the player inside it (its fake play button would never
    /// receive the tap).
    private func players(_ address: String, referer: String) async throws -> [(ToonHubParser.Link, String)] {
        guard let url = URL(string: address) else { return [] }
        let (status, html, final) = try await fetch(url, referer)
        guard status == 200 else { throw HTTPError(status: status, "ToonHub player HTTP \(status)") }
        let page = final.absoluteString
        var found: [(ToonHubParser.Link, String)] = []
        for link in ToonHubParser.playerEmbeds(html, page: page) {
            if ToonHubParser.isWrappedPlayer(link.url, page: page), let wrapper = URL(string: link.url),
               let answer = try? await fetch(wrapper, page), answer.0 == 200,
               let player = ToonHubParser.wrappedPlayer(answer.1, page: answer.2.absoluteString) {
                found.append((ToonHubParser.Link(url: player, label: link.label), answer.2.absoluteString))
            } else {
                found.append((link, page))
            }
        }
        return found
    }

    /// The best-matching post that lists episodes; nil only for a title the site was asked about
    /// and didn't have.
    private func catalog(_ media: Media) async throws -> Catalog? {
        if let known = catalogs[media.id] { return known }
        if let missed = misses[media.id], Date().timeIntervalSince(missed) < Self.missTTL { return nil }
        var unanswered: (any Error)?
        var candidates: [ToonHubParser.Hit] = []
        for query in AnimeDekho.searchQueries(media) {
            var components = URLComponents(string: Self.base + "/wp-json/wp/v2/search")!
            components.queryItems = [URLQueryItem(name: "search", value: query), URLQueryItem(name: "per_page", value: "\(Self.searchPageSize)")]
            do {
                guard let hits = ToonHubParser.search(try await text(components.url!, referer: Self.base + "/")) else {
                    throw HTTPError("ToonHub search for \"\(query)\" did not answer with JSON")
                }
                candidates += hits
            } catch {
                unanswered = error
            }
        }
        if candidates.isEmpty, let unanswered { throw unanswered }
        var seen = Set<String>()
        let ranked = candidates.filter { seen.insert($0.url).inserted }
            .map { ($0, Self.score(media, $0)) }
            .filter { $0.1 >= Self.minTitleScore }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.maxProbePages)
        for (candidate, _) in ranked {
            guard let url = URL(string: candidate.url) else { continue }
            let html: String
            do { html = try await text(url, referer: Self.base + "/") } catch { unanswered = error; continue }
            var episodes = ToonHubParser.episodes(html, base: Self.base)
            if episodes.isEmpty, AnimeDekho.isSingleVideo(media), case let links = ToonHubParser.links(html, base: Self.base), !links.isEmpty {
                episodes = [.init(number: 1, links: links)]
            }
            if !episodes.isEmpty {
                let catalog = Catalog(title: candidate.title, page: candidate.url, episodes: episodes)
                catalogs[media.id] = catalog
                return catalog
            }
        }
        if let unanswered { throw unanswered }
        misses[media.id] = Date()
        return nil
    }

    /// Title (or the post's series name), weighted by whether the post is the season asked for.
    static func score(_ media: Media, _ hit: ToonHubParser.Hit) -> Double {
        let titles = ProviderSupport.titles(media)
        var score = titles.map { max(TitleMatching.selectionScore($0, hit.title), TitleMatching.selectionScore($0, ToonHubParser.seriesTitle(hit.title))) }.max() ?? 0
        if !AnimeDekho.isSingleVideo(media) {
            let wanted = TitleMatching.seasonHint(titles) ?? 1
            if let season = TitleMatching.seasonNumber(hit.title) { score *= season == wanted ? 1.2 : 0.45 }
        } else if hit.title.lowercased().contains("movie") {
            score *= 1.1
        }
        return min(score, 1)
    }

    private func text(_ url: URL, referer: String) async throws -> String {
        let (status, body, _) = try await fetch(url, referer)
        guard status == 200 else { throw HTTPError(status: status, "ToonHub answered HTTP \(status)") }
        return body
    }
}

/// Pure handling for ToonHub's pages (Android's `ToonHubParser`).
enum ToonHubParser {
    struct Hit: Equatable { var url: String; var title: String }
    struct Link: Equatable, Sendable { var url: String; var label: String }
    struct Episode: Equatable, Sendable { var number: Int; var links: [Link] }

    private static let anchor = Pattern(#"<a\b[^>]*>"#)
    private static let iframe = Pattern(#"<iframe\b[^>]*>"#)
    private static let paragraph = Pattern(#"<p\b[^>]*>[\s\S]*?</p>"#)
    private static let span = Pattern(#"<span\b[^>]*>[\s\S]*?</span>"#)
    private static let episodeText = Pattern(#"^Episode\s*0*(\d+)\b"#)
    private static let quality = Pattern(#"\b(2160p|1080p|720p|480p|360p|4k)\b"#)
    private static let redirectTarget = Pattern(#"[?&]url=([A-Za-z0-9+/=_-]+)"#, caseInsensitive: false)
    private static let seriesCut = Pattern(#"\s*(?:[-–—:|]\s*)?\b(?:Season\s*\d+|Episodes?|Hindi|Tamil|Telugu|Multi\s*Audio|Dual\s*Audio|Download|Watch|Movie|Film)\b"#)
    private static let episodeSuffix = Pattern(#"(-\d+x)\d+(?=/|$)"#)
    private static let trailerHosts = ["youtube.com", "youtu.be", "youtube-nocookie.com"]

    /// One `wp/v2/search` answer: posts only (the contact and DMCA pages match many queries).
    /// Nil when the body wasn't a JSON array: the question never got through, which isn't
    /// "nothing found".
    static func search(_ body: String) -> [Hit]? {
        guard let rows = (try? JSON.parse(Data(body.utf8)))?.array else { return nil }
        var seen = Set<String>()
        return rows.compactMap { row -> Hit? in
            if let subtype = row["subtype"]?.string, subtype.lowercased() != "post" { return nil }
            guard let url = row["url"]?.string, !url.isEmpty,
                  let title = row["title"]?.string.map(HTML.decodeEntities), !title.isEmpty, seen.insert(url).inserted else { return nil }
            return Hit(url: url, title: title)
        }
    }

    /// Each "Episode N" paragraph and what follows it up to the next: its watch links (the
    /// episode suffix repaired) and its mirrors.
    static func episodes(_ html: String, base: String) -> [Episode] {
        let heads = paragraph.matches(in: html).compactMap { match -> (Range<String.Index>, Int)? in
            guard let text = match[0], let number = episodeText.firstMatch(in: HTML.stripTags(text).trimmingCharacters(in: .whitespacesAndNewlines))?[1].flatMap({ Int($0) }) else { return nil }
            return (match.range, number)
        }
        var seen = Set<Int>()
        return heads.enumerated().compactMap { index, head -> Episode? in
            let end = index + 1 < heads.count ? heads[index + 1].0.lowerBound : html.endIndex
            let segment = String(html[head.0.upperBound..<end])
            let links = watchLinks(segment, base: base, episode: head.1) + self.links(segment, base: base)
            guard !links.isEmpty, seen.insert(head.1).inserted else { return nil }
            return Episode(number: head.1, links: links)
        }
    }

    /// The post's own mirrors: `/file/` and `/embed/` links, labelled by the paragraph's quality.
    static func links(_ html: String, base: String) -> [Link] {
        var seen = Set<String>()
        return paragraph.matches(in: html).flatMap { match -> [Link] in
            guard let block = match[0] else { return [] }
            let text = HTML.stripTags(block)
            let label = quality.firstMatch(in: text)?[1].map { $0.lowercased() == "4k" ? "4K" : $0.lowercased() }
                ?? text.split(separator: "–").first.flatMap { $0.split(separator: "-").first }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return anchor.matches(in: block).compactMap { tag -> Link? in
                guard let raw = tag[0].map({ HTML.attr($0, "href") }), !raw.isEmpty else { return nil }
                let absolute = AnimeKaiParser.absolute(base, raw)
                let embed: String
                if absolute.range(of: "/file/", options: .caseInsensitive) != nil {
                    embed = absolute.replacingOccurrences(of: "/file/", with: "/embed/", options: .caseInsensitive)
                } else if absolute.range(of: "/embed/", options: .caseInsensitive) != nil {
                    embed = absolute
                } else {
                    return nil
                }
                guard seen.insert(embed).inserted else { return nil }
                return Link(url: embed, label: (label?.isEmpty == false ? label : nil) ?? "Mirror")
            }
        }
    }

    static func isWatchLink(_ url: String) -> Bool {
        let host = URL(string: url)?.host?.lowercased() ?? ""
        return host.contains("toonstream") || host.contains("toon-stream")
    }

    /// GDMirror's old domain redirects every embed to an advertising site.
    static func redirectsToAds(_ url: String) -> Bool {
        URL(string: url)?.host?.lowercased().contains("gdmirrorbot") == true
    }

    /// A watch link out of ToonHub's `/redirect/mainN.php?url=<base64>` hop.
    static func followRedirect(_ url: String) -> String {
        guard url.range(of: "/redirect/", options: .caseInsensitive) != nil, let encoded = redirectTarget.firstMatch(in: url)?[1] else { return url }
        let standard = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "="))
        guard let data = Data(base64Encoded: AnimeAV1Parser.pad(standard)), let decoded = String(data: data, encoding: .utf8),
              decoded.lowercased().hasPrefix("http://") || decoded.lowercased().hasPrefix("https://") else { return url }
        return decoded
    }

    /// Every player a ToonStream episode page iframes, labelled by its server list and in a
    /// health order; the trailer is left out.
    static func playerEmbeds(_ html: String, page: String) -> [Link] {
        let labels = span.matches(in: html).compactMap { match -> String? in
            guard let tag = match[0] else { return nil }
            let classes = (anchorOpen(tag).map { HTML.attr($0, "class") } ?? "").split(whereSeparator: \.isWhitespace)
            let text = HTML.stripTags(tag).trimmingCharacters(in: .whitespacesAndNewlines)
            return classes.contains { $0.lowercased() == "server" } && !text.isEmpty ? text : nil
        }
        var seen = Set<String>()
        var index = 0
        var found: [Link] = []
        for match in iframe.matches(in: html) {
            guard let tag = match[0] else { continue }
            var raw = HTML.attr(tag, "src")
            if raw.isEmpty { raw = HTML.attr(tag, "data-src") }
            guard !raw.isEmpty else { continue }
            let absolute = raw.hasPrefix("//") ? "https:" + raw : AnimeKaiParser.absolute(page, raw)
            guard let url = URL(string: absolute), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  var host = url.host?.lowercased(), !host.isEmpty, absolute.caseInsensitiveCompare(page) != .orderedSame else { continue }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if trailerHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { continue }
            let label = index < labels.count ? labels[index] : "Server \(index + 1)"
            index += 1
            if seen.insert(absolute).inserted { found.append(Link(url: absolute, label: label)) }
        }
        return found.enumerated().sorted { (rank($0.element.label), $0.offset) < (rank($1.element.label), $1.offset) }.map(\.element)
    }

    private static func anchorOpen(_ tag: String) -> String? {
        tag.range(of: ">").map { String(tag[..<$0.upperBound]) }
    }

    /// The same-host `/embed/` chrome that `wrappedPlayer` peels.
    static func isWrappedPlayer(_ url: String, page: String) -> Bool {
        guard let target = URL(string: url), let host = URL(string: page)?.host else { return false }
        return target.host?.lowercased() == host.lowercased() && target.path.lowercased().hasPrefix("/embed/")
    }

    static func wrappedPlayer(_ html: String, page: String) -> String? {
        for match in iframe.matches(in: html) {
            guard let tag = match[0] else { continue }
            var raw = HTML.attr(tag, "src")
            if raw.isEmpty { raw = HTML.attr(tag, "data-src") }
            guard !raw.isEmpty else { continue }
            let absolute = raw.hasPrefix("//") ? "https:" + raw : AnimeKaiParser.absolute(page, raw)
            guard let url = URL(string: absolute), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
                  absolute.caseInsensitiveCompare(page) != .orderedSame else { continue }
            return absolute
        }
        return nil
    }

    private static func rank(_ label: String) -> Int {
        let label = label.lowercased()
        if label.contains("short") { return 0 }
        if label.contains("moly") { return 1 }
        if label.contains("turbo") { return 2 }
        if label.contains("ruby") { return 3 }
        if label.contains("multi") { return 4 }
        if label == "play" { return 5 }
        if label.contains("cloud") { return 6 }
        if label.contains("strm") { return 7 }
        if label.contains("watch") { return 20 }
        return 10
    }

    private static func watchLinks(_ html: String, base: String, episode: Int) -> [Link] {
        var seen = Set<String>()
        return anchor.matches(in: html).compactMap { match -> Link? in
            guard let raw = match[0].map({ HTML.attr($0, "href") }), !raw.isEmpty else { return nil }
            let absolute = followRedirect(AnimeKaiParser.absolute(base, raw))
            guard isWatchLink(absolute) else { return nil }
            var corrected = absolute
            if let suffix = episodeSuffix.firstMatch(in: absolute), let season = suffix[1] {
                corrected.replaceSubrange(suffix.range, with: season + String(episode))
            }
            return seen.insert(corrected).inserted ? Link(url: corrected, label: "Hindi Stream") : nil
        }
    }

    static func seriesTitle(_ title: String) -> String {
        let cut = seriesCut.firstMatch(in: title)?.range.lowerBound ?? title.endIndex
        return String(title[..<cut]).trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—:|(["))
            .trimmingCharacters(in: .whitespaces)
    }
}
