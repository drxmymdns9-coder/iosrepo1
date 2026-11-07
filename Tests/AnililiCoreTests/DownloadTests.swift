import Foundation
import Testing
@testable import AnililiCore

struct DownloadTests {
    let base = URL(string: "https://cdn.example/hls/master.m3u8")!

    @Test func thePickedServerIsTriedFirstAndTheRestStayBehindIt() {
        func source(_ provider: String, _ server: String, kind: VideoSource.Kind = .hls, softSub: Bool = false) -> VideoSource {
            VideoSource(url: URL(string: "https://\(provider).example/\(server.count)")!, provider: provider, server: server, kind: kind, softSub: softSub)
        }
        let heaven = source("AnimeHeaven", "Mirror 2 (rt)")
        let koto = source("AniKoto", "MegaPlay")
        let soft = source("Miruro", "kiwi", softSub: true)
        let embed = source("AniKoto", "Vidstream", kind: .embed)
        let found = [heaven, soft, koto, embed]

        #expect(DownloadQueue.attempts(found, preferring: nil) == [heaven, koto])
        #expect(DownloadQueue.attempts(found, preferring: koto.label) == [koto, heaven])
        // A pick the fresh lookup no longer has, or one that can't be saved, changes nothing.
        #expect(DownloadQueue.attempts(found, preferring: "Zoko · 1080p") == [heaven, koto])
        #expect(DownloadQueue.attempts(found, preferring: soft.label) == [heaven, koto])
    }

    @Test func theBatchLabelSaysSubDownloadsAreHardSub() {
        #expect(DownloadQueue.batchLabel(count: 12, audio: .sub) == "Download 12 episodes (hard sub)")
        #expect(DownloadQueue.batchLabel(count: 1, audio: .dub) == "Download 1 episode (Dub)")
    }

    @Test func automaticDownloadsPreferArabicSoftSubtitles() {
        let hard = VideoSource(url: URL(string: "https://hard.example/ep.m3u8")!, provider: "Hard", server: "1080p", kind: .hls)
        let english = VideoSource(url: URL(string: "https://english.example/ep.m3u8")!, provider: "Soft", server: "English", kind: .hls,
                                  subtitles: [SubtitleTrack(url: URL(string: "https://english.example/en.vtt")!, label: "English", language: "en")], softSub: true)
        let arabic = VideoSource(url: URL(string: "https://arabic.example/ep.m3u8")!, provider: "Soft", server: "Arabic", kind: .hls,
                                 subtitles: [SubtitleTrack(url: URL(string: "https://arabic.example/ar.vtt")!, label: "Arabic", language: "ar")], softSub: true)
        #expect(DownloadQueue.attempts([hard, english, arabic], preferring: nil) == [arabic, english, hard])
        #expect(DownloadQueue.attempts([hard, english, arabic], preferring: hard.label).first == hard)
    }

