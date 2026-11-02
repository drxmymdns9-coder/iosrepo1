import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// hstream.moe, ported from the Android app's `HStreamProvider` (c09b9679). An adult-only server:
/// `SourceHub` asks it only while "Hide adult content" is off.
///
/// ```
/// GET  hstream.moe/sitemap.xml          -> every series and episode slug, held 6 hours
/// GET  hstream.moe/hentai/{slug}-{n}    -> #e_id, data-csrf, and a session cookie
/// POST hstream.moe/player/api           -> {stream_domains: [5 mirrors], stream_url, extra_subtitles}
/// ```
///
/// The POST answers 419 without both the page's session cookie and `X-CSRF-TOKEN`, and 200 with
/// them; the captcha on the page gates only downloads. The mirrors want no Referer, cookie or
/// User-Agent. Android plays the 720p DASH manifest first; AVPlayer has no DASH, so this port
/// offers `x264.720p.mp4`, the same H.264 encode as one file (the site's own fallback for devices
/// without AV1), on two mirrors in turn. 1080p and up are AV1-only DASH and are left out.
///
/// Every episode has English subtitles as `eng.vtt` beside the video, which carries none burned in;
/// the site's machine translations are `.ass` files, labelled "(auto-translated)".
///
/// The site names no AniList or MAL id anywhere, so a series is bound by name against the sitemap,
/// whose slugs are romaji like AniList's own titles (`AdultTitles.seriesScore`).
public actor HStream: StreamProvider {
    public nonisolated let id = "hstream"
    public nonisolated let name = "HStream"

    static let base = "https://hstream.moe"

    /// A page body with the cookies it set, ready to send back.
    struct Page: Sendable {
        var status: Int
        var body: String
        var cookies: String
    }

    typealias Load = @Sendable (URLRequest) async throws -> Page

    private let load: Load
    private let mirrorStart: @Sendable () -> Int
    /// Short, because the same sitemap says which episodes exist and a new one shouldn't wait a day.
    private let catalogue = CatalogueCache<[String: [Int]]>(ttl: 6 * 3600, isEmpty: { $0.isEmpty })
    private var slugs: [Int: String] = [:]

    public init() {
        load = { request in
            var request = request
            request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await HTTP.data(for: request)
            return Page(status: response.statusCode, body: String(decoding: data, as: UTF8.self), cookies: HStreamParser.cookieHeader(response))
        }
        // The API has listed five mirrors every time; the first pick is spread over them.
        mirrorStart = { Int.random(in: 0..<5) }
    }

    init(load: @escaping Load, mirrorStart: @escaping @Sendable () -> Int = { 0 }) {
        self.load = load
        self.mirrorStart = mirrorStart
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        guard let (slug, numbers) = try await series(media), !numbers.isEmpty else { return .empty }
        Log.info("hstream", "\(media.id) → \(slug): \(numbers.count) episodes")
        let set = Set(numbers)
        return EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: set, dubbed: [])
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard audio == .sub else { return [] }
        guard let (slug, numbers) = try await series(media) else { throw ProviderError.titleNotFound(provider: name) }
        guard numbers.contains(episode) else { throw ProviderError.episodeNotFound(provider: name, episode: episode) }
        let pageURL = URL(string: "\(Self.base)/hentai/\(slug)-\(episode)")!
        var pageRequest = URLRequest(url: pageURL)
        pageRequest.setValue("text/html,*/*", forHTTPHeaderField: "Accept")
        let page = try await load(pageRequest)
        guard (200..<300).contains(page.status) else { throw HTTPError(status: page.status, "HStream answered HTTP \(page.status)") }
        guard let episodeID = HStreamParser.episodeID(page.body), let csrf = HStreamParser.csrfToken(page.body) else {
            throw HTTPError("HStream's episode page carried no episode id or token")
        }
        guard !page.cookies.isEmpty else { throw HTTPError("HStream's episode page opened no session") }

        var api = URLRequest(url: URL(string: Self.base + "/player/api")!)
        api.httpMethod = "POST"
        api.httpBody = try JSONSerialization.data(withJSONObject: ["episode_id": episodeID])
        for (field, value) in ["Content-Type": "application/json", "Accept": "application/json", "Cookie": page.cookies,
                               "X-CSRF-TOKEN": csrf, "X-Requested-With": "XMLHttpRequest", "Referer": pageURL.absoluteString,
                               "Origin": Self.base] {
            api.setValue(value, forHTTPHeaderField: field)
        }
        let answer = try await load(api)
        guard (200..<300).contains(answer.status) else { throw HTTPError(status: answer.status, "HStream's player API answered HTTP \(answer.status)") }
        guard let player = HStreamParser.player(Data(answer.body.utf8)) else { throw HTTPError("HStream's player API named no stream") }
        let sources = HStreamParser.sources(player, provider: name, mirrorStart: mirrorStart())
        Log.info("hstream", "\(slug) ep \(episode): \(sources.count) mirrors, \(sources.first?.subtitles.count ?? 0) subtitle files")
        return sources
    }

    private func series(_ media: Media) async throws -> (String, [Int])? {
        let all = try await catalogue.get { [load] in
            let page = try await load(URLRequest(url: URL(string: Self.base + "/sitemap.xml")!))
            guard (200..<300).contains(page.status) else { throw HTTPError(status: page.status, "HStream's sitemap answered HTTP \(page.status)") }
            let series = HStreamParser.catalogue(page.body)
            Log.info("hstream", "catalogue: \(series.count) series")
            return series
        }
        if let known = slugs[media.id] { return (known, all[known] ?? []) }
        guard let slug = AdultTitles.bestSlug(media, in: all.keys.sorted(), score: AdultTitles.seriesScore) else { return nil }
        slugs[media.id] = slug
        return (slug, all[slug] ?? [])
    }
}

