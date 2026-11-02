import Foundation

/// AnimeHeaven's back catalogue, served as progressive MP4. Ported from the Android app's
/// `AnimeHeavenProvider`.
///
/// Three plain GETs and no player page: `search.php` finds the entry, `anime.php?<id>` lists the
/// episodes, and `gate.php`, asked with the episode's hash as a `key` cookie, answers with
/// `<source>` tags naming the file on the CDN directly.
///
/// It is the fallback behind Miruro, and worth having for the same reason as on Android: the MP4 answers
/// `206 Partial Content` with no Referer and no cookie (measured 2026-09-13), so AVPlayer can open
/// the URL as it is, and AirPlay and Picture in Picture work with nothing to proxy.
///
/// The catalogue is sub only with burned-in subtitles, and one 720p encode per episode; the three
/// mirrors are that same file on different hosts, offered as manual failover.
public actor AnimeHeaven: StreamProvider {
    public nonisolated let id = "animeheaven"
    public nonisolated let name = "AnimeHeaven"

    private struct Catalog {
        var title: String
        var path: String
        var episodes: [AnimeHeavenParser.Episode]
    }

    private let base: URL
    private let fetch: @Sendable (URL, [String: String]) async throws -> String
    private var catalogs: [Int: Catalog] = [:]
    private var misses: [Int: Date] = [:]

    static let minTitleScore = 0.28
    static let maxSearchQueries = 3
    static let maxProbePages = 3
    static let missTTL: TimeInterval = 6 * 60 * 60

    public init(base: URL = URL(string: "https://animeheaven.me")!) {
        self.base = base
        self.fetch = { url, headers in try await HTTP.text(url, headers: headers) }
    }

    /// For tests: answers every GET from `fetch` instead of the network.
    init(base: URL, fetch: @escaping @Sendable (URL, [String: String]) async throws -> String) {
        self.base = base
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        guard let catalog = try await catalog(for: media) else { return .empty }
        let numbers = catalog.episodes.map(\.number)
        return EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: Set(numbers), dubbed: [])
    }

    /// Sub only: the catalogue is hard-subbed with no dubbed entries, so a dub request is
    /// answered with nothing rather than a search.
    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard audio == .sub else { return [] }
        guard let catalog = try await catalog(for: media) else {
            throw ProviderError.titleNotFound(provider: name)
        }
        guard let entry = catalog.episodes.first(where: { $0.number == episode }) else {
            throw ProviderError.episodeNotFound(provider: name, episode: episode)
        }
        // The gate hands out a second, short-lived token in the file URL, so it is asked at
        // resolve time rather than cached with the episode list.
        let page = try await get(
            "gate.php",
            // Joined as text: appendingPathComponent would percent-encode the `?` in `anime.php?id`.
            referer: base.absoluteString + "/" + catalog.path,
            cookie: "key=\(entry.gateKey)"
        )
        let urls = AnimeHeavenParser.videoURLs(page).compactMap(URL.init(string:))
        Log.info("aheaven", "\(media.id) ep \(episode): \(urls.count) mirrors")
        return urls.enumerated().map { index, url in
            VideoSource(url: url, provider: name, server: Self.mirrorLabel(url, index: index), kind: .mp4)
        }
    }

    // MARK: - Catalogue

    private func catalog(for media: Media) async throws -> Catalog? {
        if let cached = catalogs[media.id] { return cached }
        if let seenAt = misses[media.id] {
            if Date().timeIntervalSince(seenAt) < Self.missTTL { return nil }
            misses[media.id] = nil
        }
        guard let built = try await build(media) else {
            Log.info("aheaven", "\(media.id) \(media.title.preferred): not on AnimeHeaven (remembered for 6 h)")
            misses[media.id] = Date()
            return nil
        }
        Log.info("aheaven", "\(media.id) → \(built.path) \"\(built.title)\", \(built.episodes.count) episodes")
        catalogs[media.id] = built
        return built
    }

    /// Returns nil only for a title this site was asked about and did not have.
    ///
    /// A lookup that never got an answer must not come back as nil, because `catalog(for:)` would
    /// remember that as "no entry" for six hours. Transport failures are rethrown instead, so
    /// nothing is learned from them.
    private func build(_ media: Media) async throws -> Catalog? {
        var unanswered: Error?
        var candidates: [AnimeHeavenParser.SearchResult] = []
        for query in Self.searchQueries(media) {
            do {
                let results = AnimeHeavenParser.parseSearch(try await get("search.php?s=\(query.queryEncoded)"))
                Log.debug("aheaven", "search \"\(query)\": \(results.count) results")
                if !results.isEmpty {
                    candidates = results
                    break
                }
            } catch {
                unanswered = error
            }
        }
        if candidates.isEmpty, let unanswered { throw unanswered }

        let ranked = Self.rank(candidates, for: media)
        Log.debug("aheaven", "ranked: \(ranked.prefix(Self.maxProbePages).map(\.title))")
        for candidate in ranked.prefix(Self.maxProbePages) {
            do {
                let episodes = AnimeHeavenParser.parseEpisodes(try await get(candidate.path))
                if !episodes.isEmpty {
                    return Catalog(title: candidate.title, path: candidate.path, episodes: episodes)
                }
            } catch {
                unanswered = error
            }
        }
        if let unanswered { throw unanswered }
        return nil
    }

    /// Candidates worth probing, best first: the season asked for ahead of the title score.
    static func rank(_ candidates: [AnimeHeavenParser.SearchResult], for media: Media) -> [AnimeHeavenParser.SearchResult] {
        struct Scored {
            var candidate: AnimeHeavenParser.SearchResult
            var score: Double
            var season: Int
        }
        var seen = Set<String>()
        let scored: [Scored] = candidates.compactMap { candidate in
            guard seen.insert(candidate.path).inserted else { return nil }
            let score = titleScore(media, candidate.title)
            guard score >= minTitleScore else { return nil }
            return Scored(candidate: candidate, score: score, season: seasonPriority(media, candidate.title))
        }
        let ordered = scored.sorted { lhs, rhs in
            lhs.season != rhs.season ? lhs.season > rhs.season : lhs.score > rhs.score
        }
        return ordered.map(\.candidate)
    }

    static func titleScore(_ media: Media, _ candidate: String) -> Double {
        media.title.all
            .flatMap { [$0, TitleMatching.baseSeriesTitle($0)] }
            .map { TitleMatching.selectionScore($0, candidate) }
            .max() ?? 0
    }

    /// Whether a candidate is the season that was asked for: 2 yes, 1 no opinion, 0 wrong season.
    ///
    /// Ranking on the title score alone gets sequels backwards. Asking for "Saga of Tanya the Evil
    /// Season 2", "Saga of Tanya the Evil" scores 0.764 and "Saga of Tanya the Evil II" 0.727, so
    /// season one would play under season two's numbers. A wrong season is ordered last rather than
    /// dropped: it still beats nothing when the site carries only the one post.
    static func seasonPriority(_ media: Media, _ candidate: String) -> Int {
        guard let wanted = TitleMatching.seasonHint(media.title.all) else { return 1 }
        let found = TitleMatching.seasonNumber(candidate) ?? 1
        return found == wanted ? 2 : 0
    }

    /// The season-stripped name leads, because AnimeHeaven's search is literal and files sequels
    /// under its own numbering ("… II", "… 2"). A name with no season marker is unchanged by the
    /// strip, so it costs no extra request.
    static func searchQueries(_ media: Media) -> [String] {
        var seen = Set<String>()
        return media.title.all
            .flatMap { title -> [String] in
                let beforeColon = title.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    .first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? title
                return [TitleMatching.baseSeriesTitle(title), beforeColon, title]
            }
            .filter { $0.count >= 3 && seen.insert($0.lowercased()).inserted }
            .prefix(maxSearchQueries)
            .map { $0 }
    }

    /// The mirror's own hostname, the only thing that tells these copies of one encode apart.
    static func mirrorLabel(_ url: URL, index: Int) -> String {
        guard let host = url.host?.split(separator: ".").first, !host.isEmpty else {
            return "Mirror \(index + 1)"
        }
        return "Mirror \(index + 1) (\(host))"
    }

    private func get(_ path: String, referer: String? = nil, cookie: String? = nil) async throws -> String {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw HTTPError("Bad AnimeHeaven path \(path)")
        }
        var headers = [
            "User-Agent": HTTP.androidChromeUserAgent,
            "Accept": "text/html,application/xhtml+xml,*/*",
            "Referer": referer ?? base.absoluteString + "/",
        ]
        if let cookie { headers["Cookie"] = cookie }
        return try await fetch(url, headers)
    }
}