    @Test func recordsSavedBeforeAPickedServerStillLoad() throws {
        var record = DownloadRecord(media: Media(id: 1, title: .init(romaji: "Old")), episode: 3, audio: .sub)
        record.preferredSource = "AniKoto · MegaPlay"
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["preferredSource"] = nil
        let old = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.preferredSource == nil)
        #expect(old.episode == 3)
    }

    @Test func picksTheVariantForTheQualitySetting() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720
        720/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        https://other.example/1080.m3u8
        """
        #expect(HLSDownload.variant(in: master, base: base, maxHeight: nil)?.absoluteString == "https://other.example/1080.m3u8")
        #expect(HLSDownload.variant(in: master, base: base, maxHeight: 720)?.absoluteString == "https://cdn.example/hls/720/index.m3u8")
        #expect(HLSDownload.variant(in: master, base: base, maxHeight: 240)?.absoluteString == "https://cdn.example/hls/360/index.m3u8")
        #expect(HLSDownload.variant(in: "#EXTM3U\n#EXTINF:4,\na.ts", base: base, maxHeight: nil) == nil)
    }

    @Test func rewritesTheMediaPlaylistToLocalFiles() {
        let media = """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example/k.key",IV=0x1234
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:10.0,
        seg-1.jpg
        #EXTINF:5.5,
        /abs/seg-2.ts?token=x
        #EXTINF:4,
        seg-1.jpg
        """
        let plan = HLSDownload.plan(media, base: base)
        #expect(plan.files.map(\.local) == ["key00000.bin", "init00000.mp4", "s00000.ts", "s00001.ts"])
        #expect(plan.files[0].remote.absoluteString == "https://keys.example/k.key")
        #expect(plan.files[3].remote.absoluteString == "https://cdn.example/abs/seg-2.ts?token=x")
        #expect(plan.playlist.contains(#"#EXT-X-KEY:METHOD=AES-128,URI="key00000.bin",IV=0x1234"#))
        #expect(plan.playlist.contains(#"#EXT-X-MAP:URI="init00000.mp4""#))
        #expect(plan.playlist.hasSuffix("#EXT-X-ENDLIST\n"))
        #expect(plan.duration == 19.5)
        // A segment listed twice is fetched once.
        #expect(plan.playlist.components(separatedBy: "s00000.ts").count == 3)
    }

    @Test func separateAudioPlansUseTheirOwnPrefix() {
        let audio = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXTINF:4,
        audio-1.aac
        #EXTINF:4,
        audio-2.aac
        """
        let plan = HLSDownload.plan(audio, base: base, prefix: "a")
        #expect(plan.files.map(\.local) == ["a00000.aac", "a00001.aac"])
        #expect(plan.playlist.contains("a00000.aac"))
        #expect(!plan.playlist.contains("s00000"))
    }

    @Test func kwikCopiesKeepTheIVsTheirSegmentNamesGive() {
        // Saved as it came, the local names (s00000.ts…) would lose the numbers Kwik's IVs come
        // from, and the copy would only play from 0:00.
        let kwik = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-KEY:METHOD=AES-128,URI="https://vault-04.uwucdn.top/mon.key"
        #EXTINF:10,
        https://vault-04.uwucdn.top/stream/x/segment-1-v1-a1.jpg
        #EXTINF:10,
        https://vault-04.uwucdn.top/stream/x/segment-5-v1-a1.jpg
        #EXT-X-ENDLIST
        """
        let plan = HLSDownload.plan(kwik, base: base)
        #expect(plan.files.map(\.local) == ["key00000.bin", "s00000.ts", "s00001.ts"], "one key file however many key lines")
        #expect(plan.files.map(\.isSegment) == [false, true, true])
        let lines = plan.playlist.components(separatedBy: "\n")
        #expect(lines.contains(#"#EXT-X-KEY:METHOD=AES-128,URI="key00000.bin",IV=0x00000000000000000000000000000001"#))
        #expect(lines.contains(#"#EXT-X-KEY:METHOD=AES-128,URI="key00000.bin",IV=0x00000000000000000000000000000005"#))
        #expect(lines.filter { $0 == "#EXT-X-ENDLIST" }.count == 1)
    }

    @Test func disguisedSegmentsAreSavedUnwrapped() {
        let ts = Data((0..<4).flatMap { _ in [UInt8(0x47)] + Array(repeating: UInt8(0x11), count: 187) })
        func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
            [0, 0, 0, UInt8(data.count)] + Array(type.utf8) + data + [0, 0, 0, 0]
        }
        let png = StreamRewrite.pngSignature + chunk("IHDR", Array(repeating: 1, count: 13)) + chunk("IEND", [])
        #expect(HLSDownload.unwrap(Data(png) + ts) == ts)
        #expect(HLSDownload.unwrap(ts) == ts)
        let cipher = Data([0xDD, 0x3C, 0x9A, 0xAF] + Array(repeating: 9, count: 2000))
        #expect(HLSDownload.unwrap(cipher) == cipher, "an encrypted segment with nothing in front is left alone")
        #expect(HLSDownload.unwrap((Data([0xAA]) + Data(png) + ts).dropFirst()) == ts, "a slice that doesn't start at 0")
    }

    @Test func onlyMediaCountsAsASavedSegment() {
        func check(_ bytes: [UInt8], encrypted: Bool = false) -> Bool {
            HLSDownload.isMedia(Array(bytes.prefix(HLSDownload.mediaCheckLength)), size: bytes.count, encrypted: encrypted)
        }
        // knob · Vidplay's segments: plain MPEG-TS served as image/jpeg (measured 2026-10-12).
        let ts = (0..<4).flatMap { _ in [UInt8(0x47)] + Array(repeating: UInt8(0x11), count: 187) }
        #expect(check(ts))
        #expect(check(Array("ID3".utf8) + ts))
        #expect(check([0, 0, 0, 24] + Array("styp".utf8) + Array(repeating: 0, count: 16)))
        #expect(check([0xFF, 0xF1, 0x50, 0x80] + Array(repeating: 0, count: 60)), "ADTS audio")

        // What a CDN answers 200 with instead of the segment.
        #expect(!check(Array("<!DOCTYPE html><html><body>429 Too Many Requests</body></html>".utf8)))
        #expect(!check(Array(#"{"error":"rate limited"}"#.utf8)))
        #expect(!check([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 7, count: 600)), "a placeholder JPEG")
        #expect(!check(Array("GIF89a".utf8) + Array(repeating: 0x47, count: 400)), "a GIF, though it starts with G")
        #expect(!check([0x47] + Array(repeating: 0x11, count: 400)), "one stray G is not a stream")
        #expect(!check([]))

        // Ciphertext says nothing but its length.
        #expect(check(Array(repeating: 0x3C, count: 4096), encrypted: true))
        #expect(!check(Array(repeating: 0x3C, count: 4095), encrypted: true))
    }

    @Test func segmentsUnderAnAESKeyAreMarkedEncrypted() {
        let media = """
        #EXTM3U
        #EXTINF:4,
        clear.ts
        #EXT-X-KEY:METHOD=AES-128,URI="k.key"
        #EXTINF:4,
        locked.ts
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:4,
        clear-again.ts
        """
        let plan = HLSDownload.plan(media, base: base)
        #expect(plan.files.filter(\.isSegment).map(\.encrypted) == [false, true, false])
    }

    @Test func aSavedCopyNamesTheSegmentsThatWontPlay() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("anilili-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = HLSDownload.plan("#EXTM3U\n#EXTINF:4,\na.ts\n#EXTINF:4,\nb.ts\n#EXTINF:4,\nc.ts\n", base: base)
        try Data(saved.playlist.utf8).write(to: folder.appendingPathComponent("index.m3u8"))
        let ts = Data((0..<4).flatMap { _ in [UInt8(0x47)] + Array(repeating: UInt8(0x11), count: 187) })
        try ts.write(to: folder.appendingPathComponent("s00000.ts"))
        try Data("<html>Too Many Requests</html>".utf8).write(to: folder.appendingPathComponent("s00001.ts"))
        // s00002.ts was never written.
        #expect(HLSDownload.damagedSegments(in: folder) == ["s00001.ts", "s00002.ts"])
        #expect(HLSDownload.damagedSegments(in: folder.appendingPathComponent("nothing-here")).isEmpty)
    }

    @Test func queueRunsTwoAtATimeOldestFirst() {
        let media = Media(id: 1, title: .init(romaji: "A"))
        let records = (1...4).map { DownloadRecord(media: media, episode: $0, audio: .sub, createdAt: Date(timeIntervalSince1970: Double(10 - $0))) }
        #expect(DownloadQueue.next(records, running: []).map(\.episode) == [4, 3])
        #expect(DownloadQueue.next(records, running: ["1-4-sub"]).map(\.episode) == [3])
        #expect(DownloadQueue.next(records, running: ["x", "y"]).isEmpty)
    }

    @Test func groupsBySeries() {
        let a = Media(id: 1, title: .init(romaji: "A"))
        let b = Media(id: 2, title: .init(romaji: "B"))
        var done = DownloadRecord(media: a, episode: 2, audio: .sub, createdAt: Date(timeIntervalSince1970: 5))
        done.state = .done
        done.bytes = 100
        let series = DownloadQueue.series([done, DownloadRecord(media: b, episode: 1, audio: .dub, createdAt: Date(timeIntervalSince1970: 9)),
                                           DownloadRecord(media: a, episode: 1, audio: .sub, createdAt: Date(timeIntervalSince1970: 1))])
        #expect(series.map(\.id) == [2, 1])
        #expect(series[1].episodes.map(\.episode) == [1, 2])
        #expect(series[1].doneCount == 1)
        #expect(series[1].activeCount == 1)
        #expect(series[1].bytes == 100)
    }

    @Test func recordsSurviveARoundTrip() throws {
        var record = DownloadRecord(media: Media(id: 1, title: .init(romaji: "A")), episode: 3, audio: .dub)
        record.state = .failed("HTTP 403")
        record.kind = .hls
        let back = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(record))
        #expect(back == record)
        #expect(back.entryFile == "index.m3u8")
    }
}
