import Foundation
import Testing
@testable import AnililiCore

struct HomeLayoutTests {
    @Test func nothingStoredIsTheDefault() {
        #expect(HomeLayout.decode(nil) == .standard)
        #expect(HomeLayout.decode("  ") == .standard)
        #expect(HomeLayout.standard.visible.first == .continueWatching)
    }

    @Test func roundTripsAndroidsEncoding() {
        let layout = HomeLayout.standard.moving(.movies, to: 0).withHidden(.because, true)
        let stored = layout.encode()
        #expect(stored.hasPrefix("movies,continue,for_you,-because,"))
        #expect(HomeLayout.decode(stored) == layout)
        #expect(!HomeLayout.decode(stored).visible.contains(.because))
    }

    @Test func unknownKeysAndRepeatsAreDropped() {
        let layout = HomeLayout.decode("newest,bogus,newest,-trending")
        #expect(layout.order.filter { $0 == .newest }.count == 1)
        #expect(layout.hidden == [.trending])
    }

    @Test func aRowTheStoredLayoutLacksReturnsWhereTheDefaultHasIt() {
        // Customised before Top Rated and Upcoming existed: each comes back right after the row
        // that precedes it in the default, wherever the viewer moved that row (Movies went first,
        // so Upcoming follows it there), rather than being dumped at the bottom.
        let layout = HomeLayout.decode("movies,continue,for_you,because,newest,trending,popular")
        #expect(layout.order == [.movies, .upcoming, .continueWatching, .forYou, .because, .newest, .trending, .popular, .topRated])
    }
}
