import Foundation

/// Every provider the app asks, in preference order, asked together.
///
/// The order is the Android app's (`ProviderCatalog.defaultPriority`, then its fast servers, then
/// the rest): Miruro leads, with sub and dub across several servers, episode titles, stills and
/// skip times, and AniChan follows on an independent backend so a bad day for one isn't a bad day
/// for both. AniKoto (MegaPlay) is its third default; Ani.pm and Zoko are its fast servers; AnimeHeaven, a hard-subbed MP4 fallback, comes
/// later. The web-player servers (RareAnimes, AnimeDekho, ToonHub, AnimeKhor) are asked too, and
/// their pages follow every stream the app plays itself. Lili (Android's fifth default) is ported but left out: its file host answered 401 to the
/// media index's URLs and to the ones the site's own pages name (2026-10-12).
///
/// The adult-only servers (Hentai Haven, hstream, hanime) are asked only for an adult title, ahead of
/// the rest there, and only while "Hide adult content" is off.
///
/// Every provider is asked at once, and each has `timeout` to answer: one slow site mustn't hold
/// the episode list or the player hostage to its stragglers.
public struct SourceHub: Sendable {
    public let providers: [any StreamProvider]

    /// Every provider the app knows, in its own order.
    public static let all: [any StreamProvider] = [
        Miruro(), AniChan(), AniKoto(), AniPm(), Zoko(), RareAnimes(), AniDbApp(), AnimeHeaven(), KickAssAnime(), AnimeKai(), AniZone(), AnimeGG(),
        AnimeDekho(), ToonHub(), UniqueStream(), AnimeKhor(), AnimeAV1(),
        HentaiHaven(), HStream(), Hanime(),
    ]

    /// Whether a provider only ever carries adult material (Android's `ProviderCatalog.isAdultOnly`).
    public static func isAdultOnly(_ id: String) -> Bool { AdultTitles.providerIDs.contains(id) }

    /// The app's "Hide adult content" switch (`hide_adult_content`), on until the viewer turns it off.
    public static var hidesAdult: Bool { UserDefaults.standard.object(forKey: "hide_adult_content") as? Bool ?? true }

    /// How long one provider gets to answer before the rest go ahead without it.
    public static let timeout: Duration = .seconds(15)
    /// How long the others get once the best-ranked useful answer is in.
    public static let grace: Duration = .seconds(2)

    /// The hub as the viewer arranged it in Settings → Servers (Android's `disabled_providers` and
    /// `server_priority`, both comma-separated provider ids), without the adult-only servers while
    /// "Hide adult content" is on.
    public static var shared: SourceHub {
        let defaults = UserDefaults.standard
        let disabled = Set((defaults.string(forKey: "disabled_providers") ?? "").split(separator: ",").map(String.init))
        let priority = (defaults.string(forKey: "server_priority") ?? "").split(separator: ",").map(String.init)
        return SourceHub(providers: arranged(selectable(hideAdult: hidesAdult), disabled: disabled, priority: priority))
    }

    /// Every provider a viewer can see and pin: the adult-only ones drop out while adult content is
    /// hidden (Android's `ProviderCatalog.selectableProviders`).
    public static func selectable(hideAdult: Bool) -> [any StreamProvider] {
        hideAdult ? all.filter { !isAdultOnly($0.id) } : all
    }

    /// The providers left on, the pinned ones first in the viewer's order, the rest in the app's.
    /// Switching everything off is taken as a mistake: nothing would play.
    public static func arranged(_ providers: [any StreamProvider], disabled: Set<String>, priority: [String]) -> [any StreamProvider] {
        let enabled = providers.filter { !disabled.contains($0.id) }
        guard !enabled.isEmpty else { return providers }
        let pinned = priority.compactMap { id in enabled.first { $0.id == id } }
        return pinned + enabled.filter { provider in !pinned.contains { $0.id == provider.id } }
    }

