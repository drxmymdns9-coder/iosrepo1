import Foundation
import Testing
@testable import AnililiCore

/// Android's `AnimeKaiProviderTest`, on its fixtures, including the bounded search.
struct AnimeKaiTests {
    @Test func searchCardsAndMALIdentityParse() throws {
        let html = """
        <div class="aitem">
          <a class="poster" href="/watch/jujutsu-kaisen-2nd-season/ep-1"></a>
          <a class="title d-title" data-en="Jujutsu Kaisen 2nd Season">JJK 2</a>
        </div>
        <a href="https://myanimelist.net/anime/51009">MAL</a>
        """
        let card = try #require(AnimeKaiParser.cards(html).first)
        #expect(card.slug == "jujutsu-kaisen-2nd-season")
        #expect(card.title == "Jujutsu Kaisen 2nd Season")
        #expect(AnimeKaiParser.malID(html) == 51009)
    }

    @Test func serversByAudioAndTheirPlayerAssets() throws {
        let subtitle = "https%3A%2F%2Fcdn.test%2Fenglish.vtt"
        let html = """
        <div class="server-items lang-group" data-id="hsub">
          <span class="server-video" data-video="https://vivibebe.site/e/abc?sub=\(subtitle)&amp;sub_1=English">Vid</span>
        </div>
        <div class="server-items lang-group" data-id="dub">
          <span class="server-video" data-video="https://vivibebe.site/e/xyz">Vid</span>
        </div>
        """
        let servers = AnimeKaiParser.servers(html)
        #expect(servers.map(\.language) == ["hsub", "dub"])
        let track = try #require(AnimeKaiParser.embedSubtitles(servers[0].video).first)
        #expect(track.url.absoluteString == "https://cdn.test/english.vtt")
        #expect(track.language == "en")
        #expect(AnimeKaiParser.findHLS(#"const src = "https:\/\/cdn.test\/master.m3u8?token=abc";"#) == "https://cdn.test/master.m3u8?token=abc")
        #expect(AnimeKaiParser.rank("https://vivibebe.site/e/1") > AnimeKaiParser.rank("https://megaup.cc/e/1"))
    }

    @Test func aConfidentFirstTitleAnswersWithoutSearchingTheRest() async throws {
        let asked = RequestLog()
        let provider = AnimeKai(mirrors: (0..<5).map { "https://m\($0).test" }) { url, _ in
            asked.append(url.host! + url.path)
            if url.path == "/browser" {
                return (200, #"<div class="aitem"><a class="poster" href="/watch/frieren"></a><a class="title d-title" data-en="Frieren">Frieren</a></div>"#)
            }
            return (200, #"<a data-num="1" data-sub="1"></a><a data-num="2" data-sub="1" data-dub="1"></a>"#)
        }
        let media = Media(id: 154587, title: .init(romaji: "Sousou no Frieren", english: "Frieren", native: "葬送のフリーレン"))
        let listing = try await provider.episodes(for: media)
        #expect(listing.subbed == [1, 2])
        #expect(listing.dubbed == [2])
        #expect(asked.entries == ["m0.test/browser", "m0.test/watch/frieren"])
    }

    @Test func aSearchThatFindsNothingMovesTheNextOneOn() async throws {
        let asked = RequestLog()
        let provider = AnimeKai(mirrors: (0..<5).map { "https://m\($0).test" }) { url, _ in
            asked.append(url.host!)
            return (200, "<html></html>")
        }
        let media = Media(id: 1, title: .init(english: "Nothing"))
        for _ in 0..<2 { _ = try await provider.episodes(for: media) }
        var seen = Set<String>()
        #expect(asked.entries.filter { seen.insert($0).inserted } == ["m0.test", "m1.test", "m2.test", "m3.test"])
    }
}
