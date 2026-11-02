import Foundation
import Testing
@testable import AnililiCore

/// Android's `RareAnimesParserTest`, on its markup.
struct RareAnimesTests {
    private typealias Hit = RareAnimesParser.Hit
    private typealias Link = RareAnimesParser.ServerLink

    @Test func theFeedReadsBothTitleShapes() throws {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <title>Search Results for &#8220;naruto&#8221;</title>
          <link>https://www.rareanimes.mov/</link>
          <item>
            <title><![CDATA[Naruto Shippuden Season 02 &#8211; Episodes Hindi Dubbed Download HD]]></title>
            <link>https://www.rareanimes.mov/hindi/naruto-shippuden-season-02-episodes-hindi-dubbed-download-hd/</link>
          </item>
          <item>
            <title>Naruto Shippuden Season 01 &#8211; Episodes Hindi Dubbed Download HD</title>
            <link>https://www.rareanimes.mov/hindi/naruto-shippuden-season-01-episodes-hindi-dubbed-download-hd/</link>
          </item>
        </channel></rss>
        """
        let results = try #require(RareAnimesParser.feed(feed))
        #expect(results.map(\.title) == ["Naruto Shippuden Season 02 – Episodes Hindi Dubbed Download HD", "Naruto Shippuden Season 01 – Episodes Hindi Dubbed Download HD"])
        #expect(results[0].url == "https://www.rareanimes.mov/hindi/naruto-shippuden-season-02-episodes-hindi-dubbed-download-hd/")
    }

    @Test func anEmptyFeedIsAMissButANonFeedIsTheEnd() {
        let empty = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Search Results</title>
        <link>https://www.rareanimes.mov/</link></channel></rss>
        """
        #expect(RareAnimesParser.feed(empty) == [])
        #expect(RareAnimesParser.feed("<!doctype html><html><body>search page</body></html>") == nil)
        #expect(RareAnimesParser.feed("") == nil)
    }

    @Test func paragraphEpisodesSplitByLanguage() throws {
        let html = """
        <hr>
        <p>Episode 01 – The New Target</p>
        <p><span style="color: #99cc00;">Hindi Uncut </span>– [<a href="https://codedew.com/zipper/?url=HINDI_MQ" target="_blank">WatchMultiQuality</a>] [<a href="https://codedew.com/zipper/?url=HINDI_SB" target="_blank">StreamBeta</a>] [<a href="https://codedew.com/zipper/?url=HINDI_DL" target="_blank">DLBeta</a>]</p>
        <p><span style="color: #ff00ff;">Tamil </span>– [<a href="https://codedew.com/zipper/?url=TAMIL_SB" target="_blank">StreamBeta</a>]</p>
        <p><span style="color: #00ccff;">Telugu </span>– [<a href="https://codedew.com/zipper/?url=TELUGU_SB" target="_blank">StreamBeta</a>]</p>
        <hr>
        <p>Episode 02 – Formation! New Team Kakashi!</p>
        <p><span style="color: #99cc00;">Hindi Uncut </span>– [<a href="https://codedew.com/zipper/?url=EP2_MQ" target="_blank">WatchMultiQuality</a>]</p>
        <hr>
        """
        let episodes = RareAnimesParser.episodes(html)
        #expect(episodes.map(\.number) == [1, 2])
        #expect(Set(episodes[0].languages.keys) == ["hindi", "tamil", "telugu"])
        #expect(episodes[0].languages["hindi"]?.count == 3)
        #expect(RareAnimesParser.preferred(try #require(episodes[0].languages["hindi"]))?.url == "https://codedew.com/zipper/?url=HINDI_MQ")
        #expect(RareAnimesParser.preferred(try #require(episodes[0].languages["tamil"]))?.url == "https://codedew.com/zipper/?url=TAMIL_SB")
        #expect(Set(episodes[1].languages.keys) == ["hindi"])
    }

    @Test func spanEpisodesAndEmptyAndRepeatedHeadings() throws {
        let spans = """
        <span class="ra-ep-title"><strong>Episode 01 – The Beginning</strong></span>
        <span class="ra-l-hindi">Hindi</span>
        [<a href="https://codedew.com/zipper/?url=SPAN_MQ">WatchMultQuality</a>]
        [<a href="https://codedew.com/zipper/?url=SPAN_SB">StreamBeta</a>]
        """
        let episodes = RareAnimesParser.episodes(spans)
        #expect(episodes.count == 1)
        #expect(RareAnimesParser.preferred(episodes.first?.languages["hindi"] ?? [])?.url == "https://codedew.com/zipper/?url=SPAN_MQ")

        let empty = """
        <p>Episode 01 – Real</p>
        <p><span>Hindi </span>– [<a href="https://codedew.com/zipper/?url=OK">WatchMultiQuality</a>]</p>
        <p>Episode 02 – Empty</p>
        <p>No links here yet.</p>
        """
        #expect(RareAnimesParser.episodes(empty).map(\.number) == [1])

        let repeated = """
        <p>Episode 01 – Real</p>
        <p><span>Hindi </span>– [<a href="https://codedew.com/zipper/?url=A">WatchMultiQuality</a>]</p>
        <p>Episode 01 – Repeated in a footer index</p>
        <p><span>Hindi </span>– [<a href="https://codedew.com/zipper/?url=B">WatchMultiQuality</a>]</p>
        """
        #expect(RareAnimesParser.episodes(repeated).map(\.number) == [1])
    }

    @Test func singleLanguagePostsLabelRowsByDubSource() {
        let html = """
        <p>Episode 01 – Ryomen Sukuna</p>
        <p><span style="color: #ff0000;">New Sony Dub – </span>[<a href="https://codedew.com/zipper/?url=EP1_MQ" target="_blank">WatchMultQuality</a>] [<a href="https://codedew.com/zipper/?url=EP1_MF">MediaFire</a>]</p>
        <p><span style="color: #99cc00;">Crunchyroll</span> – [<a href="https://codedew.com/zipper/?url=EP1_CR">WatchMultQuality</a>]</p>
        <hr>
        <p>Episode 02 – For Myself</p>
        <p><span>New Sony Dub – </span>[<a href="https://codedew.com/zipper/?url=EP2_MQ">WatchMultQuality</a>]</p>
        """
        let episodes = RareAnimesParser.episodes(html)
        #expect(episodes.map(\.number) == [1, 2])
        #expect(Set(episodes[0].languages.keys) == ["hindi"])
        #expect(episodes[0].languages["hindi"]?.count == 3)
        #expect(RareAnimesParser.preferred(episodes[0].languages["hindi"] ?? [])?.url == "https://codedew.com/zipper/?url=EP1_MQ")
    }

    @Test func preferredTakesBothMultiQualitySpellings() {
        let multi = Link(url: "u1", anchor: "WatchMultiQuality")
        let mult = Link(url: "u2", anchor: "WatchMultQuality")
        let beta = Link(url: "u3", anchor: "StreamBeta")
        #expect(RareAnimesParser.preferred([beta, multi])?.url == "u1")
        #expect(RareAnimesParser.preferred([beta, mult])?.url == "u2")
        #expect(RareAnimesParser.preferred([Link(url: "u4", anchor: "Watch Online"), mult])?.url == "u2")
        #expect(RareAnimesParser.preferred([]) == nil)
    }

    @Test func seriesTitleDropsTheStockSuffix() {
        #expect(RareAnimesParser.seriesTitle("Demon Slayer Season 1 – Episodes Hindi Dubbed Download HD Jio Cinema") == "Demon Slayer")
        #expect(RareAnimesParser.seriesTitle("Naruto Shippuden Season 02 – Episodes Hindi Dubbed Download HD") == "Naruto Shippuden")
        #expect(RareAnimesParser.seriesTitle("Death Note") == "Death Note")
    }

    private let slime = [
        Hit(url: "season-4", title: "That Time I Got Reincarnated as a Slime Season 4 Hindi Dubbed Episodes Download HD"),
        Hit(url: "movie", title: "That Time I Got Reincarnated as a Slime the Movie: Scarlet Bond Movie Hindi Dubbed Download HD"),
        Hit(url: "season-3", title: "That Time I Got Reincarnated as a Slime Season 3 Hindi Dubbed Episodes Download HD"),
        Hit(url: "season-2", title: "That Time I Got Reincarnated as a Slime Season 2 Hindi Dubbed Episodes Download HD"),
        Hit(url: "season-1", title: "That Time I Got Reincarnated as a Slime Season 1 Hindi Dubbed Episodes Download HD"),
    ]

    @Test func rankingPicksTheSeasonAskedFor() {
        #expect(RareAnimesParser.rank(titles: ["That Time I Got Reincarnated as a Slime"], slime, episodic: true).first?.url == "season-1")
        #expect(RareAnimesParser.rank(titles: ["That Time I Got Reincarnated as a Slime 2nd Season"], slime, episodic: true).first?.url == "season-2")
        let titan = [
            Hit(url: "s1", title: "Attack on Titan Season 1 Hindi Dubbed Episodes Download HD"),
            Hit(url: "oad", title: "Attack on Titan OAD Hindi Dubbed Episodes Download HD"),
            Hit(url: "s4", title: "Attack on Titan Season 4 Hindi Dubbed Episodes Download HD"),
            Hit(url: "s3", title: "Attack on Titan Season 3 Hindi Dubbed Episodes Download HD"),
        ]
        #expect(RareAnimesParser.rank(titles: ["Attack on Titan Final Season", "Shingeki no Kyojin: The Final Season"], titan, episodic: true).first?.url == "s4")
        let slayer = [
            Hit(url: "season-1", title: "Demon Slayer Season 1 Hindi Dubbed Episodes Download HD"),
            Hit(url: "season-4", title: "Demon Slayer Season 4 (Hashira Training Arc) Hindi Dubbed Episodes Download HD"),
        ]
        #expect(RareAnimesParser.rank(titles: ["Demon Slayer: Kimetsu no Yaiba - Hashira Training Arc"], slayer, episodic: true).first?.url == "season-4")
        let ranma = [
            Hit(url: "season-2", title: "Ranma1/2 Season 2 Hindi Dubbed Episodes Download HD"),
            Hit(url: "season-1", title: "Ranma1/2 Season 1 Hindi Dubbed Episodes Download HD"),
        ]
        #expect(RareAnimesParser.rank(titles: ["Ranma ½"], ranma, episodic: true).first?.url == "season-1")
    }

    @Test func aPostThatOnlySharesAWordIsNotThisTitle() {
        let wedding = [Hit(url: "wedding", title: "365 Days to the Wedding Season 1 Hindi Dubbed Episodes Download HD")]
        #expect(RareAnimesParser.rank(titles: ["Sakamoto Days"], wedding, episodic: true, minScore: 0.5).isEmpty)
    }

    private func moviePage(_ body: String, after: String = "") -> String {
        """
        <header class="entry-header"><h1 class="entry-title h1">Movie Hindi Dubbed Download HD</h1></header>
        <div class="entry-content herald-entry-content">
        \(body)
        </div>
        \(after)
        """
    }

    @Test func aMoviePostIsOneEpisode() throws {
        let html = moviePage("""
        <p>Download Grave of the Fireflies Hindi Full Movie.</p>
        <hr>
        <h4 style="text-align: center;"><span style="color: #00ff00;">Hindi (FanDub)</span></h4>
        <h4 style="text-align: center;"><span style="color: #ff00ff;">Hindi – Download</span></h4>
        <h3 style="text-align: center;"><a href="https://codedew.com/zipper/?url=MOVIE_MQ" target="_blank" rel="noopener noreferrer">WatchMultiQuality</a></h3>
        <h3 style="text-align: center;"><a href="https://codedew.com/zipper/?url=MOVIE_MEGA" target="_blank" rel="noopener noreferrer">Mega</a></h3>
        """)
        #expect(RareAnimesParser.episodes(html).isEmpty)
        let movie = try #require(RareAnimesParser.movie(html))
        #expect(movie.number == 1)
        #expect(Set(movie.languages.keys) == ["hindi"])
        #expect(RareAnimesParser.preferred(movie.languages["hindi"] ?? [])?.url == "https://codedew.com/zipper/?url=MOVIE_MQ")
    }

    @Test func aMovieKeepsOnlyRealServersInItsBody() throws {
        let prose = moviePage("""
        <p>This movie is now available in Hindi (Unofficial Dubbed).</p>
        <h5>Movie Info</h5>
        <p>Full Name: Grave of the Fireflies
          (<a title="Japanese language" href="https://codedew.com/zipper/?url=JUNK_JA">Japanese</a>:
          <a title="Hepburn romanization" href="https://codedew.com/zipper/?url=JUNK_HEP">Hepburn</a>)</p>
        <h4>Hindi – Download</h4>
        <h3><a href="https://codedew.com/zipper/?url=REAL_MQ">WatchMultiQuality</a></h3>
        """)
        #expect(RareAnimesParser.movie(prose)?.languages["hindi"]?.map(\.url) == ["https://codedew.com/zipper/?url=REAL_MQ"])

        let languages = moviePage("""
        <p>Available in Hindi, Tamil and Telugu.</p>
        <h4>Hindi – Download</h4>
        <h3><a href="https://codedew.com/zipper/?url=HI_MQ">WatchMultiQuality</a></h3>
        <h3><a href="https://codedew.com/zipper/?url=HI_SB">StreamBeta</a></h3>
        <h4>Tamil – Download</h4>
        <h3><a href="https://codedew.com/zipper/?url=TA_MQ">WatchMultiQuality</a></h3>
        <h4>Telugu – Download</h4>
        <h3><a href="https://codedew.com/zipper/?url=TE_MQ">WatchMultiQuality</a></h3>
        """)
        let movie = try #require(RareAnimesParser.movie(languages))
        #expect(Set(movie.languages.keys) == ["hindi", "tamil", "telugu"])
        #expect(movie.languages["hindi"]?.map(\.url) == ["https://codedew.com/zipper/?url=HI_MQ"])

        let related = moviePage("""
        <h4>Hindi – Download</h4>
        <h3><a href="https://codedew.com/zipper/?url=MINE">WatchMultiQuality</a></h3>
        """, after: """
        <div class="herald-related">
          <h4>Hindi</h4>
          <a href="https://codedew.com/zipper/?url=SOMEONE_ELSE">WatchMultiQuality</a>
        </div>
        """)
        #expect(RareAnimesParser.movie(related)?.languages["hindi"]?.map(\.url) == ["https://codedew.com/zipper/?url=MINE"])
        #expect(RareAnimesParser.movie(moviePage("<p>Hindi dub coming soon.</p>")) == nil)
    }

    @Test func findsTheArgonEmbed() {
        let html = #"<iframe src="https://argon.razorshell.space/embed/5GQAmPt6K445Vk7" referrerpolicy="origin" allowfullscreen></iframe>"#
        #expect(RareAnimesParser.embedURL(html) == "https://argon.razorshell.space/embed/5GQAmPt6K445Vk7")
        #expect(RareAnimesParser.embedURL("<p>nothing</p>") == nil)
    }
}
