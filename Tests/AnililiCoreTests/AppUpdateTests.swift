import Foundation
import Testing
@testable import AnililiCore

struct AppUpdateTests {
    @Test func aNewerVersionPromptsAndARebuildIsQuiet() {
        #expect(UpdateOffer.decide(remoteVersion: "0.0.2", remoteBuild: 5, installedVersion: "0.0.1", installedBuild: 4) == .prompt)
        #expect(UpdateOffer.decide(remoteVersion: "0.0.1", remoteBuild: 5, installedVersion: "0.0.1", installedBuild: 4) == .quiet)
        #expect(UpdateOffer.decide(remoteVersion: "0.0.1", remoteBuild: 4, installedVersion: "0.0.1", installedBuild: 4) == .none)
        #expect(UpdateOffer.decide(remoteVersion: "0.0.1", remoteBuild: nil, installedVersion: "0.0.1", installedBuild: 4) == .none)
    }

    @Test func anOlderBuildIsNeverOfferedWhateverItsName() {
        #expect(UpdateOffer.decide(remoteVersion: "0.0.9", remoteBuild: 3, installedVersion: "0.0.1", installedBuild: 4) == .none)
        #expect(UpdateOffer.decide(remoteVersion: "0.0.1", remoteBuild: nil, installedVersion: "0.0.2", installedBuild: 1) == .none)
    }

    @Test func versionsCompareNumerically() {
        #expect(UpdateOffer.compareVersions("0.0.10", "0.0.9") == 1)
        #expect(UpdateOffer.compareVersions("v0.1", "0.1.0") == 0)
        #expect(UpdateOffer.compareVersions("1.2.3-beta", "1.2.4") == -1)
        #expect(UpdateOffer.label(version: "0.0.1", build: 5) == "v0.0.1 (build 5)")
        #expect(UpdateOffer.label(version: "0.0.2", build: nil) == "v0.0.2")
    }

    @Test func theManifestNamesTheFileAndItsMirrors() throws {
        let content = #"""
        {"version":"0.0.2","build":5,"changelog":"## 📺 iPad\n- **Fixed** it",
         "ios":{"url":"https://example.com/Anilili-iOS.ipa","sizeBytes":4260492,"sha256":"ab12",
                "mirrors":["https://mirror.example/Anilili-iOS.ipa","http://insecure.example/x.ipa","https://example.com/Anilili-iOS.ipa"]}}
        """#
        let update = try #require(AppUpdate.parse(content))
        #expect(update.version == "0.0.2")
        #expect(update.build == 5)
        #expect(update.sizeBytes == 4_260_492)
        #expect(update.sha256 == "ab12")
        #expect(update.changelog.hasPrefix("## 📺 iPad"))
        #expect(update.mirrors.map(\.absoluteString) == ["https://mirror.example/Anilili-iOS.ipa", "https://example.com/Anilili-iOS.ipa"],
                "plain http is dropped")
        #expect(update.downloadURLs.map(\.absoluteString) == ["https://example.com/Anilili-iOS.ipa", "https://mirror.example/Anilili-iOS.ipa"],
                "the primary isn't tried twice")
    }

    @Test func aManifestWithoutAnHttpsFileIsNoUpdate() {
        #expect(AppUpdate.parse(#"{"version":"0.0.2","ios":{"url":"http://example.com/a.ipa"}}"#) == nil)
        #expect(AppUpdate.parse(#"{"version":"0.0.2"}"#) == nil)
        #expect(AppUpdate.parse(#"{"ios":{"url":"https://example.com/a.ipa"}}"#) == nil)
        #expect(AppUpdate.parse("not json") == nil)
    }

    @Test func anUnsignedOrForeignEventIsRefused() {
        let event: JSON = .object([
            "id": .string(String(repeating: "0", count: 64)), "pubkey": .string(NostrEvent.projectPubkey),
            "created_at": .number(1), "kind": .number(30078), "tags": .array([.array([.string("d"), .string(AppUpdate.dTag)])]),
            "content": .string(#"{"version":"9.9.9","ios":{"url":"https://evil.example/a.ipa"}}"#), "sig": .string(String(repeating: "0", count: 128)),
        ])
        #expect(AppUpdate.from(event: event) == nil)
    }

    @Test func releaseNotesReadAsAndroidWritesThem() {
        let notes = "## 📺 iPad\n- **A menu** across the top\n\n**Servers**\n* Filters\nThanks for updating!"
        #expect(ReleaseNotes.parse(notes) == [
            .heading("📺 iPad"), .bullet("**A menu** across the top"), .heading("Servers"), .bullet("Filters"), .paragraph("Thanks for updating!"),
        ])
    }
}