/// Pure parsing for `HStream`, kept network-free for tests.
enum HStreamParser {
    struct Player: Equatable, Sendable {
        var streamPath: String
        var mirrors: [String]
        /// Language code to display name, for the machine-translated `.ass` files.
        var extraSubtitles: [String: String]
    }

    /// Series slug to its episode numbers. An entry is an episode when it is a listed series plus
    /// `-{n}`: deciding by "ends in a number" alone would misfile a series whose name ends in one.
    static func catalogue(_ xml: String) -> [String: [Int]] {
        let entries = Set(sitemapEntry.matches(in: xml).compactMap { $0[1] })
        var episodes: [String: Set<Int>] = [:]
        for entry in entries {
            guard let match = trailingNumber.firstMatch(in: entry), let series = match[1], entries.contains(series),
                  let number = match[2].flatMap(Int.init) else { continue }
            episodes[series, default: []].insert(number)
        }
        return episodes.mapValues { $0.sorted() }
    }

    static func episodeID(_ html: String) -> String? { episodeIDPattern.firstMatch(in: html)?[1] }

    static func csrfToken(_ html: String) -> String? {
        (dataCSRF.firstMatch(in: html) ?? metaCSRF.firstMatch(in: html))?[1]?.nonBlank
    }

    /// A `Cookie` header out of a response's `Set-Cookie` lines: each `name=value`, attributes dropped.
    static func cookieHeader(_ response: HTTPURLResponse) -> String {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let name = pair.key as? String, let value = pair.value as? String { result[name] = value }
        }
        guard let url = response.url else { return "" }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    static func player(_ data: Data) -> Player? {
        guard let root = try? JSON.parse(data),
              let path = root["stream_url"]?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).nonBlank else { return nil }
        let mirrors = (root["stream_domains"]?.array ?? []).compactMap { $0.string }
            .filter { $0.hasPrefix("https://") }
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        guard !mirrors.isEmpty else { return nil }
        // An empty set arrives as `[]` rather than `{}`.
        var extras: [String: String] = [:]
        for (code, label) in root["extra_subtitles"]?.object ?? [:] {
            if let label = label.string, languageCode.firstMatch(in: code)?[0] == code { extras[code] = label }
        }
        return Player(streamPath: path, mirrors: mirrors, extraSubtitles: extras)
    }

    /// The MP4 on two mirrors in turn, so a failed mirror is stepped past rather than retried.
    static func sources(_ player: Player, provider: String, mirrorStart: Int) -> [VideoSource] {
        func mirror(_ index: Int) -> String {
            let count = player.mirrors.count
            return player.mirrors[((mirrorStart + index) % count + count) % count]
        }
        // Subtitles off the leading mirror; every mirror carries the same files.
        func subtitles(_ host: String) -> [SubtitleTrack] {
            let english = SubtitleTrack(url: URL(string: "\(host)/\(player.streamPath)/eng.vtt")!, label: "English", language: "en", isDefault: true)
            let translated = player.extraSubtitles.sorted { $0.value < $1.value }.compactMap { code, label in
                URL(string: "\(host)/\(player.streamPath)/autotrans/\(code).ass").map {
                    SubtitleTrack(url: $0, label: "\(label) (auto-translated)", language: code)
                }
            }
            return [english] + translated
        }
        return (0..<min(2, player.mirrors.count)).compactMap { index in
            let host = mirror(index)
            guard let url = URL(string: "\(host)/\(player.streamPath)/x264.720p.mp4") else { return nil }
            let server = URL(string: host)?.host?.components(separatedBy: ".").first ?? "Mirror \(index + 1)"
            return VideoSource(url: url, provider: provider, server: "720p · \(server)", kind: .mp4,
                               subtitles: subtitles(host), softSub: true)
        }
    }

    private static let sitemapEntry = Pattern(#"<loc>https://hstream\.moe/hentai/([a-z0-9-]+)/?</loc>"#, caseInsensitive: false)
    private static let trailingNumber = Pattern(#"^(.+)-(\d+)$"#, caseInsensitive: false)
    private static let episodeIDPattern = Pattern(#"<input[^>]*\bid="e_id"[^>]*\bvalue="(\d+)""#)
    private static let dataCSRF = Pattern(#"data-csrf="([^"]+)""#)
    private static let metaCSRF = Pattern(#"<meta name="csrf-token" content="([^"]+)""#)
    private static let languageCode = Pattern(#"^[a-z]{2,3}(?:-[A-Za-z]{2,4})?$"#, caseInsensitive: false)
}
