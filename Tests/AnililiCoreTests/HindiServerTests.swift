import Foundation
import Testing
@testable import AnililiCore

/// Android's `AnimeDekhoParserTest`, on its markup.
struct AnimeDekhoTests {
    @Test func searchReadsTheBlockLinkAndDecodedTitle() {
        let html = """
        <article class="post dfx fcl movies">
          <header><h2 class="entry-title">Frieren: Beyond Journey&#8217;s End</h2></header>
          <a href="https://animedekho.app/series-hindi/frieren-hindi/" class="lnk-blk"></a>
        </article>
        """
        #expect(AnimeDekhoParser.search(html) == [.init(url: "https://animedekho.app/series-hindi/frieren-hindi/", title: "Frieren: Beyond Journey’s End")])
    }

    @Test func seasonListsKeepTheirOwnNumbering() {
        let html = """
        <div class="seasons-bx" id="0">
          <div class="seasons-tt"><p>Season <span>1</span></p><span class="date">September 29, 2023</span></div>
          <ul class="seasons-lst anm-a">
            <li><h3 class="title"><span>S1-E1</span> The Journey's End</h3><a href="https://animedekho.app/epi/frieren-1x1/">Watch</a></li>
            <li><h3 class="title"><span>S1-E2</span> Magic</h3><a href="https://animedekho.app/epi/frieren-1x2/">Watch</a></li>
          </ul>
        </div>
        <div class="seasons-bx" id="1">
          <div class="seasons-tt"><p>Season <span>2</span></p><span class="date">10 Episodes</span></div>
          <ul class="seasons-lst anm-a">
            <li><h3 class="title"><span>S2-E1</span> Shall We Go?</h3><a href="https://animedekho.app/epi/frieren-2x1/">Watch</a></li>
          </ul>
        </div>
        """
        let seasons = AnimeDekhoParser.seasons(html)
        #expect(seasons.map(\.number) == [1, 2])
        #expect(seasons.first?.year == 2023)
        #expect(seasons.first?.episodes.map(\.number) == [1, 2])
        #expect(seasons.last?.episodes.map(\.number) == [1])
        #expect(AnimeDekhoParser.selectSeason(seasons, hint: 2, expected: 1, year: 2026)?.number == 2)
        #expect(AnimeDekhoParser.selectSeason(seasons, hint: nil, expected: 2, year: nil)?.number == 1)
        #expect(AnimeDekhoParser.selectSeason(seasons, hint: nil, expected: nil, year: 2023)?.number == 1)
    }

    @Test func resolverIDAndBothIframeAttributes() {
        let html = """
        <body class="term-frieren-1x1 term-47842 wp-theme-toronites">
          <iframe src="https://abyssplayer.example/a1"></iframe>
          <iframe data-src="/aaa/pixel/second"></iframe>
          <iframe src="https://abyssplayer.example/a1"></iframe>
        </body>
        """
        #expect(AnimeDekhoParser.termID(html) == "47842")
        #expect(AnimeDekhoParser.iframes(html, base: "https://animedekho.app") == ["https://abyssplayer.example/a1", "https://animedekho.app/aaa/pixel/second"])
        #expect(AnimeDekhoParser.termID("<body class=plain>") == nil)
    }

    @Test func healthyMirrorsLeadTheDownPlaceholder() {
        let mirrors = [
            "https://animedekho.app/aaa/down/v/dead/", "https://vidcloud.example/#third", "https://vidmoly.example/embed-second.html",
            "https://abyssplayer.example/first", "https://animedekho.app/aaa/pixel/fallback", "https://abyssplayer.example/first",
        ]
        #expect(AnimeDekhoParser.orderMirrors(mirrors, base: "https://animedekho.app") == [
            "https://abyssplayer.example/first", "https://vidmoly.example/embed-second.html", "https://vidcloud.example/#third",
            "https://animedekho.app/aaa/pixel/fallback", "https://animedekho.app/aaa/down/v/dead/",
        ])
        // That placeholder says only "This Server is Down" (seen live, 2026-10-12): never offered.
        #expect(AnimeDekhoParser.isDownPlaceholder("https://animedekho.app/aaa/down/v/JL5chpyd7NnD/"))
        #expect(!AnimeDekhoParser.isDownPlaceholder("https://animedekho.app/aaa/pixel/fallback"))
    }

    @Test func aSequelIsSearchedByItsSeriesFirst() {
        let media = Media(id: 1, title: .init(romaji: "Tensei shitara Slime Datta Ken 2nd Season", english: "That Time I Got Reincarnated as a Slime Season 2"))
        #expect(AnimeDekho.searchQueries(media).first == "That Time I Got Reincarnated as a Slime")
    }
}

