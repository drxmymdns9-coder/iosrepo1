import Foundation

/// Title matching the adult servers share (Android's `HanimeCatalog.kt` helpers and
/// `HStreamProvider.seriesScore`).
///
/// None of hanime, Hentai Haven or hstream carries an AniList, MAL, TMDB or AniDB id, and none has
/// a usable search (Hentai Haven's answers the same eighteen titles to every query), so each site's
/// whole catalogue is held and an AniList entry is matched against it by name. The bar is high on
/// purpose: a wrong hentai match is worse than none, since the viewer gets a video that isn't the
/// one they asked for instead of an honest "no source".
enum AdultTitles {
    /// The ids of the servers that only ever carry adult material (Android's
    /// `ProviderCatalog.adultProviders`). Asked only while "Hide adult content" is off.
    static let providerIDs: Set<String> = ["hanime", "hentaihaven", "hstream"]

    /// Below this a match is more likely a different show with a similar name than the right one.
    static let matchThreshold = 0.85

    /// The names an AniList entry can be known by, best-known first.
    static func candidates(_ media: Media) -> [String] {
        var seen = Set<String>()
        return [media.title.romaji, media.title.english, media.title.native, media.title.userPreferred]
            .compactMap { $0?.nonBlank }
            .filter { seen.insert($0).inserted }
    }

    /// Lower case, punctuation to spaces, runs of space collapsed: punctuation is where these
    /// catalogues disagree most with AniList ("Maki-chan to Nau" for "Maki-chan to Nau.").
    static func normalize(_ value: String) -> String {
        let folded = String(value.lowercased().map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " " })
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Dice coefficient over character bigrams of the normalised titles; 1 is identical.
    static func similarity(_ left: String, _ right: String) -> Double {
        let a = Array(normalize(left)), b = Array(normalize(right))
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        let pairs = bigrams(a), other = bigrams(b)
        var counts: [String: Int] = [:]
        for pair in other { counts[pair, default: 0] += 1 }
        var shared = 0
        for pair in pairs where counts[pair, default: 0] > 0 {
            counts[pair]! -= 1
            shared += 1
        }
        return 2 * Double(shared) / Double(pairs.count + other.count)
    }

    private static func bigrams(_ characters: [Character]) -> [String] {
        characters.count < 2 ? [String(characters)] : (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
    }

    /// `onaji-zemi-no-someya-san` reads as a title once the hyphens are spaces.
    static func slugAsTitle(_ slug: String) -> String { slug.replacingOccurrences(of: "-", with: " ") }

    /// The best slug for `media` whose `score` clears the bar, or nil.
    static func bestSlug<S: Sequence>(_ media: Media, in slugs: S, score: ([String], String) -> Double) -> String? where S.Element == String {
        let wanted = candidates(media)
        guard !wanted.isEmpty else { return nil }
        var best: (slug: String, score: Double)?
        for slug in slugs {
            let value = score(wanted, slug)
            if value >= matchThreshold, value > (best?.score ?? 0) { best = (slug, value) }
        }
        return best?.slug
    }

    /// Hentai Haven's score: the slug read as a title against every AniList name.
    static func plainScore(_ wanted: [String], _ slug: String) -> Double {
        let title = slugAsTitle(slug)
        return wanted.map { similarity($0, title) }.max() ?? 0
    }

    /// hstream's score (Android's `HStreamProvider.seriesScore`). The plain comparison lands most
    /// series; each extra spelling rescued one measured miss, and the number check closes the one
    /// false match that leniency opens:
    ///
    /// - `ito-o-yoru` is AniList's "Ito wo Yoru": the site writes the particle を as "o".
    /// - `imouto-paradise-s2` is AniList's "Imouto Paradise! 2".
    /// - `inyouchuu-the-animation` drops a subtitle AniList keeps after a colon.
    /// - "Imouto Paradise!" (season one) scored 0.93 against the season-two slug, so a pair whose
    ///   standalone numbers differ never matches.
    static func seriesScore(_ wanted: [String], _ slug: String) -> Double {
        let site = siteTitleVariants(slug)
        var seen = Set<String>()
        var best = 0.0
        for candidate in wanted.flatMap(aniListTitleVariants) where seen.insert(candidate).inserted {
            for title in site where numbersAgree(candidate, title) {
                best = max(best, similarity(candidate, title))
            }
        }
        return best
    }

    /// The ways a slug can be read as a title; see `seriesScore`.
    static func siteTitleVariants(_ slug: String) -> [String] {
        let base = seasonSuffix.replacing(in: slugAsTitle(slug), with: " $1")
        let withoutAnimation = theAnimationSuffix.replacing(in: base, with: "")
        var seen = Set<String>()
        return [base, withoutAnimation]
            .flatMap { [$0, particleO.replacing(in: $0, with: "wo")] }
            .compactMap(\.nonBlank)
            .filter { seen.insert($0).inserted }
    }

    private static func aniListTitleVariants(_ title: String) -> [String] {
        [title, String(title.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""),
         theAnimationSuffix.replacing(in: title, with: "")].compactMap(\.nonBlank)
    }

    /// Whether two titles carry the same standalone numbers, in any order.
    static func numbersAgree(_ left: String, _ right: String) -> Bool {
        standaloneNumbers(left) == standaloneNumbers(right)
    }

    private static func standaloneNumbers(_ title: String) -> [String] {
        normalize(title).split(separator: " ").map(String.init).filter { $0.allSatisfy(\.isNumber) }.sorted()
    }

    private static let seasonSuffix = Pattern(#"\s+s(\d+)$"#, caseInsensitive: false)
    private static let theAnimationSuffix = Pattern(#"[\s:]+the animation\s*$"#)
    /// A standalone "o", the site's romanisation of the particle を that AniList writes "wo".
    private static let particleO = Pattern(#"(?<= )o(?= )"#, caseInsensitive: false)
}

/// A whole-catalogue download held for `ttl`, fetched once however many lookups ask at the same
/// time. An empty result is never kept, so one bad pass can't pin "no source" for hours (Android's
/// `cacheIf = { it.isNotEmpty() }`).
actor CatalogueCache<Value: Sendable> {
    private let ttl: TimeInterval
    private let isEmpty: @Sendable (Value) -> Bool
    private var value: Value?
    private var fetchedAt = Date.distantPast
    private var inFlight: Task<Value, any Error>?

    init(ttl: TimeInterval, isEmpty: @escaping @Sendable (Value) -> Bool) {
        self.ttl = ttl
        self.isEmpty = isEmpty
    }

    func get(_ fetch: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let value, Date().timeIntervalSince(fetchedAt) < ttl { return value }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await fetch() }
        inFlight = task
        defer { inFlight = nil }
        let fresh = try await task.value
        if !isEmpty(fresh) {
            value = fresh
            fetchedAt = Date()
        }
        return fresh
    }
}
