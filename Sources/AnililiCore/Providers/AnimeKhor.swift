import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AnimeKhor (animekhor.org), ported from the Android app's `AnimekhorProvider`: a donghua
/// catalogue and nothing else, so it's only asked about Chinese titles (Android's country gate).
///
/// A WordPress anime theme: `/?s=` search, a series page listing one page per episode (sometimes
/// a batch, "637 to 638"), and an episode page whose mirrors are base64 `<iframe>` HTML in a
/// `<select>`. Every mirror is a third-party player (Dailymotion, ok.ru, Rumble …), so they are
/// web players, not streams.
public actor AnimeKhor: StreamProvider {
    public nonisolated let id = "animekhor"
    public nonisolated let name = "AnimeKhor"

    struct Catalog: Sendable { var title: String; var episodes: [Int: String] }

    static let base = "https://animekhor.org"
    static let minTitleScore = 0.28
    static let maxSearchQueries = 3
    static let maxProbePages = 3
    static let countPenalty = 0.45
    static let formatMismatchPenalty = 0.65
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

    public func episodes(for media: Media) async throws -> EpisodeListing {
        guard let catalog = try await catalog(media) else { return .empty }
        let numbers = catalog.episodes.keys.sorted()
        return EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: Set(numbers), dubbed: [])
    }

    /// Subtitled only: the site has no dubs, so a dub asks for nothing.
    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard audio == .sub else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        guard let catalog = try await catalog(media) else { throw ProviderError.titleNotFound(provider: name) }
        guard let address = catalog.episodes[episode], let page = URL(string: address) else {
            throw ProviderError.episodeNotFound(provider: name, episode: episode)
        }
        let mirrors = AnimeKhorParser.mirrors(try await text(page, referer: Self.base + "/"))
        guard !mirrors.isEmpty else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        return mirrors.compactMap { mirror in
            URL(string: mirror.url).map { VideoSource(url: $0, provider: name, server: mirror.label, kind: .embed, headers: ["Referer": address]) }
        }
    }

    /// The series page that agrees best with AniList: title first, then how close its episode
    /// count is (the site numbers whole franchises on one page where AniList splits seasons).
    /// Nil only for a title the site was asked about and didn't have; a failed request throws.
    private func catalog(_ media: Media) async throws -> Catalog? {
        guard media.countryOfOrigin?.uppercased() == "CN" else { return nil }
        if let known = catalogs[media.id] { return known }
        if let missed = misses[media.id], Date().timeIntervalSince(missed) < Self.missTTL { return nil }
        var unanswered: (any Error)?
        var candidates: [AnimeKhorParser.Hit] = []
        for query in Self.searchQueries(media) {
            var components = URLComponents(string: Self.base + "/")!
            components.queryItems = [URLQueryItem(name: "s", value: query)]
            do {
                candidates = AnimeKhorParser.search(try await text(components.url!, referer: Self.base + "/"))
            } catch {
                unanswered = error
            }
            if !candidates.isEmpty { break }
        }
        if candidates.isEmpty, let unanswered { throw unanswered }
        var seen = Set<String>()
        let ranked = candidates.filter { seen.insert($0.url).inserted }
            .map { ($0, Self.titleScore(media, $0)) }
            .filter { $0.1 >= Self.minTitleScore }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.maxProbePages)
        let expected = Self.expectedCount(media)
        var best: (Catalog, Double)?
        for (candidate, score) in ranked {
            guard let url = URL(string: candidate.url) else { continue }
            let html: String
            do { html = try await text(url, referer: Self.base + "/") } catch { unanswered = error; continue }
            let episodes = AnimeKhorParser.episodes(html)
            guard !episodes.isEmpty else { continue }
            let total = score * Self.countAgreement(episodes.count, expected)
            if best == nil || total > best!.1 { best = (Catalog(title: candidate.title, episodes: episodes), total) }
        }
        guard let best else {
            if let unanswered { throw unanswered }
            misses[media.id] = Date()
            return nil
        }
        catalogs[media.id] = best.0
        return best.0
    }

    /// A soft multiplier in `[countPenalty, 1]`: a mismatch loses to a better page but doesn't
    /// disqualify the only one.
    static func countAgreement(_ found: Int, _ expected: Int?) -> Double {
        guard let expected, expected > 0, found > 0 else { return 1 }
        return countPenalty + (1 - countPenalty) * Double(min(found, expected)) / Double(max(found, expected))
    }

    static func titleScore(_ media: Media, _ hit: AnimeKhorParser.Hit) -> Double {
        if hit.isComic { return 0 }
        let score = ProviderSupport.titles(media).map { TitleMatching.selectionScore($0, hit.title) }.max() ?? 0
        let movie = media.format?.uppercased() == "MOVIE" || expectedCount(media) == 1
        return min(movie == hit.isMovie ? score : score * formatMismatchPenalty, 1)
    }

    static func expectedCount(_ media: Media) -> Int? {
        if let episodes = media.episodes, episodes > 0 { return episodes }
        if let released = media.releasedEpisodes, released > 0 { return released }
        return nil
    }

    /// Each title, and its part before a colon, three at most.
    static func searchQueries(_ media: Media) -> [String] {
        var seen = Set<String>()
        return ProviderSupport.titles(media)
            .flatMap { [$0, $0.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? $0] }
            .filter { $0.count >= 3 && seen.insert($0.lowercased()).inserted }
            .prefix(maxSearchQueries)
            .map { $0 }
    }

    private func text(_ url: URL, referer: String) async throws -> String {
        let (status, body) = try await fetch(url, referer)
        guard status == 200 else { throw HTTPError(status: status, "AnimeKhor answered HTTP \(status)") }
        return body
    }
}