    public init(providers: [any StreamProvider]) {
        self.providers = providers
    }

    /// The providers worth asking about `media`, in the order they're tried. An adult-only server
    /// is asked only for an adult title: everything it has is adult, so a general title matching one
    /// by name is a matcher accident, and a wrong hentai match is worse than none. For an adult title
    /// they lead instead, so the wait for the first useful answer includes them (a general server's
    /// quick, mismatched listing mustn't start the grace period that leaves them behind) and their
    /// streams are tried first.
    func providers(for media: Media) -> [any StreamProvider] {
        let adult = providers.filter { Self.isAdultOnly($0.id) }
        let general = providers.filter { !Self.isAdultOnly($0.id) }
        return media.isAdult == true ? adult + general : general
    }

    /// The first provider's listing with whatever the others add merged in. Throws only when no
    /// provider answered at all.
    public func episodes(for media: Media) async throws -> EpisodeListing {
        let asked = providers(for: media)
        let results = await askAll(asked, useful: { !$0.isEmpty }) { try await $0.episodes(for: media) }
        logResults(asked, "episodes for \(media.id)", results) { "\($0.episodes.count) (\($0.dubbed.count) dub)" }
        var merged: EpisodeListing?
        for listing in Self.counted(media, Array(zip(asked.map(\.id), results))) {
            if merged == nil { merged = listing } else { merged?.merge(listing) }
        }
        if let merged { return merged }
        if let failure = Self.firstFailure(results), !results.contains(where: Self.succeeded) { throw failure }
        return .empty
    }

    /// The listings an episode list is built from, in provider order. For an adult title AniList
    /// can't count (`Media.episodeCountUnknown`: nearly every running hentai OVA series), only the
    /// adult-only servers are counted when any of them has it, after Android's 97fadd44: a general
    /// server's matcher once paired Imaizumin-chi (132203) with Super GALS! Kotobuki Ran and listed
    /// 50 episodes beside the adult servers' six, and a plain union put 50 rows on the page. A title
    /// AniList does count keeps every server's rows.
    static func counted(_ media: Media, _ results: [(id: String, result: Result<EpisodeListing, any Error>)]) -> [EpisodeListing] {
        let answered = results.compactMap { entry -> (String, EpisodeListing)? in
            guard case .success(let listing) = entry.result, !listing.isEmpty else { return nil }
            return (entry.id, listing)
        }
        let adult = answered.filter { isAdultOnly($0.0) }
        guard media.isAdult == true, media.episodeCountUnknown, !adult.isEmpty else { return answered.map(\.1) }
        return adult.map(\.1)
    }

    /// Every provider's sources for the episode, in provider order, so the player can fail over
    /// from one to the next.
    public func sources(for media: Media, episode: Int, audio: AudioTrack) async throws -> [VideoSource] {
        // Only a stream the app plays itself ends the wait: a player page is the last resort.
        let asked = providers(for: media)
        let results = await askAll(asked, useful: { $0.contains { $0.kind != .embed } }) { try await $0.sources(for: media, episode: episode, audio: audio) }
        logResults(asked, "\(audio.rawValue) sources for \(media.id) ep \(episode)", results) { "\($0.count)" }
        // A server in a declared language leads when the viewer asked for that language and
        // follows everything else when they didn't.
        let wanted = Self.wantedLanguages(audio)
        var leading: [VideoSource] = [], ordinary: [VideoSource] = [], trailing: [VideoSource] = []
        for (provider, result) in zip(asked, results) {
            guard case .success(let found) = result else { continue }
            if let language = provider.declaredLanguage {
                if wanted.contains(language.lowercased()) { leading += found } else { trailing += found }
            } else {
                ordinary += found
            }
        }
        // Player pages come after every stream the app plays itself, as on Android.
        let ranked = leading + ordinary + trailing
        let sources = ranked.filter { $0.kind != .embed } + ranked.filter { $0.kind == .embed }
        if !sources.isEmpty { return sources }
        if let failure = Self.firstFailure(results), !results.contains(where: Self.succeeded) { throw failure }
        throw ProviderError.noStreams(episode: episode, audio: audio)
    }

