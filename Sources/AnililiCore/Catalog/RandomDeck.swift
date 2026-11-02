import Foundation

/// The dice's draw pile (Android's `RandomAnimeDeck`): a shuffled page of the pool dealt one title
/// at a time. Only an empty pile fetches another page, chosen at random from those not dealt yet,
/// so nothing repeats in a session until the whole pool has gone round. Titles already started
/// are left out unless a page would have nothing else, and every `tasteEvery`th card comes from
/// the viewer's taste instead: a dice that only dealt what it thinks you'll like would stop
/// being a dice.
public actor RandomDeck {
    public typealias PageFetch = @Sendable (Int) async throws -> [Media]
    public typealias TasteFetch = @Sendable () async -> [Media]

    private let fetchPage: PageFetch
    private let taste: TasteFetch?
    private let tasteEvery: Int
    private let skip: @Sendable (Media) -> Bool
    private var pageCount: Int
    private var dealtPages = Set<Int>()
    private var shown = Set<Int>()
    private var pile: [Media] = []
    private var tastePile: [Media] = []
    private var tasteDry = false
    private var dealt = 0
    private var generator: any RandomNumberGenerator

    /// Bounds one draw: a pool that keeps answering empty is down, not unlucky.
    static let maxFetchesPerDraw = 4

    public init(pageCount: Int, skip: @escaping @Sendable (Media) -> Bool = { _ in false }, taste: TasteFetch? = nil,
                tasteEvery: Int = 3, generator: any RandomNumberGenerator = SystemRandomNumberGenerator(), fetchPage: @escaping PageFetch) {
        self.pageCount = max(1, pageCount)
        self.skip = skip
        self.taste = taste
        self.tasteEvery = tasteEvery
        self.generator = generator
        self.fetchPage = fetchPage
    }

    /// The card the next draw will deal, when the pile already holds it (to preload its art).
    public var upNext: Media? {
        (tasteTurn(dealt) ? tastePile.first : nil) ?? pile.first
    }

    private func tasteTurn(_ count: Int) -> Bool { taste != nil && tasteEvery > 0 && count % tasteEvery == tasteEvery - 1 }

    /// One title, fetching a page when the pile is empty; nil when the pool gave nothing.
    public func draw() async throws -> Media? {
        if tasteTurn(dealt), let media = await drawTaste() {
            shown.insert(media.id)
            dealt += 1
            return media
        }
        dealt += 1
        for _ in 0..<Self.maxFetchesPerDraw {
            if pile.isEmpty { try await refill() }
            if !pile.isEmpty {
                let media = pile.removeFirst()
                shown.insert(media.id)
                return media
            }
        }
        return nil
    }

    private func drawTaste() async -> Media? {
        guard let taste else { return nil }
        if tastePile.isEmpty && !tasteDry {
            let fresh = await taste().filter { !shown.contains($0.id) && !skip($0) }
            if fresh.isEmpty { tasteDry = true } else { tastePile = fresh }
        }
        while !tastePile.isEmpty {
            let media = tastePile.removeFirst()
            if !shown.contains(media.id) { return media }
        }
        return nil
    }

    private func refill() async throws {
        if dealtPages.count >= pageCount {
            // The whole pool has been through the pile: start again rather than run dry.
            dealtPages = []
            shown = []
            tasteDry = false
        }
        let candidates = (1...pageCount).filter { !dealtPages.contains($0) }
        let page = candidates.randomElement(using: &generator) ?? 1
        let items = try await fetchPage(page)
        if items.isEmpty {
            // The pool shrank below this page since it was measured; stop the range short of it.
            pageCount = max(1, page - 1)
            dealtPages = dealtPages.filter { $0 <= pageCount }
            if page == 1 { dealtPages.insert(page) }
            return
        }
        dealtPages.insert(page)
        let fresh = items.filter { !shown.contains($0.id) }
        let wanted = fresh.filter { !skip($0) }
        pile += (wanted.isEmpty ? fresh : wanted).shuffled(using: &generator)
    }
}

extension AniListClient {
    /// Android's `RANDOM_POOL_PAGES` × 50: popular finished and airing titles, the dice's pool.
    public static let randomPoolPages = 70

    public func randomPool(page: Int, hideAdult: Bool) async throws -> [Media] {
        let adultDeclaration = hideAdult ? ", $isAdult: Boolean" : ""
        let adultArgument = hideAdult ? ", isAdult: $isAdult" : ""
        let query = """
        query ($page: Int, $perPage: Int, $minPopularity: Int\(adultDeclaration)) {
          Page(page: $page, perPage: $perPage) {
            media(type: ANIME, sort: [POPULARITY_DESC], popularity_greater: $minPopularity, format_in: [TV, MOVIE, ONA, OVA],
                  status_not: NOT_YET_RELEASED\(adultArgument)) { \(Self.spotlightFields) }
          }
        }
        """
        var variables: [String: Variable] = ["page": .int(page), "perPage": .int(50), "minPopularity": .int(10_000)]
        if hideAdult { variables["isAdult"] = .bool(false) }
        struct PageResult: Decodable { var media: [Media] }
        struct Payload: Decodable { var Page: PageResult }
        let data: Payload = try await run(query, variables)
        return data.Page.media
    }
}
