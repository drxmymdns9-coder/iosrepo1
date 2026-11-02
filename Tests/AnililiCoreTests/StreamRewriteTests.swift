import Foundation
import Testing
@testable import AnililiCore

struct StreamRewriteTests {
    let base = URL(string: "https://cdn.example/show/ep1/master.m3u8?t=1")!

    private func proxied(_ url: URL, _ role: StreamRewrite.Role) -> String {
        "http://127.0.0.1:9/\(role.rawValue)?\(url.absoluteString)"
    }

    @Test func everyURLInAMasterComesBackThroughTheProxy() {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English",URI="audio/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
        https://other.example/720/index.m3u8
        """
        let out = StreamRewrite.playlist(master, base: base) { proxied($0, $1) }.components(separatedBy: "\n")
        #expect(out[1] == #"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English",URI="http://127.0.0.1:9/playlist?https://cdn.example/show/ep1/audio/en.m3u8""#)
        #expect(out[2] == "#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360")
        #expect(out[3] == "http://127.0.0.1:9/playlist?https://cdn.example/show/ep1/360/index.m3u8")
        #expect(out[5] == "http://127.0.0.1:9/playlist?https://other.example/720/index.m3u8")
    }

    @Test func mediaPlaylistsKeepTheirTagsAndRouteKeysMapsAndSegments() {
        let media = "#EXTM3U\r\n#EXT-X-TARGETDURATION:6\r\n#EXT-X-KEY:METHOD=AES-128,URI=\"/key.bin\",IV=0x01\r\n#EXT-X-MAP:URI=\"init.mp4\"\r\n#EXTINF:6.0,\r\nseg-1.jpg\r\n#EXTINF:6.0,\r\nseg-2.png?x=1\r\n#EXT-X-ENDLIST\r\n"
        let out = StreamRewrite.playlist(media, base: base) { proxied($0, $1) }
        #expect(out.contains("\r\n"), "line endings kept")
        let lines = out.components(separatedBy: "\r\n")
        #expect(lines[2] == #"#EXT-X-KEY:METHOD=AES-128,URI="http://127.0.0.1:9/key?https://cdn.example/key.bin",IV=0x01"#)
        #expect(lines[3] == #"#EXT-X-MAP:URI="http://127.0.0.1:9/map?https://cdn.example/show/ep1/init.mp4""#)
        #expect(lines[5] == "http://127.0.0.1:9/segment?https://cdn.example/show/ep1/seg-1.jpg")
        #expect(lines[7] == "http://127.0.0.1:9/segment?https://cdn.example/show/ep1/seg-2.png?x=1")
        #expect(lines[8] == "#EXT-X-ENDLIST")
        let fairPlay = "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://abc\"\nseg.ts"
        #expect(StreamRewrite.playlist(fairPlay, base: base) { proxied($0, $1) }.contains("skd://abc"))
    }

    @Test func playlistsAreRecognisedByTheirFirstLine() {
        #expect(StreamRewrite.looksLikePlaylist(Data("#EXTM3U\n#EXT-X-VERSION:3".utf8)))
        #expect(StreamRewrite.looksLikePlaylist(Data([0xEF, 0xBB, 0xBF] + Array("\n#EXTM3U".utf8))))
        #expect(!StreamRewrite.looksLikePlaylist(Data([0x47, 0x40, 0x00, 0x10])))
    }

    @Test func kwikIVsComeFromTheSegmentNames() throws {
        let kwik = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-KEY:METHOD=AES-128,URI="https://vault-08.uwucdn.top/mon.key"
        #EXTINF:10,
        https://vault-08.uwucdn.top/stream/x/segment-1-v1-a1.jpg
        #EXTINF:10,
        https://vault-08.uwucdn.top/stream/x/segment-5-v1-a1.jpg
        #EXT-X-ENDLIST
        """
        let out = try #require(StreamRewrite.explicitKwikIVs(kwik)).components(separatedBy: "\n")
        #expect(out[4] == #"#EXT-X-KEY:METHOD=AES-128,URI="https://vault-08.uwucdn.top/mon.key",IV=0x00000000000000000000000000000001"#)
        #expect(out[5].hasSuffix("segment-1-v1-a1.jpg"))
        #expect(out[7] == #"#EXT-X-KEY:METHOD=AES-128,URI="https://vault-08.uwucdn.top/mon.key",IV=0x00000000000000000000000000000005"#)
        #expect(StreamRewrite.explicitKwikIVs(kwik.replacingOccurrences(of: "mon.key\"", with: "mon.key\",IV=0x09")) == nil, "a stated IV is left alone")
        #expect(StreamRewrite.explicitKwikIVs("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\nseg1.ts") == nil, "not Kwik's names")
        #expect(StreamRewrite.hlsIV(255) == "0x000000000000000000000000000000ff")
    }

    /// A PNG's signature and chunks, then TS packets: the shape Miruro's `bee · HD-1` serves.
    private func wrapped(_ payload: [UInt8]) -> [UInt8] {
        func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
            let length = UInt32(data.count)
            return [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
                + Array(type.utf8) + data + [0, 0, 0, 0]
        }
        return StreamRewrite.pngSignature + chunk("IHDR", Array(repeating: 1, count: 13)) + chunk("IDAT", Array(repeating: 7, count: 200))
            + chunk("IEND", []) + payload
    }

    private var ts: [UInt8] { (0..<4).flatMap { _ in [0x47] + Array(repeating: UInt8(0x11), count: 187) } }

    @Test func aPNGWrapperIsWalkedToItsEnd() {
        let segment = wrapped(ts)
        let offset = StreamRewrite.payloadOffset(segment, complete: false)
        #expect(offset == 8 + 25 + 212 + 12)
        #expect(segment[offset ?? 0] == 0x47)
        #expect(StreamRewrite.payloadOffset(wrapped([0xDD, 0x3C, 0x9A, 0xAF] + Array(repeating: 3, count: 600)), complete: false) == 257,
                "an encrypted payload behind the PNG is found by the chunks, not a sync byte")
        #expect(StreamRewrite.payloadOffset(Array(segment.prefix(40)), complete: false) == nil, "waits for the IEND")
    }

    @Test func plainSegmentsAreLeftAlone() {
        #expect(StreamRewrite.payloadOffset(ts, complete: false) == 0)
        #expect(StreamRewrite.payloadOffset([0xDD, 0x3C, 0x9A, 0xAF] + Array(repeating: 9, count: 2000), complete: false) == 0, "ciphertext")
        #expect(StreamRewrite.payloadOffset([0x47, 0x40], complete: true) == 0)
        #expect(StreamRewrite.payloadOffset([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0, count: 100) + ts, complete: false) == 104)
    }
}
