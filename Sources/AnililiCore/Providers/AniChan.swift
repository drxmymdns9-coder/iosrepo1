import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AniChan (anichan.to), ported from the Android app's `AniChanProvider`: JSON throughout and keyed
/// by the AniList id, so there's no search and no title matching.
///
/// ```
/// GET  /api/watch/episodes?anilistId=154587        -> {"episodes":28,"dubAvailable":true}
/// POST /api/watch/session  {"token":""}            -> Set-Cookie: anichan_ws=…  (2 h)
/// GET  /api/watch/servers?anilistId=&ep=&category= -> {"servers":[…]}
/// ```
///
/// Its own server answers a 1080p master with soft subtitles in a dozen languages, and needs no
/// Referer. Segments arrive as `.ts.png` with an image content type, which the app's stream proxy
/// straightens out for AVPlayer.
///
/// Behind Cloudflare: a client whose User-Agent doesn't match its TLS stack is refused outright
/// (see `HTTP.browserUserAgent`).
public actor AniChan: StreamProvider {
    public nonisolated let id = "anichan"
    public nonisolated let name = "AniChan"

    public static let base = "https://anichan.to"

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let fetch: Fetch
    private var session: (cookie: String, expires: Date)?
    private var counts: [Int: (at: Date, listing: EpisodeListing)] = [:]

    static let listingTTL: TimeInterval = 30 * 60

    public init() {
        fetch = { request in try await HTTP.data(for: request) }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        if let cached = counts[media.id], Date().timeIntervalSince(cached.at) < Self.listingTTL { return cached.listing }
        let (status, root) = try await getJSON("/api/watch/episodes?anilistId=\(media.id)", cookie: nil)
        guard status == 200, let root else { throw HTTPError(status: status, "AniChan answered HTTP \(status)") }
        guard let listing = AniChanParser.listing(root) else { throw ProviderError.titleNotFound(provider: name) }
        Log.info("anichan", "\(media.id): \(listing.episodes.count) episodes, dub \(listing.dubbed.isEmpty ? "no" : "yes")")
        counts[media.id] = (Date(), listing)
        return listing
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        let path = "/api/watch/servers?anilistId=\(media.id)&ep=\(episode)&category=\(audio == .dub ? "dub" : "sub")"
        var (status, root) = try await getJSON(path, cookie: try await sessionCookie())
        if status == 401 {
            // The cookie can lapse before its stated expiry; the refusal is the authority.
            session = nil
            (status, root) = try await getJSON(path, cookie: try await sessionCookie())
        }
        guard status == 200, let root else { throw HTTPError(status: status, "AniChan answered HTTP \(status) for episode \(episode)") }
        let sources = AniChanParser.sources(root["servers"], provider: name)
        guard !sources.isEmpty else { throw ProviderError.noStreams(episode: episode, audio: audio) }
        Log.info("anichan", "\(media.id) ep \(episode) \(audio.rawValue): \(sources.map(\.label).joined(separator: ", "))")
        return sources
    }

    // MARK: - Requests

    /// A live `anichan_ws` cookie, minted when missing or spent. The `token` would be a Turnstile
    /// answer; the site publishes no Turnstile key, so an empty one is accepted (as on Android).
    private func sessionCookie() async throws -> String {
        if let session, Date() < session.expires { return session.cookie }
        var request = request(path: "/api/watch/session")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"token":""}"#.utf8)
        let (data, response) = try await fetch(request)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError(status: response.statusCode, "AniChan refused a session (HTTP \(response.statusCode))")
        }
        guard let cookie = AniChanParser.sessionCookie(response.value(forHTTPHeaderField: "Set-Cookie")) else {
            throw HTTPError("AniChan's session carried no cookie")
        }
        let expires = (try? JSON.parse(data))?["exp"]?.number.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(7200)
        session = (cookie, expires.addingTimeInterval(-60))
        return cookie
    }

    private func getJSON(_ path: String, cookie: String?) async throws -> (Int, JSON?) {
        var request = request(path: path)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await fetch(request)
        return (response.statusCode, try? JSON.parse(data))
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.base + path)!)
        request.httpShouldHandleCookies = false
        request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.base + "/", forHTTPHeaderField: "Referer")
        return request
    }
}

