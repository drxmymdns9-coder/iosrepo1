import Foundation
import Testing
@testable import AnililiCore

struct SubtitleTests {
    @Test func parsesVttWithShortStampsTagsAndRuby() {
        let vtt = """
        WEBVTT

        00:00:00.000 --> 00:00:05.000 line:0% align:end size:15%
        <ruby><rt>kaa.lt</rt></ruby>

        1
        00:20.240 --> 00:29.210
        <b>Beyond Journey&#39;s End</b>

        01:01:29.980 --> 01:01:31.000
        Two
        lines
        """
        let cues = Subtitles.parse(vtt)
        #expect(cues.map(\.text) == ["Beyond Journey's End", "Two\nlines"], "the watermark cue reads as empty and is dropped")
        #expect(cues[0].start == 20.24)
        #expect(cues[1].start == 3689.98)
        #expect(Subtitles.text(at: 25, in: cues) == "Beyond Journey's End")
        #expect(Subtitles.text(at: 25, in: cues, delay: 10) == nil)
        #expect(Subtitles.text(at: 100, in: cues) == nil)
    }

    @Test func parsesSrt() {
        let srt = "1\r\n00:00:01,500 --> 00:00:03,000\r\n<i>Hello</i>\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\nWorld\r\n"
        #expect(Subtitles.parse(srt).map(\.text) == ["Hello", "World"])
        #expect(Subtitles.parse(srt).first?.start == 1.5)
    }

    @Test func hlsVariantsBestFirst() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
        360/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720
        720/index.m3u8
        """
        #expect(HLSPlaylist.variants(master).map(\.label) == ["1080p", "720p", "360p"])
        #expect(HLSPlaylist.variants("#EXTM3U\n#EXTINF:10,\nseg1.ts").isEmpty)
    }

    @Test func miruroSoftSubServersCarryTheirSubtitles() throws {
        let config = Miruro.parseConfig(try JSON.parse(Fixture.data("miruro/config.json")))
        let play = try JSON.parse(Miruro.decodeCatalogBody(Fixture.data("miruro/play.bin")))
        let sub = Miruro.parseSources(config: config, play: play, audio: .sub).filter { $0.kind != .embed }
        let hard = sub.filter { !$0.softSub }
        let soft = sub.filter(\.softSub)
        #expect(hard.map(\.label) == ["sun · icarus-2-1", "sun · vault-6-direct-2", "kiwi · animepahe", "knob · Vidplay"])
        #expect(!soft.isEmpty)
        #expect(sub.firstIndex { $0.softSub }! > sub.lastIndex { !$0.softSub }!, "hard subs first")
        #expect(soft.allSatisfy { !$0.subtitles.isEmpty })
        #expect(soft.first?.subtitles.contains { $0.language == "en" } == true)
    }
}

struct SkipTimesTests {
    @Test func theMirrorIsReadAndTheClosestLengthWins() async {
        let mirror = #"{"v":1,"mal":52991,"episodes":{"1":[["op",3.2,93.2,1559.9,"a"],["op",5,95,1420,"b"],["ed",1417.1,1507.1,1510.1,"c"],["mixed-op",58.7,148.7,1470,"d"]]}}"#
        let service = SkipTimesService { url in
            url.path.hasSuffix("/skip/154/154587.json") ? Data(mirror.utf8) : nil
        }
        let found = await service.skipTimes(anilistID: 154587, malID: nil, episode: 1, length: 1425)
        #expect(found?.intro == .init(start: 5, end: 95))
        #expect(found?.outro == .init(start: 1417.1, end: 1507.1))
        #expect(await service.skipTimes(anilistID: 154587, malID: nil, episode: 2, length: 1425) == nil)
    }
}

struct PlaybackPolicyTests {
    @Test func anOutroOnlyCountsWhenItReachesTheLastQuarter() {
        let credits = SkipTimes.Window(start: 1290, end: 1380)
        // Bleach 274: AniSkip's "ed" at 4:46–6:16 of a 24:05 encode.
        let early = SkipTimes.Window(start: 286, end: 376)
        let inverted = SkipTimes.Window(start: 10, end: 5)
        #expect(PlaybackPolicy.outroIsCredits(credits, duration: 1440) == true)
        #expect(PlaybackPolicy.outroIsCredits(early, duration: 1445) == false)
        #expect(PlaybackPolicy.outroIsCredits(nil, duration: 1440) == false)
        #expect(PlaybackPolicy.outroIsCredits(inverted, duration: 1440) == false)
    }

    @Test func theNextEpisodeIsOfferedOnlyAtTheEnd() {
        let credits = SkipTimes.Window(start: 1320, end: 1410)
        #expect(PlaybackPolicy.nextTrigger(position: 1000, duration: 1440, outro: nil) == .none)
        #expect(PlaybackPolicy.nextTrigger(position: 1415, duration: 1440, outro: nil) == .ending)
        #expect(PlaybackPolicy.nextTrigger(position: 1405, duration: 1440, outro: credits) == .none, "credits still rolling")
        #expect(PlaybackPolicy.nextTrigger(position: 1412, duration: 1440, outro: credits) == .afterCredits)
        #expect(PlaybackPolicy.nextTrigger(position: 1436, duration: 1440, outro: SkipTimes.Window(start: 1350, end: 1440)) == .afterCredits, "final seconds")
    }
}
