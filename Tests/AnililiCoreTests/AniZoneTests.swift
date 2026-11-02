import Foundation
import Testing
@testable import AnililiCore

struct AniZoneTests {
    /// `anime?search=frieren` as served on 2026-10-12: results as JSON in an Alpine attribute,
    /// every quote written `"`.
    @Test func searchResultsComeOutOfTheAlpineData() throws {
        let candidates = AniZoneParser.search(try Fixture.text("anizone/search.html"))
        #expect(candidates.first == .init(slug: "mdkytdqp", title: "Sousou no Frieren"))
        #expect(candidates.contains(.init(slug: "mdkytdqp", title: "Frieren: Beyond Journey`s End")))
        #expect(candidates.contains { $0.title.contains("葬送のフリーレン") }, "non-ASCII survives the escapes")
    }

    @Test func javaScriptEscapesAreUndone() {
        #expect(AniZoneParser.unescapeJavaScript(#""a":"It\'s \\/x""#) == #""a":"It's \/x""#)
    }

    @Test func theEpisodePageNamesItsStreamAndTracks() {
        let html = #"<media-player src="https://cdn.anizone.to/x/master.m3u8?t=1&amp;e=2"></media-player><track kind="subtitles" src="/subs/en.vtt" label="English" srclang="en"><track kind="chapters" src="/c.vtt">"#
        #expect(AniZoneParser.hls(html) == "https://cdn.anizone.to/x/master.m3u8?t=1&e=2")
        #expect(AniZoneParser.subtitles(html).map(\.url.absoluteString) == ["https://anizone.to/subs/en.vtt"])
        #expect(AniZoneParser.episodeCount("<span>28 Episodes</span>") == 28)
    }
}

struct AniZoneEpisodePageTests {
    /// `anime/mdkytdqp/1` as served on 2026-10-12: master and ASS tracks only in the Livewire data.
    @Test func theStreamAndASSTracksComeOutOfTheLivewireData() throws {
        let html = try Fixture.text("anizone/episode.html")
        let hls = try #require(AniZoneParser.hls(html))
        #expect(hls.hasPrefix("https://") && hls.hasSuffix("/master.m3u8"))
        let tracks = AniZoneParser.subtitles(html)
        #expect(tracks.count > 5)
        #expect(tracks.allSatisfy { $0.url.absoluteString.hasSuffix(".ass") })
        #expect(tracks.contains { $0.language == "en" })
    }

    @Test func assDialogueBecomesCues() {
        let ass = #"""
        [Script Info]
        Title: x

        [V4+ Styles]
        Format: Name, Fontname
        Style: Default,Arial

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,{\i1}Hello,{\i0} there\Nfriend
        Dialogue: 0,0:00:04.00,0:00:05.00,Sign,,0,0,0,,{\p1}m 0 0 l 10 10{\p0}
        Dialogue: 0,0:01:00.00,0:01:02.25,Default,,0,0,0,,Second
        """#
        let cues = Subtitles.parse(ass)
        #expect(cues.map(\.text) == ["Hello, there\nfriend", "Second"])
        #expect(cues.first?.start == 1.5)
        #expect(cues.last?.end == 62.25)
    }
}