/// Pure payload handling for `AniChan`, kept network-free for tests.
enum AniChanParser {
    /// `episodes` is a count; `dubAvailable` is all it says about the dub, so the whole run is
    /// trusted to have one when it's true. A zero count is a title AniChan doesn't carry.
    static func listing(_ root: JSON) -> EpisodeListing? {
        let count = Int(root["episodes"]?.number ?? 0)
        guard count > 0 else { return nil }
        let numbers = Array(1...count)
        let dubbed = root["dubAvailable"]?.bool == true
        return EpisodeListing(episodes: numbers.map(EpisodeInfo.init(number:)), subbed: Set(numbers), dubbed: dubbed ? Set(numbers) : [])
    }

    static func sessionCookie(_ header: String?) -> String? {
        guard let header, let range = header.range(of: "anichan_ws=") else { return nil }
        let value = header[range.lowerBound...].prefix { $0 != ";" && $0 != "," }
        return value.count > "anichan_ws=".count ? String(value) : nil
    }

    /// Ranked, de-duplicated servers with a stream. The megaplay ones and vidhawk are left out:
    /// they're AniKoto's backend under other names (Android's deny list). Subtitles come from the
    /// leading server only, `.vtt` only: each list is cut for its own encode.
    static func sources(_ servers: JSON?, provider: String) -> [VideoSource] {
        let usable = (servers?.array ?? [])
            .filter { server in
                let name = server["name"]?.string ?? ""
                return !name.lowercased().hasPrefix("megaplay") && name.lowercased() != "vidhawk" && server["stream"]?.string != nil
            }
            .sorted { ($0["rank"]?.number ?? .infinity) < ($1["rank"]?.number ?? .infinity) }
        guard let leader = usable.first else { return [] }
        var seen = Set<String>()
        let subtitles = (leader["subtitles"]?.array ?? []).compactMap { track -> SubtitleTrack? in
            guard let text = track["url"]?.string, let url = URL(string: absolute(text)), seen.insert(url.absoluteString).inserted else { return nil }
            let label = track["lang"]?.string ?? "Subtitles"
            return SubtitleTrack(url: url, label: label, language: language(label), isDefault: track["default"]?.bool ?? false)
        }
        return usable.enumerated().compactMap { index, server in
            guard let text = server["stream"]?.string, let url = URL(string: absolute(text)) else { return nil }
            let label = server["label"]?.string?.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "★")).trimmingCharacters(in: .whitespaces)
            let own = index == 0 ? subtitles : []
            return VideoSource(url: url, provider: provider, server: label?.nonBlank ?? server["name"]?.string ?? "Server \(index + 1)",
                               kind: .hls, subtitles: own, softSub: !own.isEmpty)
        }
    }

    /// Site-relative URLs get the origin; spaces (AniChan names subtitle files "English (CR)0.vtt")
    /// become %20 and nothing else is touched: `+` is refused, and a general escaper would turn
    /// a stream URL's own `%2F` into `%252F`.
    static func absolute(_ url: String) -> String {
        (url.hasPrefix("/") ? AniChan.base + url : url).replacingOccurrences(of: " ", with: "%20")
    }

    static func language(_ label: String) -> String {
        let lower = label.lowercased()
        let table: [(String, String)] = [("eng", "en"), ("spa", "es"), ("por", "pt"), ("fre", "fr"), ("fra", "fr"), ("ger", "de"), ("deu", "de"),
                                         ("ita", "it"), ("ara", "ar"), ("rus", "ru"), ("ind", "id"), ("kor", "ko"), ("jap", "ja"), ("chi", "zh"), ("zho", "zh")]
        return table.first { lower.hasPrefix($0.0) }?.1 ?? "und"
    }
}
