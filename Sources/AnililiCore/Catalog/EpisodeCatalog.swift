import Foundation

/// What a show page lists, after the Android app's episode assembly: the providers' episodes, with
/// what they lack filled in from the media index (titles, TMDB stills, synopses, air dates) and
/// then from AniList's licensor links, whose only number lives in their titles.
public enum EpisodeCatalog {
    /// Fills gaps in `listing` from the index and AniList, and adds the index's episodes the
    /// providers don't have yet as unplayable rows (in neither `subbed` nor `dubbed`), so a page
    /// can show what's coming.
    public static func merge(_ listing: EpisodeListing, index: [MediaIndex.Episode], streaming: [Media.StreamingEpisode], filler: Set<Int> = []) -> EpisodeListing {
        var byNumber: [Int: MediaIndex.Episode] = [:]
        for episode in index {
            if let number = episode.number, number == number.rounded(), number >= 1 { byNumber[Int(number)] = episode }
        }
        var licensed: [Int: Media.StreamingEpisode] = [:]
        for row in streaming {
            if let number = streamingNumber(row.title) { licensed[number] = licensed[number] ?? row }
        }
        var merged = listing
        merged.episodes = listing.episodes.map { episode in
            var episode = episode
            if let fromIndex = byNumber[episode.number] {
                if episode.title == nil { episode.title = fromIndex.title?.nonBlank }
                if episode.thumbnail == nil { episode.thumbnail = fromIndex.still.flatMap(URL.init(string:)) }
                if episode.synopsis == nil { episode.synopsis = fromIndex.overview?.nonBlank }
                if episode.airedOn == nil { episode.airedOn = fromIndex.air_date }
                if episode.duration == nil, let runtime = fromIndex.runtime { episode.duration = Double(runtime * 60) }
            }
            if let row = licensed[episode.number] {
                if episode.thumbnail == nil { episode.thumbnail = row.thumbnail.flatMap(URL.init(string:)) }
                if episode.title == nil { episode.title = streamingTitle(row.title) }
            }
            if filler.contains(episode.number) { episode.isFiller = true }
            return episode
        }
        let known = Set(merged.episodes.map(\.number))
        let upcoming = byNumber.values.compactMap { entry -> EpisodeInfo? in
            guard let value = entry.number else { return nil }
            let number = Int(value)
            guard !known.contains(number) else { return nil }
            var episode = EpisodeInfo(number: number)
            episode.title = entry.title?.nonBlank
            episode.thumbnail = entry.still.flatMap(URL.init(string:))
            episode.synopsis = entry.overview?.nonBlank
            episode.airedOn = entry.air_date
            return episode
        }
        // Only what's past the providers' last episode: a gap in the middle is a provider missing
        // one, not an episode that hasn't aired.
        let last = merged.episodes.map(\.number).max() ?? 0
        merged.episodes += upcoming.filter { $0.number > last }
        merged.episodes.sort { $0.number < $1.number }
        return merged
    }

    /// "Episode 12 - Something" → 12.
    static func streamingNumber(_ title: String?) -> Int? {
        guard let title, let match = Pattern("^\\s*episode\\s+(\\d+)").firstMatch(in: title)?[1] else { return nil }
        return Int(match)
    }

    /// "Episode 12 - Something" → "Something".
    static func streamingTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let stripped = Pattern("^\\s*episode\\s+\\d+\\s*[-–—:]\\s*").replacing(in: title, with: "")
        return stripped == title ? nil : stripped.nonBlank
    }

    /// One entry of the range picker: a contiguous slice, labelled by its two ends.
    public struct Block: Hashable, Sendable {
        public var label: String
        public var episodes: [EpisodeInfo]
    }

    public static let blockSize = 100
    /// Below this the range picker and the filter field are noise; one cour fits a short scroll.
    public static let browserMinimum = 12

    /// Slices by position, not number, so gaps and recaps still give even blocks and a season that
    /// starts at 1051 labels its first block from there.
    public static func blocks(_ episodes: [EpisodeInfo], size: Int = blockSize) -> [Block] {
        stride(from: 0, to: episodes.count, by: size).map { start in
            let chunk = Array(episodes[start..<min(start + size, episodes.count)])
            let first = chunk.first?.number ?? 0
            let last = chunk.last?.number ?? 0
            return Block(label: first == last ? "\(first)" : "\(first) – \(last)", episodes: chunk)
        }
    }

    /// Number prefix first, then title: the field doubles as "jump to episode".
    public static func filter(_ episodes: [EpisodeInfo], _ query: String) -> [EpisodeInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return episodes }
        let byNumber = episodes.filter { String($0.number).hasPrefix(trimmed) }
        let numbers = Set(byNumber.map(\.number))
        let byTitle = episodes.filter { !numbers.contains($0.number) && ($0.title?.localizedCaseInsensitiveContains(trimmed) ?? false) }
        return byNumber + byTitle
    }

    /// The block holding `number`, so a resumed long-runner opens where the viewer is.
    public static func blockIndex(_ blocks: [Block], holding number: Int?) -> Int {
        guard let number else { return 0 }
        return blocks.firstIndex { $0.episodes.contains { $0.number == number } } ?? 0
    }
}
