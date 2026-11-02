import Foundation
import Testing
@testable import AnililiCore

/// Android's `anilili-backup` v1, read and written by both apps.
struct BackupTests {
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    @Test func pbkdf2MatchesTheRFCVectors() {
        let salt = Data("salt".utf8)
        #expect(hex(BackupCrypto.deriveKey(passphrase: "password", salt: salt, iterations: 1)) == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        #expect(hex(BackupCrypto.deriveKey(passphrase: "password", salt: salt, iterations: 2)) == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        #expect(hex(BackupCrypto.deriveKey(passphrase: "password", salt: salt, iterations: 4096)) == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    /// Sealed by an independent implementation (Python `cryptography`), opened by both apps.
    @Test func opensTheParityFixture() throws {
        let fixture = try JSON.parse(Fixture.data("parity/backup-sealed.json"))
        let passphrase = try #require(fixture["passphrase"]?.string)
        let file = try JSONEncoder().encode(try #require(fixture["file"]))
        let document = try BackupDocument.decode(file)
        #expect(document.credentials?.services == ["anilist", "mal"])
        let credentials = try #require(try document.openCredentials(passphrase: passphrase))
        #expect(credentials.aniListToken == "android-token")
        #expect(credentials.hasMALHandoff)
        #expect(credentials.malIssuedAt == 42)
        #expect(throws: BackupDocument.BackupError.wrongPassphrase) { try document.openCredentials(passphrase: "WRNG-PASS") }
    }

    @Test func theSealIsBoundToTheDocumentHeader() throws {
        let fixture = try JSON.parse(Fixture.data("parity/backup-sealed.json"))
        var document = try BackupDocument.decode(JSONEncoder().encode(try #require(fixture["file"])))
        document.version = 0
        #expect(throws: BackupDocument.BackupError.wrongPassphrase) { try document.openCredentials(passphrase: "K7M4-9QXR") }
    }

    @Test func sealAndOpenRoundTrip() throws {
        var document = BackupDocument()
        let plaintext = try JSONEncoder().encode(BackupDocument.Credentials(aniListToken: "tok"))
        var sealed = try BackupCrypto.seal(passphrase: "ABCD-EFGH", plaintext: plaintext, associatedData: document.associatedData, iterations: 1000)
        sealed.services = ["anilist"]
        document.credentials = sealed
        let reread = try BackupDocument.decode(document.encoded())
        #expect(try reread.openCredentials(passphrase: "ABCD-EFGH")?.aniListToken == "tok")
        #expect(throws: BackupDocument.BackupError.shortPassphrase) { try document.seal(.init(aniListToken: "t"), passphrase: "short") }
    }

    @Test func generatedPassphrasesAreTypeable() {
        let passphrase = BackupCrypto.generatePassphrase()
        #expect(passphrase.count == 9)
        #expect(passphrase.split(separator: "-").map(\.count) == [4, 4])
        #expect(passphrase.allSatisfy { $0 == "-" || BackupCrypto.alphabet.contains($0) })
    }

    @Test func refusesWhatIsntABackup() {
        #expect(throws: BackupDocument.BackupError.self) { try BackupDocument.decode(Data()) }
        #expect(throws: BackupDocument.BackupError.self) { try BackupDocument.decode(Data(#"{"format":"mal-export"}"#.utf8)) }
        #expect(throws: BackupDocument.BackupError.newer(2)) { try BackupDocument.decode(Data(#"{"format":"anilili-backup","version":2}"#.utf8)) }
    }

    /// What Android writes, trimmed: missing fields take Android's defaults.
    @Test func readsAnAndroidDocument() throws {
        let json = """
        {"format":"anilili-backup","version":1,"createdAt":1760000000000,"appVersion":"0.1.14",
         "settings":{"autoplay":false,"theme_accent":"violet","hold_playback_speed":1.5,"caption_text_scale":120},
         "watchlist":[{"anilistId":21,"title":"One Piece","cover":null,"format":"TV","averageScore":87,"addedAt":5}],
         "history":[{"anilistId":5114,"title":"FMA","cover":"https://x/c.jpg","episodeNumber":7.0,"provider":"auto","category":"sub",
                     "positionMs":600000,"durationMs":1440000,"updatedAt":1760000000000,"watchedEpisodes":[1.0,2.0,3.0,4.5],
                     "resumePoints":{"5":{"positionMs":30000,"durationMs":1440000}}}],
         "searchHistory":["frieren"],"customLists":[{"name":"Favs","entries":[]}],"unknownFutureField":true}
        """
        let document = try BackupDocument.decode(Data(json.utf8))
        #expect(document.settings["autoplay"] == .bool(false))
        #expect(document.settings["hold_playback_speed"] == .number(1.5))
        #expect(document.summary == "4 settings · 1 saved · 1 list · 1 continue watching · 1 search")
        let show = try #require(BackupLibrary.show(document.history[0]))
        #expect(show.lastEpisode == 7)
        #expect(show.episodes.keys.sorted() == [1, 2, 3, 5, 7])
        #expect(show.episodes[3]?.isFinished == true)
        #expect(show.episodes[7]?.position == 600)
        #expect(show.media.title.preferred == "FMA")
        #expect(show.media.coverImage?.large == "https://x/c.jpg")
    }

    @Test func writesWhatAndroidRequires() throws {
        var history = WatchHistory()
        var media = Media(id: 1, title: .init(romaji: "Show"))
        media.coverImage = .init(large: "https://x/c.jpg")
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        history.record(media, episode: 1, position: 1400, duration: 1440, at: date)
        history.record(media, episode: 2, position: 300, duration: 1440, at: date)
        var watchlist = Watchlist()
        watchlist.toggle(Media(id: 9, title: .init(romaji: "Saved")))

        var document = BackupDocument()
        document.history = BackupLibrary.historyEntries(history, preferDub: true)
        document.watchlist = BackupLibrary.watchlistEntries(watchlist)
        let data = try document.encoded()
        let text = String(decoding: data, as: UTF8.self)
        // kotlinx needs nullable fields without defaults present, as null.
        #expect(text.contains(#""cover" : null"#))
        #expect(text.contains(#""credentials" : null"#))

        let entry = document.history[0]
        #expect(entry.episodeNumber == 2)
        #expect(entry.category == "dub")
        #expect(entry.positionMs == 300_000)
        #expect(entry.watchedEpisodes == [1])
        #expect(entry.resumePoints["2"]?.positionMs == 300_000)
        #expect(entry.updatedAt == 1_760_000_000_000)

        let back = try #require(BackupLibrary.show(try BackupDocument.decode(data).history[0]))
        #expect(back.lastEpisode == 2)
        #expect(back.episodes[1]?.isFinished == true)
        #expect(back.episodes[2]?.position == 300)
    }

    @Test func restoreKeepsTheNewerRowAndEveryWatchedEpisode() {
        var history = WatchHistory()
        let media = Media(id: 1, title: .init(romaji: "Show"))
        history.setWatched(media, episode: 1, true, at: Date(timeIntervalSince1970: 100))
        let incoming = WatchHistory.Show(media: media, episodes: [3: .init(position: 50, duration: 100, updatedAt: Date(timeIntervalSince1970: 200))],
                                         lastEpisode: 3, updatedAt: Date(timeIntervalSince1970: 200))
        let changed = history.restore(incoming)
        #expect(changed)
        #expect(history.shows[1]?.lastEpisode == 3)
        #expect(history.isWatched(mediaID: 1, episode: 1))
        let again = history.restore(incoming)
        #expect(!again)
    }
}

/// Android's `MalExport`.
struct MALExportTests {
    @Test func writesMALsImportFormat() {
        var media = Media(id: 1, title: .init(romaji: "Tom & Jerry <3"))
        media.idMal = 77
        media.format = "MOVIE"
        media.episodes = 1
        let entry = MALExport.entry(media, status: "Completed", progress: 0, score: 8.6)
        #expect(entry?.watchedEpisodes == 1)
        #expect(entry?.score == 9)
        let xml = MALExport.xml(username: nil, entries: [entry!])
        #expect(xml.contains("<series_animedb_id>77</series_animedb_id>"))
        #expect(xml.contains("<series_title>Tom &amp; Jerry &lt;3</series_title>"))
        #expect(xml.contains("<series_type>Movie</series_type>"))
        #expect(xml.contains("<user_name>Anilili</user_name>"))
        #expect(MALExport.fileName(Date(timeIntervalSince1970: 1_760_227_200)).hasPrefix("Anilili-mal-export-2025"))
    }

    @Test func fallsBackToTheDevice() {
        var history = WatchHistory()
        var watched = Media(id: 1, title: .init(romaji: "A"))
        watched.idMal = 10
        watched.episodes = 12
        history.setWatched(watched, episode: 3, true)
        var watchlist = Watchlist()
        var saved = Media(id: 2, title: .init(romaji: "B"))
        saved.idMal = 20
        watchlist.toggle(saved)
        watchlist.toggle(Media(id: 3, title: .init(romaji: "No MAL id")))
        let (entries, skipped) = MALExport.entries(account: nil, history: history, watchlist: watchlist)
        #expect(entries.map(\.status) == ["Watching", "Plan to Watch"])
        #expect(entries.first?.watchedEpisodes == 3)
        #expect(skipped == 1)
    }
}
