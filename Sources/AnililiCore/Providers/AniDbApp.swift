import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AniDB App, ported from the Android app's `AniDbAppProvider`. Two hosts: `anidb.app`, the
/// website, whose title pages link AniList and MAL (an exact match); and `play.anidb.app`, the
/// player API its own apps stream through: episodes, servers per episode, and a header-free HLS
/// master per server. The player API is keyed by the Anilab post id (website id + 1,000,000,000).
///
/// When the website can't be reached (it was in maintenance on 2026-09-27 while the player API
/// served on), the Anilab catalogue stands in, matched on year, format and title; that guess is
/// held for the session only. An exact placement is remembered.
public actor AniDbApp: StreamProvider {
    public nonisolated let id = "anidbapp"
    public nonisolated let name = "AniDB App"

    struct Episode: Equatable, Sendable {
        var id: Int
        var number: Int
        var filler: Bool
    }

    struct Server: Equatable, Sendable {
        var audio: String
        var path: String
    }

    struct Candidate: Equatable, Sendable {
        var slug: String
        var siteID: Int
        var title: String
    }

    struct CataloguePost: Equatable, Sendable {
        var id: Int
        var title: String
        var type: String?
        var year: Int?
    }

    static let base = "https://anidb.app"
    static let playAPI = "https://play.anidb.app/api"
    static let catalogueAPI = "https://anilab2.amdapi.click/api"
    static let postIDBase = 1_000_000_000
    static let maxIdentityCandidates = 8
    static let maxCatalogueCandidates = 6
    static let minTitleScore = 0.28
    /// What AniDB's own player sends; the API answers without it.
    static let userAgent = "Miruro Android/1.0"

    typealias Fetch = @Sendable (URL, [String: String]) async throws -> (Int, String)

    private let fetch: Fetch
    private var exactPosts: [Int: Int] = [:]
    private var guessedPosts: [Int: Int] = [:]
    private var episodeCache: [Int: [Episode]] = [:]
    private var serverCache: [Int: [Server]] = [:]

    public init() {
        fetch = { url, headers in
            var request = URLRequest(url: url)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await HTTP.data(for: request)
            return (response.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        guard let post = try await postID(media) else { return .empty }
        let episodes = try await episodes(post)
        let expected = Self.expectedCount(media)
        let offset = AniDbAppParser.inferOffset(episodes.map(\.number), expected)
        let normalised = episodes.compactMap { episode -> (Episode, Int)? in
            let number = episode.number - offset
            return number >= 1 && (expected <= 0 || number <= expected) ? (episode, number) : nil
        }
        guard let first = normalised.first, let last = normalised.last else { return .empty }
        let firstServers = try await servers(first.0)
        let sub: Set<Int> = firstServers.isEmpty || AniDbAppParser.server(firstServers, .sub) != nil ? Set(normalised.map(\.1)) : []
        var dub: Set<Int> = []
        if AniDbAppParser.server(firstServers, .dub) != nil {
            let lastHasDub = normalised.count == 1 ? true : AniDbAppParser.server(try await servers(last.0), .dub) != nil
            if lastHasDub {
                dub = Set(normalised.map(\.1))
            } else {
                // Dubs release as a prefix: a binary search over the provider's own rows.
                var low = 0, high = normalised.count - 1, lastDub = 0
                while low <= high {
                    let middle = (low + high) / 2
                    if AniDbAppParser.server(try await servers(normalised[middle].0), .dub) != nil {
                        lastDub = middle
                        low = middle + 1
                    } else {
                        high = middle - 1
                    }
                }
                dub = Set(normalised.prefix(lastDub + 1).map(\.1))
            }
        }
        let numbers = sub.union(dub).sorted()
        var listing = EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: sub, dubbed: dub)
        let fillers = Set(normalised.filter { $0.0.filler }.map(\.1))
        for index in listing.episodes.indices where fillers.contains(listing.episodes[index].number) { listing.episodes[index].isFiller = true }
        return listing
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard let post = try await postID(media) else { throw ProviderError.titleNotFound(provider: name) }
        let episodes = try await episodes(post)
        let offset = AniDbAppParser.inferOffset(episodes.map(\.number), Self.expectedCount(media))
        guard let row = episodes.first(where: { $0.number == episode + offset }) else { throw ProviderError.episodeNotFound(provider: name, episode: episode) }
        guard let server = AniDbAppParser.server(try await servers(row), audio) else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        guard let link = AniDbAppParser.link(try JSON.parse(Data(try await play("episode/\(server.path)/iframe").utf8))), let url = URL(string: link) else {
            throw ProviderError.noStreams(episode: episode, audio: audio)
        }
        return [VideoSource(url: url, provider: name, server: server.audio == "dub" ? "English" : "Japanese", kind: .hls)]
    }

    // MARK: - Identity

    private func postID(_ media: Media) async throws -> Int? {
        if let known = exactPosts[media.id] ?? guessedPosts[media.id] { return known }
        do {
            guard let exact = try await exactPostID(media) else {
                // The website answered and named nothing with this identity: that's the answer.
                Log.info("anidbapp", "\(media.id): not on AniDB App")
                return nil
            }
            exactPosts[media.id] = exact
            return exact
        } catch {
            Log.info("anidbapp", "website unreachable (\(Log.describe(error))); trying the Anilab catalogue")
            guard let guessed = try await cataloguePostID(media) else { return nil }
            guessedPosts[media.id] = guessed
            return guessed
        }
    }

    /// The website's AniList/MAL placement; nil when it answered and had none, a throw when it
    /// couldn't be asked.
    private func exactPostID(_ media: Media) async throws -> Int? {
        var candidates: [Candidate] = []
        var seen = Set<String>()
        for title in Self.titles(media) {
            let html = try await get("\(Self.base)/search/suggestions?q=\(Self.encode(title))", referer: Self.base + "/home",
                                     accept: "text/html, */*", requestedWith: "XMLHttpRequest")
            // Suggestions are a fragment. A whole page is the site having moved: since 2026-10
            // anidb.app redirects everything to anilab.so's home page. That's the website not
            // answering, which is what the catalogue fallback is for, not "no such title".
            if AniDbAppParser.isWholePage(html) { throw HTTPError("AniDB App's website redirected away from its search") }
            candidates += AniDbAppParser.searchResults(html).filter { seen.insert($0.slug).inserted }
        }
        let ordered = candidates.sorted { score(media, $0.title) > score(media, $1.title) }
        var answered = 0
        var lastFailure: Error?
        for candidate in ordered.prefix(Self.maxIdentityCandidates) {
            do {
                let page = try await get("\(Self.base)/anime/\(candidate.slug)", referer: Self.base + "/home", accept: "text/html, */*")
                answered += 1
                let ids = AniDbAppParser.externalIDs(page)
                if ids.anilist == media.id || (ids.anilist == nil && media.idMal != nil && ids.mal == media.idMal) {
                    return Self.postIDBase + candidate.siteID
                }
            } catch {
                lastFailure = error
            }
        }
        if answered == 0, let lastFailure { throw lastFailure }
        return nil
    }

    /// The Anilab catalogue's best fit: within a year, the same format family, then by title; a
    /// lone survivor in the exact year is taken whatever its title score.
    private func cataloguePostID(_ media: Media) async throws -> Int? {
        var ids: [Int] = []
        for title in Self.titles(media) {
            let found = AniDbAppParser.catalogueSearch(try JSON.parse(Data(try await get("\(Self.catalogueAPI)/search?query=\(Self.encode(title))&page=1", referer: nil, accept: "application/json, */*").utf8)))
            if !found.isEmpty { ids = found; break }
        }
        let year = media.seasonYear ?? media.startDate?.year
        var fitting: [CataloguePost] = []
        for id in ids.prefix(Self.maxCatalogueCandidates) {
            guard let text = try? await get("\(Self.catalogueAPI)/post?id=\(id)", referer: nil, accept: "application/json, */*"),
                  let post = AniDbAppParser.cataloguePost((try? JSON.parse(Data(text.utf8))) ?? .null) else { continue }
            if AniDbAppParser.yearDistance(year, post.year) <= 1, AniDbAppParser.sameFormatFamily(media.format, post.type) { fitting.append(post) }
        }
        if fitting.count == 1, AniDbAppParser.yearDistance(year, fitting[0].year) == 0 { return fitting[0].id }
        return fitting.map { ($0, score(media, $0.title)) }.filter { $0.1 >= Self.minTitleScore }
            .sorted { (AniDbAppParser.yearDistance(year, $0.0.year), -$0.1) < (AniDbAppParser.yearDistance(year, $1.0.year), -$1.1) }
            .first?.0.id
    }

    // MARK: - Player API

    private func episodes(_ post: Int) async throws -> [Episode] {
        if let cached = episodeCache[post] { return cached }
        let parsed = AniDbAppParser.episodes(try JSON.parse(Data(try await play("anime/\(post)/episodes").utf8)))
        if !parsed.isEmpty { episodeCache[post] = parsed }
        return parsed
    }

    private func servers(_ episode: Episode) async throws -> [Server] {
        if let cached = serverCache[episode.id] { return cached }
        let parsed = AniDbAppParser.servers(try JSON.parse(Data(try await play("episode/\(episode.id)/servers").utf8)))
        // An empty answer can be a passing upstream state; only a positive one is kept.
        if !parsed.isEmpty { serverCache[episode.id] = parsed }
        return parsed
    }

    private func play(_ path: String) async throws -> String {
        try await get("\(Self.playAPI)/\(path)", referer: "https://play.app/", accept: "application/json, */*", requestedWith: "PLAY")
    }

    private func get(_ address: String, referer: String?, accept: String, requestedWith: String? = nil) async throws -> String {
        guard let url = URL(string: address) else { throw HTTPError("Bad AniDB App URL") }
        var headers = ["User-Agent": Self.userAgent, "Accept": accept]
        if let referer { headers["Referer"] = referer }
        if let requestedWith { headers["X-Requested-With"] = requestedWith }
        let (status, body) = try await fetch(url, headers)
        if AniDbAppParser.isCloudflareChallenge(body) { throw HTTPError(status: status, "AniDB App answered with a Cloudflare challenge") }
        guard status == 200 else { throw HTTPError(status: status, "AniDB App answered HTTP \(status)") }
        return body
    }

    private func score(_ media: Media, _ candidate: String) -> Double {
        Self.titles(media).map { TitleMatching.selectionScore($0, candidate) }.max() ?? 0
    }

    static func titles(_ media: Media) -> [String] {
        var seen = Set<String>()
        return [media.title.english, media.title.romaji, media.title.userPreferred, media.title.native]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 && seen.insert($0).inserted }
    }

    static func expectedCount(_ media: Media) -> Int {
        if media.status == "RELEASING", let next = media.nextAiringEpisode?.episode, next > 1 { return next - 1 }
        if let episodes = media.episodes, episodes > 0 { return episodes }
        return media.format == "MOVIE" ? 1 : 0
    }

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}

