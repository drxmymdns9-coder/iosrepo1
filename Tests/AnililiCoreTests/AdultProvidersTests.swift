import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AnililiCore

/// The adult-only servers (Android's `HentaiHavenParserTest`, `HStreamParserTest`,
/// `HanimeCatalogTest`) and the uncounted-episodes fallback (`DetailEpisodeCatalogTest`), on
/// trimmed copies of what the sites served on 2026-10-16.
struct AdultProvidersTests {
    static let imaizumiSlug = "imaizumin-chi-wa-douyara-gal-no-tamariba-ni-natteru-rashii"

    /// AniList 132203 as AniList files it: a running OVA series with no total and no schedule.
    static var imaizumi: Media {
        var media = Media(id: 132203, title: .init(romaji: "Imaizumin-chi wa Douyara Gal no Tamariba ni Natteru Rashii",
                                                   native: "イマイズミンちはどうやらギャルの溜まり場になってるらしい"))
        media.isAdult = true
        media.status = "RELEASING"
        media.format = "OVA"
        return media
    }

    // MARK: - Matching

    @Test func titlesMatchAcrossPunctuationButNotAcrossShows() {
        #expect(AdultTitles.similarity("Maki-chan to Nau.", "maki chan to nau") == 1)
        #expect(AdultTitles.similarity("Overflow", "Overflow") == 1)
        #expect(AdultTitles.similarity("Imaizumin-chi", "Super GALS! Kotobuki Ran") < 0.3)
        #expect(AdultTitles.plainScore(AdultTitles.candidates(Self.imaizumi), Self.imaizumiSlug) == 1)
    }

    @Test func hstreamSpellingsAreRescuedAndSeasonsKeptApart() {
        #expect(AdultTitles.seriesScore(["Ito wo Yoru"], "ito-o-yoru") >= AdultTitles.matchThreshold)
        #expect(AdultTitles.seriesScore(["Imouto Paradise! 2"], "imouto-paradise-s2") >= AdultTitles.matchThreshold)
        #expect(AdultTitles.seriesScore(["Inyouchuu: The Animation"], "inyouchuu-the-animation") >= AdultTitles.matchThreshold)
        #expect(AdultTitles.seriesScore(["Yarichin Kateikyoushi Netori Houkoku: Something Longer"], "yarichin-kateikyoushi-netori-houkoku") >= AdultTitles.matchThreshold)
        // Season one against the season-two slug scored 0.93 before the number check.
        #expect(AdultTitles.seriesScore(["Imouto Paradise!"], "imouto-paradise-s2") == 0)
        var season1 = Media(id: 1, title: .init(romaji: "Imouto Paradise!"))
        season1.isAdult = true
        #expect(AdultTitles.bestSlug(season1, in: ["imouto-paradise-s2", "imouto-paradise"], score: AdultTitles.seriesScore) == "imouto-paradise")
    }

    // MARK: - Hentai Haven

    static let hentaiHavenSitemap = """
    <url>
    <loc>https://hentaihaven.xxx/watch/\(imaizumiSlug)/</loc>
    <lastmod>2026-10-15T19:07:40+00:00</lastmod>
    <xhtml:link rel="alternate" hreflang="es" href="https://hentaihaven.xxx/es/watch/\(imaizumiSlug)/"/>
    </url>
    <url><loc>https://hentaihaven.xxx/watch/overflow/</loc></url>
    <url><loc>https://hentaihaven.xxx/watch/overflow/</loc></url>
    """

