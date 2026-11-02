import Foundation
import Testing
@testable import AnililiCore

/// Android's `RandomAnimeDeckTest` behaviour.
struct RandomDeckTests {
    private static func page(_ page: Int, size: Int = 5) -> [Media] {
        (0..<size).map { Media(id: page * 100 + $0, title: .init(romaji: "\(page)-\($0)")) }
    }

    actor Counter {
        var fetches: [Int] = []
        func add(_ page: Int) { fetches.append(page) }
    }

    @Test func dealsEveryTitleOnceBeforeRepeating() async throws {
        let counter = Counter()
        let deck = RandomDeck(pageCount: 3) { page in
            await counter.add(page)
            return Self.page(page)
        }
        var seen = Set<Int>()
        for _ in 0..<15 {
            let media = try #require(try await deck.draw())
            #expect(seen.insert(media.id).inserted)
        }
        #expect(await counter.fetches.sorted() == [1, 2, 3])
        // The pool has gone round: it starts again rather than running dry.
        #expect(try await deck.draw() != nil)
    }

    @Test func skipsStartedTitlesUnlessNothingElseIsLeft() async throws {
        let deck = RandomDeck(pageCount: 1, skip: { $0.id != 102 }) { page in Self.page(page) }
        #expect(try await deck.draw()?.id == 102)
        let all = RandomDeck(pageCount: 1, skip: { _ in true }) { page in Self.page(page, size: 2) }
        #expect(try await all.draw() != nil)
    }

    @Test func everyThirdCardComesFromTaste() async throws {
        let liked = [Media(id: 9001, title: .init(romaji: "Liked"))]
        let deck = RandomDeck(pageCount: 2, taste: { liked }) { page in Self.page(page) }
        var ids: [Int] = []
        for _ in 0..<4 { ids.append(try #require(try await deck.draw()).id) }
        #expect(ids[2] == 9001)
        #expect(!ids.enumerated().contains { $0.offset != 2 && $0.element == 9001 })
    }

    @Test func aShrunkenPoolStopsShort() async throws {
        let deck = RandomDeck(pageCount: 5) { page in page <= 2 ? Self.page(page, size: 1) : [] }
        var got = 0
        for _ in 0..<4 where try await deck.draw() != nil { got += 1 }
        #expect(got == 4)
    }
}
