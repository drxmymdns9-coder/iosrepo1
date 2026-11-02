import Foundation

/// What several ported providers share (Android's `AnivexaClient` helpers).
enum ProviderSupport {
    /// The highest episode in `1...limit` that `available` says exists, assuming every episode
    /// up to it does: two probes for a complete title (the first and the last), a binary search
    /// only for a partial one. Android's `highestAvailable`, for servers with no episode list.
    static func highestAvailable(_ limit: Int, _ available: @Sendable (Int) async throws -> Bool) async throws -> Int {
        guard limit > 0, try await available(1) else { return 0 }
        if limit == 1 { return 1 }
        if try await available(limit) { return limit }
        var low = 1, high = limit - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if try await available(middle) { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// One search result on a site keyed by slug.
    struct Candidate: Equatable, Sendable {
        var slug: String
        var title: String
    }

    /// The AniList titles a site is searched with: English, romaji, native.
    static func titles(_ media: Media) -> [String] {
        var seen = Set<String>()
        return [media.title.english, media.title.romaji, media.title.native].compactMap { $0?.nonBlank }.filter { seen.insert($0).inserted }
    }

    /// Android's `candidateScore`: the best title score against the candidate's title or slug,
    /// nudged by a year written in the title (a remake mustn't win on the name alone).
    static func score(_ media: Media, _ candidate: Candidate) -> Double {
        let titles = titles(media)
        var score = max(titles.map { TitleMatching.selectionScore($0, candidate.title) }.max() ?? 0,
                        titles.map { TitleMatching.selectionScore($0, candidate.slug) }.max() ?? 0)
        if let year = media.seasonYear,
           let written = candidate.title.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression).flatMap({ Int(candidate.title[$0]) }) {
            score *= written == year ? 1.15 : 0.55
        }
        return min(score, 1)
    }

    /// The best candidate across every title's search, or nil below Android's 0.28 floor.
    static func bestSlug(_ media: Media, search: @Sendable (String) async throws -> [Candidate]) async -> String? {
        var candidates: [Candidate] = []
        var seen = Set<String>()
        for title in titles(media) {
            // A result may come once per title it goes by; each is scored.
            candidates += ((try? await search(title)) ?? []).filter { seen.insert($0.slug + "|" + $0.title).inserted }
        }
        guard let best = candidates.max(by: { score(media, $0) < score(media, $1) }), score(media, best) >= 0.28 else { return nil }
        return best.slug
    }

    /// Every `.m3u8` URL written in a page, in order (Android's `hlsUrls`).
    static func hlsURLs(_ html: String) -> [String] {
        var seen = Set<String>()
        return hlsPattern.matches(in: html).compactMap { match -> String? in
            guard let raw = match[0] else { return nil }
            let url = HTML.decodeEntities(raw).replacingOccurrences(of: "\\/", with: "/")
            let absolute = url.hasPrefix("//") ? "https:" + url : url
            return seen.insert(absolute).inserted ? absolute : nil
        }
    }

    private static let hlsPattern = Pattern(#"(?:https?:)?(?:\\/|/)[^"'\s<>]+?\.m3u8[^"'\s<>]*"#)

    /// How many episodes have aired, the limit those searches run to.
    static func airedCount(_ media: Media) -> Int {
        media.releasedEpisodes ?? media.episodes ?? 0
    }

    /// A listing of episodes 1…sub and 1…dub.
    static func counts(sub: Int, dub: Int) -> EpisodeListing {
        let numbers = Array(1...max(1, max(sub, dub)))
        return EpisodeListing(episodes: max(sub, dub) > 0 ? numbers.map(EpisodeInfo.init(number:)) : [],
                              subbed: sub > 0 ? Set(1...sub) : [], dubbed: dub > 0 ? Set(1...dub) : [])
    }
}
