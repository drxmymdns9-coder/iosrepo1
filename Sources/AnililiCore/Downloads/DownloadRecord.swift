import Foundation

/// One saved (or saving) episode. Its files live in `folder`, under the app's downloads directory.
public struct DownloadRecord: Codable, Identifiable, Hashable, Sendable {
    public enum State: Codable, Hashable, Sendable {
        case queued
        case downloading(Double)
        case paused
        case done
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .queued, .downloading: return true
            default: return false
            }
        }
    }

    public enum Kind: String, Codable, Sendable { case hls, mp4 }

    public var media: Media
    public var episode: Int
    public var audio: AudioTrack
    public var episodeTitle: String?
    public var thumbnail: URL?
    public var state: State
    public var kind: Kind?
    /// Which server it came from ("Miruro · kiwi").
    public var source: String?
    /// The server the viewer picked to save from (a `VideoSource.label`), tried before the rest;
    /// nil lets the queue choose.
    public var preferredSource: String?
    /// Optional subtitle file saved beside the video for soft-sub sources.
    public var subtitleFile: String?
    public var bytes: Int64
    public var duration: Double?
    public var createdAt: Date

    public init(media: Media, episode: Int, audio: AudioTrack, episodeTitle: String? = nil, thumbnail: URL? = nil, createdAt: Date = Date()) {
        self.media = media
        self.episode = episode
        self.audio = audio
        self.episodeTitle = episodeTitle
        self.thumbnail = thumbnail
        self.state = .queued
        self.subtitleFile = nil
        self.bytes = 0
        self.createdAt = createdAt
    }

    public static func id(mediaID: Int, episode: Int, audio: AudioTrack) -> String { "\(mediaID)-\(episode)-\(audio.rawValue)" }
    public var id: String { Self.id(mediaID: media.id, episode: episode, audio: audio) }
    /// The folder name under the downloads directory.
    public var folder: String { id }
    /// The file to play, relative to `folder`.
    public var entryFile: String? {
        switch kind {
        case .hls?: return "index.m3u8"
        case .mp4?: return "episode.mp4"
        case nil: return nil
        }
    }

    public var isDone: Bool { state == .done }
}

/// The downloads, grouped and counted as the Downloads tab shows them.
public enum DownloadQueue {
    /// Android saves two episodes at a time.
    public static let concurrent = 2

    /// The queued records to start now, oldest first, so at most `concurrent` run.
    public static func next(_ records: [DownloadRecord], running: Set<String>) -> [DownloadRecord] {
        let free = concurrent - running.count
        guard free > 0 else { return [] }
        return records
            .filter { $0.state == .queued && !running.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(free)
            .map { $0 }
    }

    /// The batch download's menu item. Sub and dub sources can both be saved; soft-sub sources
    /// carry their selected subtitle beside the video.
    public static func batchLabel(count: Int, audio: AudioTrack) -> String {
        "Download \(count) episode\(count == 1 ? "" : "s") (\(audio.label))"
    }

    /// The servers a download tries, in order: the saveable ones, the one the viewer picked first.
    /// The rest stay behind it, so a pick that has stopped answering still gets the episode saved.
    public static func attempts(_ sources: [VideoSource], preferring label: String?) -> [VideoSource] {
        let saveable = sources.filter(ServerSummary.canDownload)
        // The episode-row download button has no server picker. Prefer Arabic soft subtitles,
        // then any soft subtitles, then a stream that can be saved without sidecar captions. HLS
        // is preferred over a direct MP4 because it preserves adaptive quality selection.
        let ranked = saveable.enumerated().sorted { left, right in
            let l = downloadScore(left.element)
            let r = downloadScore(right.element)
            return l == r ? left.offset < right.offset : l > r
        }.map(\.element)
        guard let label, let index = ranked.firstIndex(where: { $0.label == label }) else { return ranked }
        var rest = ranked
        let picked = rest.remove(at: index)
        return [picked] + rest
    }

    private static func downloadScore(_ source: VideoSource) -> Int {
        let arabic = source.subtitles.contains {
            $0.language.lowercased().hasPrefix("ar")
                || $0.label.localizedCaseInsensitiveContains("arab")
                || $0.label.contains("عرب")
        }
        let captions = source.softSub && !source.subtitles.isEmpty
        return (arabic ? 100 : captions ? 70 : 0) + (source.kind == .hls ? 10 : 0)
    }

    public struct Series: Identifiable, Sendable {
        public var media: Media
        public var episodes: [DownloadRecord]
        public var id: Int { media.id }
        public var bytes: Int64 { episodes.reduce(0) { $0 + $1.bytes } }
        public var activeCount: Int { episodes.filter(\.state.isActive).count }
        public var doneCount: Int { episodes.filter(\.isDone).count }
        public var latest: Date { episodes.map(\.createdAt).max() ?? .distantPast }
    }

    /// One entry per show, the most recently added first, episodes in order.
    public static func series(_ records: [DownloadRecord]) -> [Series] {
        Dictionary(grouping: records, by: \.media.id).values
            .map { group in
                let sorted = group.sorted { ($0.episode, $0.audio.rawValue) < ($1.episode, $1.audio.rawValue) }
                return Series(media: sorted.last!.media, episodes: sorted)
            }
            .sorted { $0.latest > $1.latest }
    }

    /// "1.4 GB", "820 MB".
    public static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}