    static let octopusMaster = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-MEDIA:URI="snd/a.m3u8",TYPE=AUDIO,GROUP-ID="audio",LANGUAGE="en",NAME="English",DEFAULT=YES,AUTOSELECT=YES
    #EXT-X-MEDIA:URI="s/ar.vtt",TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="ar",NAME="Ar",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO
    #EXT-X-MEDIA:URI="s/de.vtt",TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="de",NAME="German",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO
    #EXT-X-MEDIA:URI="s/en.vtt",TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="en",NAME="English",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO
    #EXT-X-STREAM-INF:BANDWIDTH=2077570,RESOLUTION=1280x720,CODECS="avc1.4d4028,mp4a.40.2",AUDIO="audio",SUBTITLES="subs"
    7sop/v.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d4028,mp4a.40.2",AUDIO="audio",SUBTITLES="subs"
    3cop/v.m3u8
    """

    @Test func hentaiHavenReadsSeriesFromTheSitemapOnly() {
        #expect(HentaiHavenParser.sitemapSlugs(Self.hentaiHavenSitemap) == [Self.imaizumiSlug, "overflow"])
    }

    @Test func hentaiHavenCountsOnlyTheSeriesOwnEpisodes() {
        let page = """
        <a href="/watch/\(Self.imaizumiSlug)/episode-1">1</a><a href="/watch/\(Self.imaizumiSlug)/episode-2/">2</a>
        <a href="/watch/\(Self.imaizumiSlug)/episode-2">again</a>
        <div class="popular"><a href="/watch/overflow/episode-8">Overflow 8</a></div>
        """
        #expect(HentaiHavenParser.episodeNumbers(page, slug: Self.imaizumiSlug) == [1, 2])
    }

    @Test func hentaiHavenFindsEitherManifestBackend() {
        let octopus = #"<script>self.__next_f.push([1,"{\"src\":\"https://octopusmanifest.org/680f3765-a3fd-4523-a502-f5d542675ebf/playlist.m3u8\"}"])</script>"#
        #expect(HentaiHavenParser.manifestURL(octopus)?.absoluteString == "https://octopusmanifest.org/680f3765-a3fd-4523-a502-f5d542675ebf/playlist.m3u8")
        let lengs = #"<video src="https://master-lengs.org/api/v3/hh/overflow-1/master.m3u8"></video>"#
        #expect(HentaiHavenParser.manifestURL(lengs)?.host == "master-lengs.org")
        #expect(HentaiHavenParser.manifestURL("<html>nothing</html>") == nil)
    }

    @Test func octopusSubtitleFilesBecomeSideloadedTracks() throws {
        let base = try #require(URL(string: "https://octopusmanifest.org/680f3765/playlist.m3u8"))
        let tracks = HentaiHavenParser.subtitleFiles(Self.octopusMaster, base: base)
        #expect(tracks.map(\.language) == ["en", "ar", "de"])
        #expect(tracks.first?.isDefault == true)
        #expect(tracks.first?.url.absoluteString == "https://octopusmanifest.org/680f3765/s/en.vtt")
        #expect(tracks.map(\.label) == ["English", "Arabic", "German"])
    }

    @Test func theProxyDropsFileSubtitleRenditionsAndTheirGroup() {
        let cleaned = StreamRewrite.droppingFileSubtitles(Self.octopusMaster)
        #expect(!cleaned.contains("TYPE=SUBTITLES"))
        #expect(!cleaned.contains("SUBTITLES=\"subs\""))
        #expect(cleaned.contains(#"AUDIO="audio""#))
        #expect(cleaned.contains("TYPE=AUDIO"))
        #expect(cleaned.contains("7sop/v.m3u8") && cleaned.contains("3cop/v.m3u8"))
        // A proper subtitle playlist, and the group it belongs to, are left alone.
        let proper = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="en",NAME="English",URI="subs/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1,SUBTITLES="subs"
        v.m3u8
        """
        #expect(StreamRewrite.droppingFileSubtitles(proper) == proper)
        #expect(StreamRewrite.attributes(#"#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="avc1,mp4a",AUDIO="a""#)["CODECS"] == "avc1,mp4a")
    }

    @Test func hentaiHavenListsAndResolvesThroughItsPages() async throws {
        let series = "<a href=\"/watch/\(Self.imaizumiSlug)/episode-1\"></a><a href=\"/watch/\(Self.imaizumiSlug)/episode-2\"></a>"
        let episode = #"<p>"https://octopusmanifest.org/680f3765/playlist.m3u8"</p>"#
        let provider = HentaiHaven { url in
            switch url.absoluteString {
            case "https://hentaihaven.xxx/en-manga-sitemap-1.xml": return (200, Data(Self.hentaiHavenSitemap.utf8))
            case "https://hentaihaven.xxx/en-manga-sitemap-2.xml": return (404, Data())
            case "https://hentaihaven.xxx/watch/\(Self.imaizumiSlug)/": return (200, Data(series.utf8))
            case "https://hentaihaven.xxx/watch/\(Self.imaizumiSlug)/episode-2/": return (200, Data(episode.utf8))
            case "https://octopusmanifest.org/680f3765/playlist.m3u8": return (200, Data(Self.octopusMaster.utf8))
            default: Issue.record("unexpected \(url)"); return (404, Data())
            }
        }
        let listing = try await provider.episodes(for: Self.imaizumi)
        #expect(listing.subbed == [1, 2])
        #expect(listing.dubbed.isEmpty)
        let sources = try await provider.sources(for: Self.imaizumi, episode: 2, audio: .sub)
        #expect(sources.count == 1)
        #expect(sources.first?.kind == .hls)
        #expect(sources.first?.softSub == true)
        #expect(sources.first?.subtitles.count == 3)
        #expect(try await provider.sources(for: Self.imaizumi, episode: 2, audio: .dub).isEmpty)
        // A title it doesn't carry is "not here", not a failure.
        #expect(try await provider.episodes(for: Media(id: 9, title: .init(romaji: "Shingeki no Kyojin"))).isEmpty)
    }

    // MARK: - hstream

    static let hstreamSitemap = """
    <url><loc>https://hstream.moe</loc></url>
    <url><loc>https://hstream.moe/hentai/\(imaizumiSlug)</loc></url>
    <url><loc>https://hstream.moe/hentai/\(imaizumiSlug)-2</loc></url>
    <url><loc>https://hstream.moe/hentai/\(imaizumiSlug)-1</loc></url>
    <url><loc>https://hstream.moe/hentai/kanojo-x-kanojo-x-kanojo-3</loc></url>
    <url><loc>https://hstream.moe/hentai/imouto-paradise-s2</loc></url>
    <url><loc>https://hstream.moe/hentai/imouto-paradise-s2-1</loc></url>
    """

    static let playerAnswer = #"""
    {"title":"Imaizumin Chi wa Douyara Gal no Tamariba ni Natteru Rashii - 1","stream_url":"2022\/Imaizumin-chi.wa.Douyara\/E01v2",
     "stream_domains":["https:\/\/imoto-str.ane-h.xyz","https:\/\/chibi-str.imoto-h.xyz\/","http:\/\/insecure.example"],
     "asia_stream_domains":["https:\/\/komako-b-str.musume-h.xyz"],"extra_subtitles":{"es":"Spanish","bad code":"x","de":"German"}}
    """#

    @Test func hstreamEpisodesAreSeriesPlusANumber() {
        let catalogue = HStreamParser.catalogue(Self.hstreamSitemap)
        #expect(catalogue[Self.imaizumiSlug] == [1, 2])
        #expect(catalogue["imouto-paradise-s2"] == [1])
        // Its series page isn't listed, so this is no episode of "kanojo-x-kanojo-x-kanojo".
        #expect(catalogue["kanojo-x-kanojo-x-kanojo"] == nil)
    }

    @Test func hstreamPageAndPlayerAnswerParse() throws {
        let page = #"<meta name="csrf-token" content="meta-token"><input id="e_id" type="hidden" value="202" /><div data-csrf="GsmYH5iJ"></div>"#
        #expect(HStreamParser.episodeID(page) == "202")
        #expect(HStreamParser.csrfToken(page) == "GsmYH5iJ")
        #expect(HStreamParser.csrfToken(#"<meta name="csrf-token" content="meta-token">"#) == "meta-token")

        let player = try #require(HStreamParser.player(Data(Self.playerAnswer.utf8)))
        #expect(player.streamPath == "2022/Imaizumin-chi.wa.Douyara/E01v2")
        #expect(player.mirrors == ["https://imoto-str.ane-h.xyz", "https://chibi-str.imoto-h.xyz"])
        #expect(player.extraSubtitles == ["es": "Spanish", "de": "German"])
        #expect(HStreamParser.player(Data(#"{"stream_url":"x","stream_domains":[],"extra_subtitles":[]}"#.utf8)) == nil)
    }

    @Test func hstreamOffersTheMP4OnTwoMirrorsWithItsSubtitles() throws {
        let player = try #require(HStreamParser.player(Data(Self.playerAnswer.utf8)))
        let sources = HStreamParser.sources(player, provider: "HStream", mirrorStart: 1)
        #expect(sources.map(\.url.absoluteString) == [
            "https://chibi-str.imoto-h.xyz/2022/Imaizumin-chi.wa.Douyara/E01v2/x264.720p.mp4",
            "https://imoto-str.ane-h.xyz/2022/Imaizumin-chi.wa.Douyara/E01v2/x264.720p.mp4",
        ])
        #expect(sources.allSatisfy { $0.kind == .mp4 && $0.softSub && $0.headers.isEmpty })
        let subtitles = try #require(sources.first?.subtitles)
        #expect(subtitles.map(\.label) == ["English", "German (auto-translated)", "Spanish (auto-translated)"])
        #expect(subtitles[0].url.absoluteString == "https://chibi-str.imoto-h.xyz/2022/Imaizumin-chi.wa.Douyara/E01v2/eng.vtt")
        #expect(subtitles[1].url.lastPathComponent == "de.ass")
    }

    @Test func hstreamCarriesThePageSessionIntoThePlayerAPI() async throws {
        let page = #"<input id="e_id" type="hidden" value="202" /><div data-csrf="token-1"></div>"#
        let provider = HStream(load: { request in
            switch (request.httpMethod ?? "GET", request.url?.absoluteString ?? "") {
            case ("GET", "https://hstream.moe/sitemap.xml"):
                return .init(status: 200, body: Self.hstreamSitemap, cookies: "")
            case ("GET", "https://hstream.moe/hentai/\(Self.imaizumiSlug)-1"):
                return .init(status: 200, body: page, cookies: "XSRF-TOKEN=x; hstream_session=s")
            case ("POST", "https://hstream.moe/player/api"):
                #expect(request.value(forHTTPHeaderField: "Cookie") == "XSRF-TOKEN=x; hstream_session=s")
                #expect(request.value(forHTTPHeaderField: "X-CSRF-TOKEN") == "token-1")
                let body = try #require(request.httpBody.flatMap { try? JSON.parse($0) })
                #expect(body["episode_id"]?.string == "202")
                return .init(status: 200, body: Self.playerAnswer, cookies: "")
            default:
                Issue.record("unexpected \(request.url?.absoluteString ?? "?")")
                return .init(status: 404, body: "", cookies: "")
            }
        })
        #expect(try await provider.episodes(for: Self.imaizumi).subbed == [1, 2])
        let sources = try await provider.sources(for: Self.imaizumi, episode: 1, audio: .sub)
        #expect(sources.first?.url.host == "imoto-str.ane-h.xyz")
        await #expect(throws: ProviderError.self) { try await provider.sources(for: Self.imaizumi, episode: 7, audio: .sub) }
    }

    @Test func setCookieLinesBecomeOneCookieHeader() throws {
        let url = try #require(URL(string: "https://hstream.moe/hentai/x-1"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Set-Cookie": "XSRF-TOKEN=abc%3D; expires=Fri, 16 Oct 2026 22:00:00 GMT; Max-Age=7200; path=/; samesite=lax",
        ]))
        #expect(HStreamParser.cookieHeader(response) == "XSRF-TOKEN=abc%3D")
    }

    // MARK: - hanime

    static let hanimeCatalogue = """
    {"data":[
     {"id":3301,"name":"Imaizumin-chi wa Douyara Gal no Tamariba ni Natteru Rashii 2","slug":"\(imaizumiSlug)-2","search_titles":"イマイズミンち","tags":[]},
     {"id":3300,"name":"Imaizumin-chi wa Douyara Gal no Tamariba ni Natteru Rashii 1","slug":"\(imaizumiSlug)-1","search_titles":"","tags":[]},
     {"id":5,"name":"Yabai! Fukushuu Yami Site 2","slug":"yabai-fukushuu-yami-site-2"},
     {"id":7,"name":"Kuroinu","slug":"kuroinu"}
    ]}
    """

    @Test func hanimeCatalogueReadsBothShapes() throws {
        let wrapped = try HanimeParser.catalogue(Data(Self.hanimeCatalogue.utf8))
        #expect(wrapped.count == 4)
        let bare = try HanimeParser.catalogue(Data(#"[{"id":1,"name":"Kuroinu","slug":"kuroinu"}]"#.utf8))
        #expect(bare.first?.episodeNumber == 1)
        #expect(bare.first?.seriesSlug == "kuroinu")
        #expect(throws: (any Error).self) { try HanimeParser.catalogue(Data(#"{"error":"nope"}"#.utf8)) }
    }

    @Test func hanimeMatchesASeriesAndOrdersItsEpisodes() throws {
        let catalogue = try HanimeParser.catalogue(Data(Self.hanimeCatalogue.utf8))
        let series = HanimeParser.match(Self.imaizumi, catalogue)
        #expect(series.map(\.episodeNumber) == [1, 2])
        #expect(series.first?.slug == "\(Self.imaizumiSlug)-1")
        #expect(HanimeParser.match(Media(id: 2, title: .init(romaji: "Kuroinu: Kedakaki Seijo wa Hakudaku ni Somaru")), catalogue).isEmpty)
    }

    @Test func hanimeKeepsOnlyTheRungsThatAreStreams() throws {
        let ladder = try JSONDecoder().decode([Hanime.Rung].self, from: Data("""
        [{"src":"","label":"1080p","kind":"promotion","width":1920,"height":1080},
         {"src":"/hls/2465/abc","label":"480p","kind":"normal","width":"854","height":"480"},
         {"src":"/hls/2465/def","label":"720p","kind":"normal","width":1280,"height":720}]
        """.utf8))
        let sources = HanimeParser.sources(ladder, provider: "Hanime")
        #expect(sources.map(\.server) == ["720p", "480p"])
        #expect(sources.first?.url.absoluteString == "https://hanime.tv/hls/2465/def")
    }

    @Test func hanimeListsWithoutAWebViewButNeedsOneToPlay() async throws {
        let catalogue = Self.hanimeCatalogue
        let provider = Hanime(fetch: { _ in (200, Data(catalogue.utf8)) }, resolver: nil)
        #expect(try await provider.episodes(for: Self.imaizumi).subbed == [1, 2])
        await #expect(throws: HTTPError.self) { try await provider.sources(for: Self.imaizumi, episode: 1, audio: .sub) }

        let resolving = Hanime(fetch: { _ in (200, Data(catalogue.utf8)) }, resolver: { slug in
            #expect(slug == "\(Self.imaizumiSlug)-2")
            return [Hanime.Rung(src: "/hls/1/x", label: "720p", height: 720)]
        })
        #expect(try await resolving.sources(for: Self.imaizumi, episode: 2, audio: .sub).count == 1)
    }

    // MARK: - SourceHub

    private struct Fixed: StreamProvider {
        let id: String
        var name: String { id }
        let listing: EpisodeListing
        func episodes(for media: Media) async throws -> EpisodeListing { listing }
        func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] { [] }
    }

    private static func listing(_ count: Int) -> EpisodeListing { ProviderSupport.counts(sub: count, dub: 0) }

    @Test func anUncountedAdultTitleListsOnlyWhatTheAdultServersCarry() async throws {
        // A general server's matcher paired Imaizumin-chi with Super GALS! (50 episodes).
        let hub = SourceHub(providers: [Fixed(id: "reanime", listing: Self.listing(50)), Fixed(id: "hstream", listing: Self.listing(6)),
                                        Fixed(id: "hentaihaven", listing: Self.listing(5))])
        #expect(Self.imaizumi.episodeCountUnknown)
        #expect(try await hub.episodes(for: Self.imaizumi).episodes.count == 6)

        // Counted by AniList: every server's rows, as before.
        var counted = Self.imaizumi
        counted.episodes = 2
        #expect(try await hub.episodes(for: counted).episodes.count == 50)

        // No adult server has it: the others still answer.
        let none = SourceHub(providers: [Fixed(id: "reanime", listing: Self.listing(3)), Fixed(id: "hstream", listing: .empty)])
        #expect(try await none.episodes(for: Self.imaizumi).episodes.count == 3)
    }

    @Test func adultServersAreAskedOnlyForAdultTitlesAndOnlyWhenShown() async throws {
        let hub = SourceHub(providers: [Fixed(id: "miruro", listing: Self.listing(12)), Fixed(id: "hstream", listing: Self.listing(40))])
        var general = Media(id: 5, title: .init(romaji: "Overflow"))
        general.isAdult = false
        #expect(hub.providers(for: general).map(\.id) == ["miruro"])
        #expect(try await hub.episodes(for: general).episodes.count == 12)
        // For an adult title they lead, so their answer is waited for and their streams go first.
        #expect(hub.providers(for: Self.imaizumi).map(\.id) == ["hstream", "miruro"])

        #expect(!SourceHub.selectable(hideAdult: true).contains { SourceHub.isAdultOnly($0.id) })
        #expect(SourceHub.selectable(hideAdult: false).filter { SourceHub.isAdultOnly($0.id) }.map(\.id) == ["hentaihaven", "hstream", "hanime"])
    }

    @Test func episodeCountUnknownIsOnlyForReleasedTitlesWithoutACountOrSchedule() {
        var media = Media(id: 1, title: .init(romaji: "x"))
        media.status = "RELEASING"
        #expect(media.episodeCountUnknown)
        media.nextAiringEpisode = .init(episode: 4, airingAt: 0)
        #expect(!media.episodeCountUnknown)
        media.nextAiringEpisode = nil
        media.status = "NOT_YET_RELEASED"
        #expect(!media.episodeCountUnknown)
        media.status = "FINISHED"
        media.episodes = 2
        #expect(!media.episodeCountUnknown)
    }
}