/// Pure HTML parsing for `AnimeHeaven`, kept network-free for tests.
///
/// The markup is hand-written and quoted with apostrophes throughout (`class='similarimg'`), with
/// stray whitespace inside tags (`<div  class= ' watch2 bc ' >`). Both are why attributes go
/// through `HTML.attr` rather than matching `class="..."` directly.
enum AnimeHeavenParser {
    struct SearchResult: Hashable, Sendable {
        var path: String
        var title: String
    }

    struct Episode: Hashable, Sendable {
        var number: Int
        var gateKey: String
    }

    /// Search renders `similarimg` cards; the front page and `popular.php` render `chart` rows.
    private static let cardStart = Pattern(
        "<div\\b[^>]*\\bclass\\s*=\\s*['\"][^'\"]*\\b(?:similarimg|chart)\\b[^'\"]*['\"][^>]*>"
    )
    private static let animeAnchor = Pattern("<a\\b[^>]*\\bhref\\s*=\\s*['\"]?(?:/)?(anime\\.php\\?[^'\"\\s>]+)")
    private static let nameAnchor = Pattern(
        "<div\\b[^>]*\\bclass\\s*=\\s*['\"][^'\"]*\\b(?:similarname|charttitle)\\b[^'\"]*['\"][^>]*>\\s*<a\\b[^>]*>([\\s\\S]*?)</a>"
    )
    private static let imgTag = Pattern("<img\\b[^>]*>")
    private static let gateAnchor = Pattern("gatea\\(\\s*(?:\"|&quot;|')([0-9a-f]+)(?:\"|&quot;|')\\s*\\)")
    private static let watchNumber = Pattern("<div\\b[^>]*\\bwatch2\\b[^>]*>\\s*(\\d+(?:\\.\\d+)?)\\s*</div>")
    private static let sourceTag = Pattern("<source\\b[^>]*>")