/// Pure handling for `AniDbApp` (Android's `AniDbAppParser`).
enum AniDbAppParser {
    private static let searchItem = Pattern(#"<a\b[^>]*\bdata-search-item\b[^>]*>[\s\S]*?</a>"#)
    private static let openTag = Pattern(#"<a\b[^>]*>"#)
    private static let animeSlug = Pattern(#"/anime/([^/?#]+)"#)
    private static let siteID = Pattern(#"-(\d+)$"#)
    private static let itemTitle = Pattern(#"<p\b[^>]*class=["'][^"']*\btext-sm\b[^"']*["'][^>]*>([\s\S]*?)</p>"#)
    private static let anilistLink = Pattern(#"https://anilist\.co/anime/(\d+)"#)
    private static let malLink = Pattern(#"https://myanimelist\.net/anime/(\d+)"#)
    private static let year = Pattern(#"\b(\d{4})\b"#)

    static func searchResults(_ html: String) -> [AniDbApp.Candidate] {
        var seen = Set<String>()
        return searchItem.matches(in: html).compactMap { match in
            let block = String(html[match.range])
            guard let tag = openTag.firstMatch(in: block).map({ String(block[$0.range]) }),
                  let slug = animeSlug.firstMatch(in: HTML.attr(tag, "href"))?[1],
                  let id = siteID.firstMatch(in: slug)?[1].flatMap(Int.init), seen.insert(slug).inserted else { return nil }
            let title = itemTitle.firstMatch(in: block)?[1].map(HTML.stripTags)?.nonBlank ?? slug.replacingOccurrences(of: "-", with: " ")
            return AniDbApp.Candidate(slug: slug, siteID: id, title: title)
        }
    }

    static func externalIDs(_ html: String) -> (anilist: Int?, mal: Int?) {
        (anilistLink.firstMatch(in: html)?[1].flatMap(Int.init), malLink.firstMatch(in: html)?[1].flatMap(Int.init))
    }

    /// `{"list":[{"id":"3062","number":"1","filler":false}]}`: numbers come as strings.
    static func episodes(_ root: JSON) -> [AniDbApp.Episode] {
        var seen = Set<Int>()
        return (root["list"]?.array ?? []).compactMap { row -> AniDbApp.Episode? in
            guard let id = row["id"]?.number.map({ Int($0) }), let number = row["number"]?.number.map({ Int($0) }), id > 0, number > 0 else { return nil }
            return AniDbApp.Episode(id: id, number: number, filler: row["filler"]?.bool ?? false)
        }.filter { seen.insert($0.number).inserted }.sorted { $0.number < $1.number }
    }

    /// `{"list":[{"id":"3062/jpn","lang":"sub"},{"id":"3062/eng","lang":"dub"}]}`; each audio is
    /// listed twice under one id.
    static func servers(_ root: JSON) -> [AniDbApp.Server] {
        var seen = Set<String>()
        return (root["list"]?.array ?? []).compactMap { row -> AniDbApp.Server? in
            guard let audio = row["lang"]?.string?.lowercased(), let path = row["id"]?.string, seen.insert(path).inserted else { return nil }
            return AniDbApp.Server(audio: audio, path: path)
        }
    }

    static func server(_ servers: [AniDbApp.Server], _ audio: AudioTrack) -> AniDbApp.Server? {
        servers.first { $0.audio == audio.rawValue } ?? servers.first { $0.path.hasSuffix(audio == .dub ? "/eng" : "/jpn") }
    }

    static func link(_ root: JSON) -> String? {
        root["link"]?.string.flatMap { $0.hasPrefix("http") ? $0 : nil }
    }

    static func catalogueSearch(_ root: JSON) -> [Int] {
        var seen = Set<Int>()
        return (root["posts"]?.array ?? []).compactMap { $0["id"]?.number.map { Int($0) } }.filter { seen.insert($0).inserted }
    }

    static func cataloguePost(_ root: JSON) -> AniDbApp.CataloguePost? {
        guard let id = root["id"]?.number.map({ Int($0) }), let title = root["title"]?.string else { return nil }
        let premiered = root["premiered"]?.string.flatMap { year.firstMatch(in: $0)?[1] }.flatMap(Int.init)
        return AniDbApp.CataloguePost(id: id, title: title, type: root["type"]?.string, year: premiered)
    }

    static func yearDistance(_ a: Int?, _ b: Int?) -> Int {
        guard let a, let b else { return 0 }
        return abs(a - b)
    }

    static func sameFormatFamily(_ anilist: String?, _ anilab: String?) -> Bool {
        guard let anilist = anilist?.nonBlank, let anilab = anilab?.nonBlank else { return true }
        func family(_ value: String) -> String {
            switch value.uppercased().replacingOccurrences(of: " ", with: "_") {
            case "TV", "TV_SHORT": return "TV"
            case "MOVIE": return "MOVIE"
            case "OVA", "ONA", "SPECIAL": return "SHORT"
            case let other: return other
            }
        }
        return family(anilist) == family(anilab)
    }

    /// A provider that numbers a later season on from the first (25…48) is shifted back.
    static func inferOffset(_ numbers: [Int], _ expected: Int) -> Int {
        let valid = numbers.filter { $0 > 0 }
        guard let low = valid.min(), let high = valid.max(), expected > 0 else { return 0 }
        return low > expected || (low > 1 && high - low + 1 >= expected) ? low - 1 : 0
    }

    /// A full HTML document rather than the suggestions fragment.
    static func isWholePage(_ body: String) -> Bool {
        let head = body.prefix(600).lowercased()
        return head.contains("<!doctype html") || head.contains("<html")
    }

    static func isCloudflareChallenge(_ body: String) -> Bool {
        ["cf_chl", "challenges.cloudflare.com", "Just a moment"].contains { body.range(of: $0, options: .caseInsensitive) != nil }
    }
}
