import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Hentai Haven, ported from the Android app's `HentaiHavenProvider` (the Next.js site, since
/// 2026-09-21). An adult-only server: `SourceHub` asks it only while "Hide adult content" is off.
///
/// ```
/// GET hentaihaven.xxx/en-manga-sitemap-{1,2}.xml   -> every series slug (~1,050), held a day
/// GET hentaihaven.xxx/watch/{slug}/                -> its episode links
/// GET hentaihaven.xxx/watch/{slug}/episode-{n}/    -> the HLS URL, written in the page
/// ```
///
/// The manifest needs no User-Agent, Referer or cookie. Two backends appear:
/// `octopusmanifest.org/{uuid}/playlist.m3u8` (720p and 360p fMP4, with WebVTT subtitles in about
/// twenty languages) and `master-lengs.org/api/v3/hh/{slug}-{n}/master.m3u8` (no subtitles).
///
/// octopus lists its subtitles as `EXT-X-MEDIA` renditions whose URI is a bare `.vtt` file rather
/// than a playlist. ExoPlayer copes; AVPlayer wants a playlist there, so the app's stream proxy
/// drops those renditions (`StreamRewrite.droppingFileSubtitles`) and this provider hands the same
/// files over as sideloaded tracks instead. The video carries no burned-in subtitles (checked on
/// Imaizumin-chi episode 1, 2026-10-16), so it counts as soft-subbed.
///
/// The site's search answers a fixed grid to every query, so series are matched by name against
/// the sitemap instead.
public actor HentaiHaven: StreamProvider {
    public nonisolated let id = "hentaihaven"
    public nonisolated let name = "Hentai Haven"

    static let base = "https://hentaihaven.xxx"
    /// The English series sitemaps. The index repeats them per locale and adds a rule34 section
    /// with no playable `/watch/` slug, so only these two are fetched.
    static let sitemaps = ["en-manga-sitemap-1.xml", "en-manga-sitemap-2.xml"]

    typealias Fetch = @Sendable (URL) async throws -> (Int, Data)

    private let fetch: Fetch
    private let catalogue = CatalogueCache<[String]>(ttl: 24 * 3600, isEmpty: { $0.isEmpty })
    /// Slug per AniList id; saves a catalogue pass on every episode change.
    private var slugs: [Int: String] = [:]

    public init() {
        fetch = { url in
            var request = URLRequest(url: url)
            request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(HentaiHaven.base + "/", forHTTPHeaderField: "Referer")
            request.setValue("text/html,application/xml,*/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await HTTP.data(for: request)
            return (response.statusCode, data)
        }
    }

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public func episodes(for media: Media) async throws -> EpisodeListing {
        guard let slug = try await seriesSlug(media) else { return .empty }
        let numbers = HentaiHavenParser.episodeNumbers(try await text("\(Self.base)/watch/\(slug)/"), slug: slug)
        Log.info("hentaihaven", "\(media.id) → \(slug): \(numbers.count) episodes")
        // Japanese audio; the subtitles are files, and there is no dub.
        return EpisodeListing(episodes: numbers.sorted().map(EpisodeInfo.init(number:)), subbed: numbers, dubbed: [])
    }

    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        guard audio == .sub else { return [] }
        guard let slug = try await seriesSlug(media) else { throw ProviderError.titleNotFound(provider: name) }
        // The trailing slash is the canonical form; without it every resolve eats a 301 first.
        let page = try await text("\(Self.base)/watch/\(slug)/episode-\(episode)/")
        guard let manifest = HentaiHavenParser.manifestURL(page) else {
            throw ProviderError.episodeNotFound(provider: name, episode: episode)
        }
        // The subtitle files are named in the master; a failure there costs only the subtitles.
        var subtitles: [SubtitleTrack] = []
        if let (status, data) = try? await fetch(manifest), (200..<300).contains(status) {
            subtitles = HentaiHavenParser.subtitleFiles(String(decoding: data, as: UTF8.self), base: manifest)
        }
        Log.info("hentaihaven", "\(slug) ep \(episode): \(manifest.host ?? "?"), \(subtitles.count) subtitle files")
        return [VideoSource(url: manifest, provider: name, server: HentaiHavenParser.server(manifest), kind: .hls,
                            headers: ["Referer": Self.base + "/"], subtitles: subtitles, softSub: !subtitles.isEmpty)]
    }

    private func seriesSlug(_ media: Media) async throws -> String? {
        if let known = slugs[media.id] { return known }
        let all = try await catalogue.get { [fetch] in
            var found: [String] = []
            for sitemap in Self.sitemaps {
                // One sitemap down still leaves the other's half of the library.
                guard let (status, data) = try? await fetch(URL(string: "\(Self.base)/\(sitemap)")!), (200..<300).contains(status) else { continue }
                found += HentaiHavenParser.sitemapSlugs(String(decoding: data, as: UTF8.self))
            }
            Log.info("hentaihaven", "catalogue: \(found.count) series")
            if found.isEmpty { throw HTTPError("Hentai Haven's sitemaps listed no series") }
            return found
        }
        let slug = AdultTitles.bestSlug(media, in: all, score: AdultTitles.plainScore)
        if let slug { slugs[media.id] = slug }
        return slug
    }

    private func text(_ address: String) async throws -> String {
        let (status, data) = try await fetch(URL(string: address)!)
        guard (200..<300).contains(status) else { throw HTTPError(status: status, "Hentai Haven answered HTTP \(status)") }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Pure parsing for `HentaiHaven`, kept network-free for tests.
enum HentaiHavenParser {
    /// Series slugs from one sitemap: an entry's `<loc>`, never its locale alternates.
    static func sitemapSlugs(_ xml: String) -> [String] {
        var seen = Set<String>()
        return sitemapEntry.matches(in: xml).compactMap { $0[1] }.filter { seen.insert($0).inserted }
    }

    /// Episode numbers a series page links to **for that series only**: the page's "Popular" and
    /// "See More" widgets link to other series' episodes, and an unscoped scan once gave a
    /// two-episode title a third from the sidebar.
    static func episodeNumbers(_ html: String, slug: String) -> Set<Int> {
        let scoped = Pattern("/watch/\(Pattern.escape(slug))/episode-(\\d+)", caseInsensitive: false)
        return Set(scoped.matches(in: html).compactMap { $0[1].flatMap(Int.init) }.filter { $0 > 0 })
    }

    /// The HLS URL an episode page carries, matched on nothing but the `.m3u8` ending: the site has
    /// moved its manifests once already, and the two hosts in use share no other structure.
    static func manifestURL(_ html: String) -> URL? {
        manifest.firstMatch(in: html)?[0].flatMap(URL.init(string:))
    }

    /// The master's subtitle renditions that are plain files rather than playlists, as tracks the
    /// player loads itself; the default first.
    static func subtitleFiles(_ playlist: String, base: URL) -> [SubtitleTrack] {
        var tracks: [SubtitleTrack] = []
        var seen = Set<URL>()
        for line in playlist.components(separatedBy: .newlines) where line.hasPrefix("#EXT-X-MEDIA:") {
            let attributes = StreamRewrite.attributes(line)
            guard attributes["TYPE"] == "SUBTITLES", let uri = attributes["URI"], StreamRewrite.isSubtitleFile(uri),
                  let url = URL(string: uri, relativeTo: base)?.absoluteURL, seen.insert(url).inserted else { continue }
            let code = (attributes["LANGUAGE"] ?? "und").lowercased()
            tracks.append(SubtitleTrack(url: url, label: label(code: code, name: attributes["NAME"]), language: code,
                                        isDefault: attributes["DEFAULT"] == "YES"))
        }
        return tracks.filter(\.isDefault) + tracks.filter { !$0.isDefault }
    }

    /// The backend a manifest is on, as the picker names it ("Octopusmanifest", "Master-lengs").
    static func server(_ manifest: URL) -> String {
        manifest.host?.components(separatedBy: ".").first?.capitalized ?? "HLS"
    }

    /// octopus names half its tracks properly ("German") and the rest by a capitalised code ("Ar").
    static func label(code: String, name: String?) -> String {
        if let name = name?.nonBlank, name.count > 3 { return name }
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? name ?? code
    }

    private static let sitemapEntry = Pattern(#"<loc>https://hentaihaven\.xxx/watch/([a-z0-9-]+)/?</loc>"#, caseInsensitive: false)
    private static let manifest = Pattern(#"https://[A-Za-z0-9.-]+/[A-Za-z0-9/_.-]+\.m3u8"#, caseInsensitive: false)
}
