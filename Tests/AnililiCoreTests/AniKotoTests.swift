import Foundation
import Testing
@testable import AnililiCore

/// Android's `MegaPlayEncTest`, `MegaPlayManifestTest`, `MegaPlayRouteDiscoveryTest` and
/// `MegaPlaySubtitleHostTest`, on their fixtures.
struct AniKotoTests {
    /// The live answer for Frieren ep 1 sub (MegaPlay file 13461), 2026-09-17.
    static let liveBlob = "wdeBruh3qqn_i5wUNnyaPcXqidp1UWP84FfPHzGyKXAz4mAVkH6j3DueswO2yXLWn8H-XMHNvbAo5Gsg7zIcFBuQ"
        + "I_zsUvMGI1gKwQsPTSHQHiF55R4BopgEQ-7jebQQ4C0Gu7YhaMucopp6d3Q8yAY9b5GdsSvPGq6CUn7SHyc"

    @Test func theLiveBlobDecryptsToItsManifest() {
        #expect(MegaPlayParser.decrypt(Self.liveBlob)
                == #"{"file":"https://fetch.nexabloom.top/anime/bb6d2babd7797d94d8f4a8600bc9b44e/b7d51fb7e838ee9b60dcdb34b953bc07/master.m3u8"}"#)
        let answer = JSON.object(["enc": .string(Self.liveBlob), "tracks": .array([])])
        #expect(MegaPlayParser.sourceFile(answer)?.hasSuffix("/master.m3u8") == true)
    }

    @Test func aBlobThisKeyCannotOpenIsRefused() {
        #expect(MegaPlayParser.decrypt("not-base64url-at-all!!") == nil)
        #expect(MegaPlayParser.decrypt("") == nil)
        #expect(MegaPlayParser.decrypt(String(Self.liveBlob.dropLast(22)) + "AAAAAAAAAAAAAAAAAAAAAA") == nil)
    }

    @Test func sourcesInTheClearNeedNoKey() throws {
        let object = try JSON.parse(Data(#"{"sources":{"file":"https://a/master.m3u8"}}"#.utf8))
        let array = try JSON.parse(Data(#"{"sources":[{"file":"https://b/master.m3u8"}]}"#.utf8))
        #expect(MegaPlayParser.sourceFile(object) == "https://a/master.m3u8")
        #expect(MegaPlayParser.sourceFile(array) == "https://b/master.m3u8")
    }

    @Test func theMasterHasItsRenditionSibling() {
        #expect(MegaPlayParser.renditionURL("https://fetch.nexabloom.top/anime/bb6d/b7d5/master.m3u8")
                == "https://fetch.nexabloom.top/anime/bb6d/b7d5/index-f1-v1-a1.m3u8")
        #expect(MegaPlayParser.renditionURL("https://x/a/master.m3u8?t=1") == "https://x/a/index-f1-v1-a1.m3u8?t=1")
        #expect(MegaPlayParser.renditionURL("https://x/a/index.m3u8") == nil)
        #expect(MegaPlayParser.manifestCanPlay("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nindex.m3u8"))
        #expect(MegaPlayParser.manifestCanPlay("#EXTM3U\n#EXTINF:4,\nseg.ts"))
        #expect(!MegaPlayParser.manifestCanPlay("#EXTM3U\n"))
        #expect(!MegaPlayParser.manifestCanPlay("<html>403</html>"))
    }

    @Test func routesAreReadFromTheClientScriptNewestFirst() {
        let script = #"var E="stream/getSources",C="stream/getSourcesNew";fetch("stream/getSources?id="+n)"#
        #expect(MegaPlayParser.sourceRoutes(script) == ["stream/getSourcesNew", "stream/getSources"])
        let page = #"<script src="https://cdn.jsdelivr.net/hls.js"></script><script src="/js/player.js"></script><script src="/js/newclient.min.js?v=2"></script>"#
        #expect(MegaPlayParser.clientScripts(page, embed: "https://megaplay.buzz/stream/s-2/1/sub")
                == ["https://megaplay.buzz/js/newclient.min.js?v=2", "https://megaplay.buzz/js/player.js"])
    }

    @Test func subtitlesMoveOntoTheStreamsHost() {
        let path = "/anime/bb6d2babd7797d94d8f4a8600bc9b44e/b7d51fb7e838ee9b60dcdb34b953bc07/"
        #expect(MegaPlayParser.onStreamHost("https://slow.online\(path)subs/eng.vtt", "https://fast.top\(path)master.m3u8")
                == "https://fast.top\(path)subs/eng.vtt")
        #expect(MegaPlayParser.onStreamHost("https://subs.example/eng.vtt", "https://fast.top\(path)master.m3u8") == "https://subs.example/eng.vtt")
    }

    @Test func pagesSayWhetherTheEpisodeIsThere() {
        #expect(MegaPlayParser.pageAvailable(#"<div id="megaplay-player" data-id="13461"></div>"#))
        #expect(!MegaPlayParser.pageAvailable("<title>Error 404</title>"))
        #expect(MegaPlayParser.dataAttribute(#"<div data-id="13461" data-ep-id="7">"#, "id") == "13461")
    }
}