/// Android's `ToonHubParserTest`, on its markup.
struct ToonHubTests {
    @Test func searchReadsPostsOnlyAndTellsAMissFromNoAnswer() throws {
        let body = """
        [
          {"id":21397,"title":"Dandadan Season 2 Multi Audio [Hindi-Tamil] 480p, 720p &#038; 1080p",
           "url":"https://toonhub4u.co/dandadan-season-2/","type":"post","subtype":"post"},
          {"title":"DMCA","url":"https://toonhub4u.co/dmca/","type":"post","subtype":"page"},
          {"id":19621,"title":"Dandadan Season 1 Episodes Multi Audio",
           "url":"https://toonhub4u.co/dandadan-season-1/","type":"post","subtype":"post"}
        ]
        """
        let results = try #require(ToonHubParser.search(body))
        #expect(results.map(\.url) == ["https://toonhub4u.co/dandadan-season-2/", "https://toonhub4u.co/dandadan-season-1/"])
        #expect(results.first?.title == "Dandadan Season 2 Multi Audio [Hindi-Tamil] 480p, 720p & 1080p")
        #expect(ToonHubParser.search("[]") == [])
        #expect(ToonHubParser.search("<html>502 Bad Gateway</html>") == nil)
        #expect(ToonHubParser.search("") == nil)
        #expect(ToonHubParser.search(#"{"code":"rest_forbidden"}"#) == nil)
    }

    @Test func episodeBlocksBecomeWatchLinksAndMirrors() {
        let html = """
        <p><strong>Episode 01: The Journey's End</strong></p>
        <p><strong><span>WatchOnline</span> – <a href="https://toonstream.one/episode/frieren-1x1/">Stream</a></strong></p>
        <p><strong>480p – <a href="https://gdmirrorbot.nl/file/first480">Mirrors</a></strong></p>
        <p><strong>1080p – <a href="https://gdmirrorbot.nl/file/first1080">Mirrors</a></strong></p>
        <hr>
        <p><strong>Episode 02: Magic</strong></p>
        <p><strong><span>WatchOnline</span> – <a href="https://toonstream.one/episode/frieren-1x1/">Stream</a></strong></p>
        <p><strong>720p – <a href="/embed/second720">Mirrors</a></strong></p>
        <hr>
        """
        let episodes = ToonHubParser.episodes(html, base: "https://toonhub4u.co")
        #expect(episodes.map(\.number) == [1, 2])
        #expect(episodes[0].links.map(\.url) == ["https://toonstream.one/episode/frieren-1x1/", "https://gdmirrorbot.nl/embed/first480", "https://gdmirrorbot.nl/embed/first1080"])
        #expect(episodes[0].links.map(\.label) == ["Hindi Stream", "480p", "1080p"])
        // Episode two repeated episode one's watch link; the heading repairs it.
        #expect(episodes[1].links.map(\.url) == ["https://toonstream.one/episode/frieren-1x2/", "https://toonhub4u.co/embed/second720"])
    }

