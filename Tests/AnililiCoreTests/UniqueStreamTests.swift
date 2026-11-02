import Foundation
import Testing
@testable import AnililiCore

/// Android's `UniqueStreamParserTest` and `UniqueStreamKeyDataSourceTest`, on their fixtures.
struct UniqueStreamTests {
    private func json(_ text: String) throws -> JSON { try JSON.parse(Data(text.utf8)) }

    @Test func searchKeepsSeriesOnly() throws {
        let found = UniqueStreamParser.search(try json("""
        {"series":[{"content_id":"I35iIyC2","title":"Solo Leveling","type":"show","subbed":true,"dubbed":true},
                   {"content_id":"Ab3kL9xQ","title":"Solo Leveling Specials","type":"show"}],
         "movies":[{"content_id":"Mv1Mv1Mv","title":"Solo Leveling: ReAwakening","type":"movie"}]}
        """))
        #expect(found.map(\.contentID) == ["I35iIyC2", "Ab3kL9xQ"])
    }

    @Test func theMALIDPicksTheSeasonBeforeTitles() throws {
        let seasons = UniqueStreamParser.seasons(try json("""
        {"seasons":[{"content_id":"0DsN4Kb7","title":"Solo Leveling","season_number":1,"episode_count":13,"mal_id":"52299"},
                    {"content_id":"Xk2Pq9Lm","title":"Solo Leveling Season 2 -Arise from the Shadow-","episode_count":13,"mal_id":"58567"},
                    {"content_id":"NoMal001","title":"Solo Leveling OVAs","episode_count":2,"mal_id":null}]}
        """))
        #expect(seasons.count == 3)
        #expect(UniqueStreamParser.select(seasons, malID: "58567", titles: ["Solo Leveling"]).map(\.contentID) == ["Xk2Pq9Lm"])
        #expect(UniqueStreamParser.select(seasons, malID: "52299", titles: ["Solo Leveling"]).map(\.contentID) == ["0DsN4Kb7"])
        let opm = [UniqueStreamParser.Season(contentID: "a", title: "One Punch Man", episodeCount: 12, malID: nil),
                   UniqueStreamParser.Season(contentID: "b", title: "One Punch Man Season 2", episodeCount: 12, malID: nil)]
        #expect(UniqueStreamParser.select(opm, malID: nil, titles: ["One Punch Man Season 2"]).map(\.contentID) == ["b"])
        #expect(UniqueStreamParser.select(opm, malID: nil, titles: ["One Punch Man"]).map(\.contentID) == ["a"])
    }

    @Test func sagasAreOneCatalogue() {
        let sagas = [("dHTiu8rG", "East Blue (1-61)", 61), ("HxyVVAYQ", "Alabasta (62-135)", 74),
                     ("ryPJvHBp", "Skypiea (136-206)", 71), ("vISRWU6Y", "Summit War (385-516)", 132)]
            .map { UniqueStreamParser.Season(contentID: $0.0, title: $0.1, episodeCount: $0.2, malID: nil) }
        #expect(UniqueStreamParser.select(sagas, malID: "21", titles: ["One Piece"]).count == 4)
        #expect(UniqueStreamParser.seasonForEpisode(sagas, 61)?.contentID == "dHTiu8rG")
        #expect(UniqueStreamParser.seasonForEpisode(sagas, 62)?.contentID == "HxyVVAYQ")
        #expect(UniqueStreamParser.seasonForEpisode(sagas, 206)?.contentID == "ryPJvHBp")
        #expect(UniqueStreamParser.seasonForEpisode(sagas, 400) == nil)
        var gapped = sagas
        gapped[1].episodeCount = nil
        #expect(UniqueStreamParser.seasonForEpisode(gapped, 150) == nil)
    }

    @Test func recapsAndClipsAreDropped() throws {
        let episodes = UniqueStreamParser.episodes(try json("""
        [{"is_clip":false,"content_id":"sczeR0vi","episode_number":1.0,"audio_locales":["ja-JP","en-US","ar-SA"]},
         {"is_clip":false,"content_id":"ep2abcd1","episode_number":2.0,"audio_locales":["ja-JP","ar-SA"]},
         {"is_clip":false,"content_id":"ep75recp","episode_number":7.5,"audio_locales":["ja-JP","en-US"]},
         {"is_clip":true,"content_id":"clip0001","episode_number":3.0,"audio_locales":["ja-JP","en-US"]}]
        """))
        #expect(episodes.map(\.number) == [1, 2])
        #expect(episodes.filter { $0.audioLocales.contains("en-US") }.map(\.number) == [1])
    }

    @Test func aSubWithoutSoftSubtitlesTakesTheBurntInEncode() throws {
        let bare = try #require(UniqueStreamParser.media(try json("""
        {"media_id":"m1","hls":{"locale":"ja-JP","playlist":"https://cdn/x/master.m3u8","subtitles":[],
          "hard_subs":[{"locale":"ar-SA","playlist":"https://cdn/x/hard/ar-SA/master.m3u8"},{"locale":"en-US","playlist":"https://cdn/x/hard/en-US/master.m3u8"}]}}
        """)))
        #expect(UniqueStreamParser.playback(bare, .sub) == .init(url: "https://cdn/x/hard/en-US/master.m3u8", subtitles: [], burntIn: true))
        #expect(UniqueStreamParser.playback(bare, .dub)?.url == "https://cdn/x/master.m3u8")
        #expect(UniqueStreamParser.media(try json(#"{"hls_not_ready":true}"#)) == nil)
    }

    @Test func theKeyIsTheMediaIDInHex() {
        #expect(UniqueStreamParser.key("00112233445566778899aabbccddeeff") == Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]))
        #expect(UniqueStreamParser.key("short") == nil)
        #expect(UniqueStreamParser.key("zz112233445566778899aabbccddeeff") == nil)
    }
}