    /// The entries on a `search.php` page (or any listing using `chart` rows).
    static func parseSearch(_ html: String) -> [SearchResult] {
        var seen = Set<String>()
        return segments(html, starts: cardStart.matches(in: html).map(\.range.upperBound))
            .compactMap { block -> SearchResult? in
                guard let path = animeAnchor.firstMatch(in: block)?[1], !path.isEmpty else { return nil }
                // The card's own caption is the reliable title; the cover's `alt` is the fallback
                // for a layout that renders the image but no name element.
                let caption = nameAnchor.firstMatch(in: block)?[1].map(HTML.stripTags)?.nonBlank
                let alt = imgTag.firstMatch(in: block).map { HTML.attr(String(block[$0.range]), "alt") }?.nonBlank
                guard let title = caption ?? alt else { return nil }
                return SearchResult(path: path, title: title)
            }
            .filter { seen.insert($0.path).inserted }
    }

    /// The episodes on an `anime.php` page, ascending.
    ///
    /// Each row is an `<a onclick='gatea("<hash>")'>` wrapping a `watch2` div holding the number.
    /// The number is looked for only between one anchor and the next: a row without a `watch2` div
    /// would otherwise borrow the following row's number and shift every episode after it by one.
    static func parseEpisodes(_ html: String) -> [Episode] {
        let anchors: [(key: String, end: String.Index)] = gateAnchor.matches(in: html).compactMap { match in
            guard let key = match[1], !key.isEmpty else { return nil }
            return (key, match.range.upperBound)
        }
        var seen = Set<Int>()
        return anchors.enumerated()
            .compactMap { index, anchor -> Episode? in
                let end = index + 1 < anchors.count ? anchors[index + 1].end : html.endIndex
                // A recap between episodes is numbered "1100.5", and the page lists newest first,
                // so cutting it to 1100 would play the recap as episode 1100. Recaps are skipped.
                guard let text = watchNumber.firstMatch(in: html, range: anchor.end..<end)?[1],
                      let value = Double(text), value == value.rounded() else { return nil }
                return Episode(number: Int(value), gateKey: anchor.key)
            }
            .filter { seen.insert($0.number).inserted }
            .sorted { $0.number < $1.number }
    }

    /// Every mirror on a `gate.php` page, primary first.
    ///
    /// The page orders them `ax`, then `ct` marked `&error`, then `ck` marked `&error2`; its own
    /// player reaches the later ones only from `onerror`. That order is kept so the fallbacks stay
    /// fallbacks, and repeats are dropped.
    static func videoURLs(_ html: String) -> [String] {
        var seen = Set<String>()
        return sourceTag.matches(in: html)
            .map { HTML.attr(String(html[$0.range]), "src").trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: ".mp4", options: .caseInsensitive) != nil && seen.insert($0).inserted }
    }

    /// `html` cut into one slice per start, each running to the next. Slicing on card boundaries
    /// keeps the last card from swallowing the page footer.
    private static func segments(_ html: String, starts: [String.Index]) -> [String] {
        starts.enumerated().map { index, start in
            String(html[start..<(index + 1 < starts.count ? starts[index + 1] : html.endIndex)])
        }
    }
}