/// Pure handling for AnimeKhor's pages (Android's `AnimekhorParser`).
enum AnimeKhorParser {
    struct Hit: Equatable {
        var url: String
        var title: String
        var type: String
        var isComic: Bool { type.caseInsensitiveCompare("Comic") == .orderedSame }
        var isMovie: Bool { type.caseInsensitiveCompare("Movie") == .orderedSame }
    }

    struct Mirror: Equatable { var label: String; var url: String }

    private static let article = Pattern(#"<article\b[^>]*>([\s\S]*?)</article>"#)
    private static let anchor = Pattern(#"<a\b[^>]*>"#)
    private static let typeBadge = Pattern(#"<div\b[^>]*class=["'][^"']*\btypez\b\s*([^"']*)["']"#)
    private static let episodeList = Pattern(#"<div\b[^>]*class=["'][^"']*\beplister\b[^"']*["'][^>]*>"#)
    private static let item = Pattern(#"<li\b[^>]*>([\s\S]*?)</li>"#)
    private static let episodeNumber = Pattern(#"<div\b[^>]*class=["'][^"']*\bepl-num\b[^"']*["'][^>]*>([\s\S]*?)</div>"#)
    private static let mirrorList = Pattern(#"<div\b[^>]*class=["'][^"']*\bmobius\b[^"']*["'][^>]*>"#)
    private static let option = Pattern(#"<option\b[^>]*value=["']([^"']*)["'][^>]*>([\s\S]*?)</option>"#)
    private static let iframe = Pattern(#"<iframe\b[^>]*>"#)
    static let maxBatchSpan = 26

    static func search(_ html: String) -> [Hit] {
        var seen = Set<String>()
        return article.matches(in: html).compactMap { match -> Hit? in
            guard let block = match[1], let link = anchor.firstMatch(in: block)?[0] else { return nil }
            let url = HTML.attr(link, "href")
            let title = HTML.decodeEntities(HTML.attr(link, "title")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.contains("/anime/"), !title.isEmpty, seen.insert(url).inserted else { return nil }
            let type = typeBadge.firstMatch(in: block)?[1]?.trimmingCharacters(in: .whitespaces) ?? ""
            return Hit(url: url, title: title, type: type)
        }
    }

    /// Every episode number the series page offers, to the page that plays it. The list is
    /// newest first and a batch page can claim a number an episode's own page does: the first
    /// (newest) one is kept.
    static func episodes(_ html: String) -> [Int: String] {
        guard let start = episodeList.firstMatch(in: html) else { return [:] }
        let rest = html[start.range.upperBound...]
        let list = String(rest[..<(rest.range(of: "</ul>", options: .caseInsensitive)?.lowerBound ?? rest.endIndex)])
        var episodes: [Int: String] = [:]
        for match in item.matches(in: list) {
            guard let block = match[1], let link = anchor.firstMatch(in: block)?[0] else { continue }
            let url = HTML.attr(link, "href")
            guard !url.isEmpty, let label = episodeNumber.firstMatch(in: block)?[1] else { continue }
            for number in numbers(HTML.stripTags(label)) where episodes[number] == nil { episodes[number] = url }
        }
        return episodes
    }

    /// What an `epl-num` label stands for: `207`, `637 to 638`, `1 to 12`, `S4 E380`,
    /// `S4 E378-379`, `S2E290`. The season prefix goes (the number after it is absolute).
    static func numbers(_ label: String) -> [Int] {
        var body = label.trimmingCharacters(in: .whitespacesAndNewlines)
        body = body.replacingOccurrences(of: #"^S\d+\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: #"\bE(?=\d)"#, with: "", options: [.regularExpression, .caseInsensitive])
        let found = Pattern(#"\d+"#).matches(in: body).compactMap { $0[0].flatMap { Int($0) } }
        guard let first = found.first else { return [] }
        guard found.count > 1, let last = found.last, last >= first, last <= first + maxBatchSpan else { return [first] }
        return Array(first...last)
    }

    /// The episode's mirrors, in the site's order: the `<select>`'s options are base64 iframe
    /// HTML; the inline player is only a fallback for a page without them.
    static func mirrors(_ html: String) -> [Mirror] {
        var segment = ""
        if let start = mirrorList.firstMatch(in: html) {
            let rest = html[start.range.upperBound...]
            segment = String(rest[..<(rest.range(of: "</select>", options: .caseInsensitive)?.lowerBound ?? rest.endIndex)])
        }
        var seen = Set<String>()
        let found = option.matches(in: segment).compactMap { match -> Mirror? in
            guard let encoded = match[1]?.trimmingCharacters(in: .whitespaces), encoded.count >= 16,
                  let data = Data(base64Encoded: AnimeAV1Parser.pad(encoded)),
                  let url = iframeSource(String(decoding: data, as: UTF8.self)), seen.insert(url).inserted else { return nil }
            let label = HTML.stripTags(match[2] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Mirror(label: label.isEmpty ? hostLabel(url) : label, url: url)
        }
        if !found.isEmpty { return found }
        return iframeSource(html).map { [Mirror(label: hostLabel($0), url: $0)] } ?? []
    }

    static func iframeSource(_ html: String) -> String? {
        for match in iframe.matches(in: html) {
            guard let tag = match[0] else { continue }
            var source = HTML.attr(tag, "src")
            if source.isEmpty { source = HTML.attr(tag, "data-src") }
            source = source.trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty else { continue }
            // Several mirrors are protocol-relative ("//ok.ru/videoembed/…").
            return source.hasPrefix("//") ? "https:" + source : AnimeKaiParser.absolute(AnimeKhor.base, source)
        }
        return nil
    }

    static func hostLabel(_ url: String) -> String {
        var host = URL(string: url)?.host ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let first = host.split(separator: ".").first.map(String.init) ?? ""
        return first.isEmpty ? "Mirror" : first.prefix(1).uppercased() + first.dropFirst()
    }
}