    @Test func mirrorLabelsComeFromQualityOrTheParagraph() {
        let unlabelled = ToonHubParser.links(#"<p>Hindi Dubbed – <a href="/embed/one">One</a> <a href="/embed/two">Two</a></p>"#, base: "https://toonhub4u.co")
        #expect(unlabelled.map(\.label) == ["Hindi Dubbed", "Hindi Dubbed"])
        let qualified = ToonHubParser.links(#"<p>Frieren 1080p – <a href="/file/one">One</a> <a href="/file/two">Two</a></p>"#, base: "https://toonhub4u.co")
        #expect(qualified.map(\.label) == ["1080p", "1080p"])
        #expect(qualified.map(\.url) == ["https://toonhub4u.co/embed/one", "https://toonhub4u.co/embed/two"])
        #expect(ToonHubParser.links("<p>No mirrors yet</p>", base: "https://toonhub4u.co").isEmpty)
    }

    @Test func seriesTitleKeepsTheSeriesIdentity() {
        #expect(ToonHubParser.seriesTitle("Frieren: Beyond Journey’s End Season 1 Episodes Hindi Multi Audio Download 1080p") == "Frieren: Beyond Journey’s End")
    }

    @Test func toonStreamPlayersInServerOrderWithoutTheTrailer() {
        let wrapped = """
        <div class="video"><iframe src="/embed/ruby-player"></iframe></div>
        <div class="video"><iframe data-src="/embed/moly-player"></iframe></div>
        <aside class="video-options">
          <span class="server">Ruby</span>
          <span class="server">Moly</span>
        </aside>
        <iframe src="https://www.youtube.com/embed/trailer"></iframe>
        """
        let players = ToonHubParser.playerEmbeds(wrapped, page: "https://toon-stream.site/episode/frieren-1x1/")
        #expect(players.map(\.url) == ["https://toon-stream.site/embed/moly-player", "https://toon-stream.site/embed/ruby-player"])
        #expect(players.map(\.label) == ["Moly", "Ruby"])

        let direct = """
        <div class="video"><iframe src="https://rubystm.com/e/mvybg38ttztw.html"></iframe></div>
        <div class="video"><iframe data-src="https://filesforever.link/embed/hdoyuqt"></iframe></div>
        <div class="video"><iframe data-src="https://cloudy.upns.one/#krga1o"></iframe></div>
        <div class="video"><iframe data-src="https://abyssplayer.com/LR0L1Adhn"></iframe></div>
        <aside class="video-options">
          <span class="server">Ruby</span>
          <span class="server">Watch/DL</span>
          <span class="server">cloudy</span>
          <span class="server">Short</span>
        </aside>
        <iframe width="560" src="https://www.youtube.com/embed/HkIKAnwLZCw"></iframe>
        """
        let page = "https://toonstream.vip/episode/solo-leveling-1x1/"
        let found = ToonHubParser.playerEmbeds(direct, page: page)
        #expect(found.map(\.label) == ["Short", "Ruby", "cloudy", "Watch/DL"])
        #expect(found.map(\.url) == ["https://abyssplayer.com/LR0L1Adhn", "https://rubystm.com/e/mvybg38ttztw.html", "https://cloudy.upns.one/#krga1o", "https://filesforever.link/embed/hdoyuqt"])
        #expect(!found.contains { ToonHubParser.isWrappedPlayer($0.url, page: page) })
        #expect(ToonHubParser.isWrappedPlayer("https://toonstream.vip/embed/8b1788c2", page: page))
    }

    @Test func aWrapperGivesUpItsRealPlayerAndNothingUnsafe() {
        let html = """
        <div class="fake-player-overlay" onclick="redirectToAd()"><div class="play-button"></div></div>
        <div class="Video"><iframe src="https://abyssplayer.com/1vGX4aCXu" allowfullscreen></iframe></div>
        """
        #expect(ToonHubParser.wrappedPlayer(html, page: "https://toon-stream.site/embed/8b1788c217f32ae0") == "https://abyssplayer.com/1vGX4aCXu")
        #expect(ToonHubParser.wrappedPlayer(#"<iframe data-src="/player/episode-1"></iframe>"#, page: "https://toon-stream.site/embed/wrapper") == "https://toon-stream.site/player/episode-1")
        #expect(ToonHubParser.wrappedPlayer(#"<iframe src="javascript:window.open('ad')"></iframe>"#, page: "https://toon-stream.site/embed/wrapper") == nil)
    }

    @Test func theRedirectorIsReadAndOtherwiseLeftAlone() throws {
        let html = """
        <p><strong>Episode 03: Still a Long Way to Go</strong></p>
        <p><strong><span>WatchOnline</span> – <a href="https://toonhub4u.co/redirect/main1.php?url=aHR0cHM6Ly90b29uc3RyZWFtLm5ldC9lcGlzb2RlL3NvbG8tbGV2ZWxpbmctMXgxLw==">Stream</a></strong></p>
        <p><strong>1080p – <a href="https://filesforever.link/file/qr8e0a0">Mirrors</a></strong></p>
        """
        let episode = try #require(ToonHubParser.episodes(html, base: "https://toonhub4u.co").first)
        #expect(episode.number == 3)
        #expect(episode.links.first == .init(url: "https://toonstream.net/episode/solo-leveling-1x3/", label: "Hindi Stream"))
        #expect(ToonHubParser.followRedirect("https://toonstream.net/episode/x-1x1/") == "https://toonstream.net/episode/x-1x1/")
        #expect(ToonHubParser.followRedirect("https://toonhub4u.co/redirect/main1.php?url=%%%") == "https://toonhub4u.co/redirect/main1.php?url=%%%")
        #expect(ToonHubParser.followRedirect("https://toonhub4u.co/redirect/main1.php?url=aGVsbG8") == "https://toonhub4u.co/redirect/main1.php?url=aGVsbG8")
    }
}