    /// Every provider's answer, in provider order, without waiting on stragglers: once every
    /// provider ranked above the first useful answer has replied, the rest get `grace` to catch up
    /// and whoever hasn't by then is left out (a hanging site mustn't hold the player for the full
    /// `timeout`). Each provider still has `timeout` at most.
    private func askAll<T: Sendable>(
        _ providers: [any StreamProvider],
        useful: @escaping @Sendable (T) -> Bool,
        _ ask: @escaping @Sendable (any StreamProvider) async throws -> T
    ) async -> [Result<T, any Error>] {
        let timeout = Self.timeout
        let grace = Self.grace
        let count = providers.count
        return await withTaskGroup(of: HubEvent<T>.self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    do {
                        return .answer(index, .success(try await Self.within(timeout, provider.name) { try await ask(provider) }))
                    } catch {
                        return .answer(index, .failure(error))
                    }
                }
            }
            var results = [Result<T, any Error>?](repeating: nil, count: count)
            var graceStarted = false
            while let event = await group.next() {
                switch event {
                case .graceOver:
                    group.cancelAll()
                    return results.map { $0 ?? .failure(HTTPError("left behind: answered later than the others")) }
                case .answer(let index, let result):
                    results[index] = result
                }
                if results.allSatisfy({ $0 != nil }) { break }
                // The leading useful answer, and whether everyone ranked above it has spoken.
                if !graceStarted, let lead = results.firstIndex(where: { if case .success(let value)? = $0 { return useful(value) } else { return false } }),
                   results[..<lead].allSatisfy({ $0 != nil }) {
                    graceStarted = true
                    group.addTask {
                        try? await Task.sleep(for: grace)
                        return .graceOver
                    }
                }
            }
            group.cancelAll()
            return results.map { $0 ?? .failure(CancellationError()) }
        }
    }

    /// The languages Settings asks for, by name: audio for a dub, subtitles for a sub, first and
    /// second choice.
    static func wantedLanguages(_ audio: AudioTrack) -> Set<String> {
        let defaults = UserDefaults.standard
        let keys = audio == .dub ? [TrackLanguage.audioKey, TrackLanguage.secondaryAudioKey] : [TrackLanguage.subtitleKey, TrackLanguage.secondarySubtitleKey]
        let list = audio == .dub ? TrackLanguage.audio : TrackLanguage.subtitles
        return Set(keys.map { TrackLanguage.stored(defaults.string(forKey: $0), in: list) }.filter { !$0.isAutomatic }.map { $0.label.lowercased() })
    }

    /// `work`, or a timeout error once `limit` has passed; the work is cancelled then.
    static func within<T: Sendable>(_ limit: Duration, _ name: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw HTTPError("\(name) didn't answer within \(limit)")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    private func logResults<T>(_ providers: [any StreamProvider], _ what: String, _ results: [Result<T, any Error>], _ summary: (T) -> String) {
        let parts = zip(providers, results).map { provider, result in
            switch result {
            case .success(let value): return "\(provider.id) \(summary(value))"
            case .failure(let error): return "\(provider.id) FAILED (\(Log.describe(error)))"
            }
        }
        Log.info("sources", "\(what): \(parts.joined(separator: "; "))")
    }

    private static func succeeded<T>(_ result: Result<T, any Error>) -> Bool {
        if case .success = result { return true }
        return false
    }

    private static func firstFailure<T>(_ results: [Result<T, any Error>]) -> (any Error)? {
        for case .failure(let error) in results { return error }
        return nil
    }
}

/// One thing `SourceHub.askAll` can hear: a provider's answer, or the grace period ending.
private enum HubEvent<T: Sendable>: Sendable {
    case answer(Int, Result<T, any Error>)
    case graceOver
}
