import Foundation

extension AniListClient {
    /// One further page of a Home catalogue row, for Load More once the row is expanded (Android's
    /// `HomeViewModel.loadMore`). Page 1 is what `homeCollections` already fetched.
    public func homeRow(_ row: HomeRow, page: Int, hideAdult: Bool = false, now: Date = Date()) async throws -> MediaPage {
        if row == .newest { return try await recentlyAired(page: page, hideAdult: hideAdult, now: now) }
        let current = Self.season(containing: now)
        let arguments: String
        var variables: [String: Variable] = ["page": .int(page)]
        switch row {
        case .trending: arguments = "sort: [TRENDING_DESC]"
        case .popular:
            arguments = "season: $season, seasonYear: $seasonYear, sort: [POPULARITY_DESC]"
            variables["season"] = .string(current.season)
            variables["seasonYear"] = .int(current.year)
        case .topRated: arguments = "sort: [SCORE_DESC]"
        case .movies: arguments = "format: MOVIE, sort: [POPULARITY_DESC]"
        case .upcoming: arguments = "status: NOT_YET_RELEASED, sort: [POPULARITY_DESC]"
        case .continueWatching, .forYou, .because, .newest:
            return MediaPage(items: [], hasNextPage: false, page: page, total: 0)
        }
        if hideAdult { variables["isAdult"] = .bool(false) }
        // AniList refuses a declared variable the query doesn't use, so the season pair is
        // declared only for the row that filters on it.
        let declarations = row == .popular
            ? "$page: Int, $isAdult: Boolean, $season: MediaSeason, $seasonYear: Int"
            : "$page: Int, $isAdult: Boolean"
        let query = """
        query (\(declarations)) {
          Page(page: $page, perPage: 30) {
            pageInfo { hasNextPage }
            media(type: ANIME, isAdult: $isAdult, \(arguments)) { \(Self.mediaFields) }
          }
        }
        """
        struct PageInfo: Decodable { var hasNextPage: Bool? }
        struct PageResult: Decodable { var pageInfo: PageInfo?; var media: [Media] }
        struct Payload: Decodable { var Page: PageResult }
        let data: Payload = try await run(query, variables)
        return MediaPage(items: data.Page.media, hasNextPage: data.Page.pageInfo?.hasNextPage ?? false, page: page, total: 0)
    }

    /// New Episodes: recently aired schedule entries, newest first, one card per show.
    private func recentlyAired(page: Int, hideAdult: Bool, now: Date) async throws -> MediaPage {
        let query = """
        query ($page: Int, $airedBefore: Int) {
          Page(page: $page, perPage: 50) {
            pageInfo { hasNextPage }
            airingSchedules(airingAt_lesser: $airedBefore, sort: TIME_DESC) { media { \(Self.mediaFields) } }
          }
        }
        """
        struct Row: Decodable { var media: Media? }
        struct PageInfo: Decodable { var hasNextPage: Bool? }
        struct PageResult: Decodable { var pageInfo: PageInfo?; var airingSchedules: [Row] }
        struct Payload: Decodable { var Page: PageResult }
        let data: Payload = try await run(query, [
            "page": .int(page),
            "airedBefore": .int(Int(now.timeIntervalSince1970 - Self.newestAiredBuffer)),
        ])
        var seen = Set<Int>()
        let items = data.Page.airingSchedules.compactMap(\.media).filter { seen.insert($0.id).inserted && !(hideAdult && $0.isAdult == true) }
        return MediaPage(items: items, hasNextPage: data.Page.pageInfo?.hasNextPage ?? false, page: page, total: 0)
    }
}
