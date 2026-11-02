import Foundation

/// An AniList anime entry, decoded straight from GraphQL field names. Mirrors the Android app's
/// `Media` (data/model/AniListModels.kt); every field but `id` is optional because each query asks
/// for a different subset.
public struct Media: Codable, Identifiable, Hashable, Sendable {
    public struct Title: Codable, Hashable, Sendable {
        public var romaji: String?
        public var english: String?
        public var native: String?
        public var userPreferred: String?

        public init(romaji: String? = nil, english: String? = nil, native: String? = nil, userPreferred: String? = nil) {
            self.romaji = romaji
            self.english = english
            self.native = native
            self.userPreferred = userPreferred
        }

        /// The app is English-first; AniList's viewer preference is only a fallback.
        public var preferred: String {
            [english, userPreferred, romaji, native].compactMap { $0?.nonBlank }.first ?? "Untitled"
        }

        /// Every distinct name, for providers that search by title.
        public var all: [String] {
            var seen = Set<String>()
            return [english, romaji, native].compactMap { $0?.nonBlank }.filter { seen.insert($0).inserted }
        }
    }

    public struct CoverImage: Codable, Hashable, Sendable {
        public var extraLarge: String?
        public var large: String?
        public var color: String?

        public init(extraLarge: String? = nil, large: String? = nil, color: String? = nil) {
            self.extraLarge = extraLarge
            self.large = large
            self.color = color
        }

        public var best: URL? { (extraLarge ?? large).flatMap(URL.init(string:)) }
        /// AniList's `large` is already bigger than a rail poster; Android draws it there to save data.
        public var card: URL? { (large ?? extraLarge).flatMap(URL.init(string:)) }
    }

    public struct NextAiring: Codable, Hashable, Sendable {
        public var episode: Int
        public var airingAt: Int
        public var timeUntilAiring: Int?

        public var date: Date { Date(timeIntervalSince1970: TimeInterval(airingAt)) }
    }

    public struct Studio: Codable, Hashable, Sendable {
        public var id: Int?
        public var name: String?
        public var isAnimationStudio: Bool?
    }

    public struct Studios: Codable, Hashable, Sendable {
        public var nodes: [Studio]?
    }

    public struct FuzzyDate: Codable, Hashable, Sendable {
        public var year: Int?
        public var month: Int?
        public var day: Int?

        public var date: Date? {
            guard let year else { return nil }
            return DateComponents(calendar: Calendar(identifier: .gregorian), year: year, month: month ?? 1, day: day ?? 1).date
        }
    }

    public struct Trailer: Codable, Hashable, Sendable {
        public var id: String?
        public var site: String?
        public var thumbnail: String?

        /// The page the trailer plays on. AniList only ever names YouTube or Dailymotion.
        public var watchURL: URL? {
            guard let id = id?.nonBlank else { return nil }
            switch site?.lowercased() {
            case "youtube": return URL(string: "https://www.youtube.com/watch?v=\(id)")
            case "dailymotion": return URL(string: "https://www.dailymotion.com/video/\(id)")
            default: return nil
            }
        }
    }

    public struct Tag: Codable, Hashable, Sendable {
        public var name: String
        public var rank: Int?
        public var isMediaSpoiler: Bool?
        public var isGeneralSpoiler: Bool?
    }

    /// One row of AniList's licensor links, which carry a still; the number only lives in the title.
    public struct StreamingEpisode: Codable, Hashable, Sendable {
        public var title: String?
        public var thumbnail: String?
        public var url: String?
        public var site: String?
    }

    public struct RelationEdge: Codable, Hashable, Sendable {
        public var relationType: String?
        public var node: Media?
    }

    public struct Relations: Codable, Hashable, Sendable {
        public var edges: [RelationEdge]?
    }

    public var id: Int
    public var idMal: Int?
    public var title: Title
    public var coverImage: CoverImage?
    public var bannerImage: String?
    public var description: String?
    public var episodes: Int?
    public var status: String?
    public var format: String?
    public var season: String?
    public var seasonYear: Int?
    public var averageScore: Int?
    public var meanScore: Int?
    public var popularity: Int?
    public var favourites: Int?
    public var genres: [String]?
    public var tags: [Tag]?
    public var duration: Int?
    public var isAdult: Bool?
    public var countryOfOrigin: String?
    public var nextAiringEpisode: NextAiring?
    public var studios: Studios?
    public var startDate: FuzzyDate?
    public var endDate: FuzzyDate?
    public var trailer: Trailer?
    public var streamingEpisodes: [StreamingEpisode]?
    public var relations: Relations?

    public init(id: Int, title: Title) {
        self.id = id
        self.title = title
    }

    public var bannerURL: URL? { bannerImage.flatMap(URL.init(string:)) }

    /// Backdrop for wide heroes, best landscape source first: the banner, then the trailer's 16:9
    /// frame, then the cover. A soft landscape still under a scrim reads better than a poster
    /// sliced down to a letterbox strip.
    public var heroImage: URL? {
        [bannerImage, trailer?.thumbnail, coverImage?.extraLarge, coverImage?.large]
            .compactMap { $0?.nonBlank }.first.flatMap(URL.init(string:))
    }

    /// The animation studio the show page names: the first one AniList marks as such, never a
    /// producer or distributor.
    public var mainStudio: Studio? {
        studios?.nodes?.first { $0.isAnimationStudio == true && $0.name?.nonBlank != nil }
    }

    /// How many episodes are out: one less than the next to air while airing, else the total.
    /// `nil` when AniList does not know, which is common for long-runners and adult OVAs.
    public var releasedEpisodes: Int? {
        if let next = nextAiringEpisode { return max(0, next.episode - 1) }
        if status == "NOT_YET_RELEASED" { return 0 }
        return episodes
    }

    /// Whether AniList can't say how many episodes are out: released, with no total and no
    /// schedule (Android's `episodeCountUnknown`). Nearly every hentai OVA series is in this state
    /// for as long as it runs, since its episodes have no broadcast to count.
    public var episodeCountUnknown: Bool {
        status != "NOT_YET_RELEASED" && episodes == nil && nextAiringEpisode == nil
    }

    /// Android's poster caption: `TV · 2016 · 13 EP`.
    public var cardDetails: String {
        [format?.replacingOccurrences(of: "_", with: " "), seasonYear.map(String.init), episodes.map { "\($0) EP" }]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
    }

    public var formatLabel: String? {
        guard let format else { return nil }
        switch format {
        case "TV": return "TV"
        case "TV_SHORT": return "TV Short"
        case "MOVIE": return "Movie"
        case "SPECIAL": return "Special"
        case "OVA": return "OVA"
        case "ONA": return "ONA"
        case "MUSIC": return "Music"
        default: return format.capitalized
        }
    }

    public var statusLabel: String? {
        guard let status else { return nil }
        switch status {
        case "FINISHED": return "Finished"
        case "RELEASING": return "Releasing"
        case "NOT_YET_RELEASED": return "Not yet released"
        case "CANCELLED": return "Cancelled"
        case "HIATUS": return "Hiatus"
        default: return status.capitalized
        }
    }

    public var seasonLabel: String? {
        switch (season, seasonYear) {
        case let (season?, year?): return "\(season.capitalized) \(year)"
        case let (nil, year?): return String(year)
        default: return nil
        }
    }
}

extension String {
    public var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
