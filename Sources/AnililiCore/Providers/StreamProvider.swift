import Foundation

/// Which audio the viewer wants. Soft-subbed streams (Miruro's `ssub`) are left out until the
/// player can load their separate subtitle files.
public enum AudioTrack: String, Codable, Sendable, CaseIterable, Identifiable {
    case sub
    case dub

    public var id: String { rawValue }
    public var label: String { self == .sub ? "Sub" : "Dub" }
}

/// Opening and ending windows, in seconds into the episode.
public struct SkipTimes: Hashable, Sendable {
    public struct Window: Hashable, Sendable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }

        public func contains(_ time: Double) -> Bool { time >= start && time < end - 1 }
    }

    public var intro: Window?
    public var outro: Window?

    public init(intro: Window? = nil, outro: Window? = nil) {
        self.intro = intro
        self.outro = outro
    }
}

/// One episode as a provider lists it. Everything but the number is optional: AnimeHeaven knows
/// only numbers, Miruro knows titles, stills, synopses and skip times.
public struct EpisodeInfo: Hashable, Sendable, Identifiable {
    public var number: Int
    public var title: String?
    public var synopsis: String?
    public var thumbnail: URL?
    public var airedOn: String?
    public var duration: Double?
    public var isFiller = false
    public var skip: SkipTimes?

    public var id: Int { number }

    public init(number: Int) {
        self.number = number
    }
}

/// A provider's episodes for one title, and which of them it has in each audio.
public struct EpisodeListing: Sendable, Equatable {
    public var episodes: [EpisodeInfo]
    public var subbed: Set<Int>
    public var dubbed: Set<Int>

    public static let empty = EpisodeListing(episodes: [], subbed: [], dubbed: [])

    public init(episodes: [EpisodeInfo], subbed: Set<Int>, dubbed: Set<Int>) {
        self.episodes = episodes
        self.subbed = subbed
        self.dubbed = dubbed
    }

    public var isEmpty: Bool { episodes.isEmpty }

    public func available(_ audio: AudioTrack) -> [EpisodeInfo] {
        let numbers = audio == .sub ? subbed : dubbed
        return episodes.filter { numbers.contains($0.number) }
    }

    public func episode(_ number: Int) -> EpisodeInfo? {
        episodes.first { $0.number == number }
    }

    /// Adds what `other` knows that this listing doesn't: episodes it lacks, and audio it has.
    /// Metadata already here wins, so the richer provider should be merged into, not from.
    public mutating func merge(_ other: EpisodeListing) {
        let known = Set(episodes.map(\.number))
        episodes += other.episodes.filter { !known.contains($0.number) }
        episodes.sort { $0.number < $1.number }
        subbed.formUnion(other.subbed)
        dubbed.formUnion(other.dubbed)
    }
}

/// A subtitle file a server offers beside its video (soft subs, or captions on a dub).
public struct SubtitleTrack: Hashable, Sendable, Identifiable {
    public var url: URL
    public var label: String
    /// ISO 639-1, as the server names it ("en").
    public var language: String
    public var isDefault: Bool

    public var id: URL { url }

    public init(url: URL, label: String, language: String, isDefault: Bool = false) {
        self.url = url
        self.label = label
        self.language = language
        self.isDefault = isDefault
    }
}

/// One playable file or playlist for an episode.
public struct VideoSource: Hashable, Sendable, Identifiable {
    /// `embed` is a third-party player page rather than a stream: the app shows it in a guarded
    /// web view (Android's `EmbedWebView`), after every stream it can play itself.
    public enum Kind: String, Sendable { case mp4, hls, embed }

    public var url: URL
    /// The site or backend it came from, as the picker groups it.
    public var provider: String
    /// The server or mirror within the provider.
    public var server: String
    public var kind: Kind
    /// Headers the CDN insists on (usually a Referer). Empty means the URL plays bare.
    public var headers: [String: String]
    /// Separate subtitle files; for a soft-sub server, the only subtitles there are.
    public var subtitles: [SubtitleTrack]
    /// The video carries no burned-in subtitles; they come from `subtitles`.
    public var softSub: Bool
    /// For a stream carrying several audio tracks (KickAssAnime's sub and dub are one master), the
    /// track to select, as a language code ("jpn", "eng"); nil plays what the stream picks.
    public var audioLanguage: String?
    /// The AES-128 key for an encrypted stream whose own key URL is gated (UniqueStream's is the
    /// media id as hex bytes): the app's stream proxy answers the playlist's key requests with it.
    public var aesKey: Data?

    public var id: URL { url }
    public var label: String { "\(provider) · \(server)" + (softSub ? " · Soft sub" : "") + (kind == .embed ? " · Web player" : "") }

    public init(url: URL, provider: String, server: String, kind: Kind, headers: [String: String] = [:], subtitles: [SubtitleTrack] = [], softSub: Bool = false, audioLanguage: String? = nil, aesKey: Data? = nil) {
        self.audioLanguage = audioLanguage
        self.aesKey = aesKey
        self.url = url
        self.provider = provider
        self.server = server
        self.kind = kind
        self.headers = headers
        self.subtitles = subtitles
        self.softSub = softSub
    }
}

/// A site that turns an AniList entry into playable episodes.
///
/// The Android app carries a dozen of these; this protocol is the shape they share once the
/// Android-only concerns (cast routing, the export pipeline, TV budgets) are left out. Episode
/// numbers are AniList's, so progress recorded against one provider means the same episode on
/// another.
public protocol StreamProvider: Sendable {
    var id: String { get }
    var name: String { get }

    /// Throws when the site was not reached; returns `.empty` only when it was asked and does not
    /// carry the title.
    func episodes(for media: Media) async throws -> EpisodeListing

    /// Playable sources for one episode, preferred first. Empty when the site has the episode but
    /// not in that audio.
    func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource]

    /// The one language a server's streams are in, for a server that isn't English ("Spanish"):
    /// it plays automatically only for a viewer whose language settings ask for it, and then
    /// first (Android's `ProviderCatalog.declaredLanguage`). Picked by hand, it always plays.
    var declaredLanguage: String? { get }
}

extension StreamProvider {
    public var declaredLanguage: String? { nil }
}

public enum ProviderError: LocalizedError, Sendable {
    case titleNotFound(provider: String)
    case episodeNotFound(provider: String, episode: Int)
    case noStreams(episode: Int, audio: AudioTrack)

    public var errorDescription: String? {
        switch self {
        case .titleNotFound(let provider):
            return "\(provider) doesn't have this title."
        case .episodeNotFound(let provider, let episode):
            return "\(provider) doesn't have episode \(episode)."
        case .noStreams(let episode, let audio):
            return "No \(audio.label.lowercased()) video was found for episode \(episode)."
        }
    }
}
