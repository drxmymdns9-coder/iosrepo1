import Foundation
import Testing
@testable import AnililiCore

/// `anilili://` links, against the cases the desktop and Android answer (parity/links.json).
struct AppLinkTests {
    private func corpus() throws -> JSON { try JSON.parse(Fixture.data("parity/links.json")) }

    private func link(_ item: JSON) throws -> AppLink {
        let id = item["id"]?.number.map { Int($0) } ?? 0
        switch item["page"]?.string {
        case "anime": return .anime(id: id)
        case "watch": return .watch(id: id, episode: try #require(item["episode"]?.number), start: item["start"]?.number)
        case "search": return .search(query: try #require(item["query"]?.string))
        default: throw Fixture.FixtureMissing(name: "page")
        }
    }

    @Test func readsEveryForm() throws {
        for item in try corpus()["read"]?.array ?? [] {
            let text = try #require(item["link"]?.string)
            #expect(AppLink(text) == (try link(item)), "\(text)")
        }
    }

    @Test func refusesWhatItCannotOpen() throws {
        for item in try corpus()["refuse"]?.array ?? [] {
            if case .string(let text) = item { #expect(AppLink(text) == nil, "\(text)") }
        }
    }

    @Test func writesTheCanonicalForm() throws {
        for item in try corpus()["write"]?.array ?? [] {
            let link = try link(item)
            #expect(link.url == item["link"]?.string)
            if case .watch(_, _, .some) = link { continue }
            #expect(AppLink(link.url) == link, "reads back what it writes")
        }
    }
}
