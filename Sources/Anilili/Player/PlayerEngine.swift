#if canImport(UIKit)
import AVFoundation
import AnililiCore
import MediaPlayer
import Observation
import SwiftUI

/// What the player is asked to open. Carries the listing so it can move between episodes and
/// find each one's skip times.
struct PlayRequest: Identifiable, Hashable {
    var media: Media
    var episode: Int
    var audio: AudioTrack
    var listing: EpisodeListing
    /// Where to start, when a link says (`anilili://watch/…?t=`); otherwise the saved position.
    var start: Double? = nil

    var id: String { "\(media.id)-\(episode)-\(audio.rawValue)" }

    var available: [Int] { listing.available(audio).map(\.number) }
    var nextEpisode: Int? { available.first { $0 > episode } }
    var previousEpisode: Int? { available.last { $0 < episode } }
    var info: EpisodeInfo? { listing.episode(episode) }

    static func == (lhs: PlayRequest, rhs: PlayRequest) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The player's brain: resolves sources and fails over between them, keeps time, subtitles,
/// quality, speed, skips and the next-episode countdown, saves progress, and logs everything
/// AVFoundation says about why a stream won't play. The views only draw it.
@MainActor
@Observable
final class PlayerEngine {
    enum Phase: Equatable {
        case resolving
        case loading
        case ready
        case failed(String)
    }

    struct Attempt: Identifiable {
        let id = UUID()
        let source: VideoSource
        var outcome: String
    }

    /// A skip on offer: the intro or outro window, or the fixed-length fallback.
    struct SkipOffer: Equatable {
        var label: String
        var target: Double
        var isWindow: Bool
        /// Shown over the bare picture, not only with the controls: the credits for all of their
        /// window, the opening for its pop-up (`PlaybackPolicy.skipPopupSeconds`).
        var floats = false
    }

    let player = AVPlayer()
    private(set) var phase: Phase = .resolving
    private(set) var status = "Finding a stream…"
    private(set) var sources: [VideoSource] = []
    private(set) var current: VideoSource?
    private(set) var attempts: [Attempt] = []
    private(set) var lastEvent: String?

    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var buffered: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var speed: Float = 1

    private(set) var skipTimes: SkipTimes?
    private(set) var skipOffer: SkipOffer?
    /// Seconds left before an auto-skip happens, while one is counting down.
    private(set) var autoSkipCountdown: Int?
    /// Seconds left before the next episode plays, while the card is up.
    private(set) var nextCountdown: Int?

    private(set) var subtitleTracks: [SubtitleTrack] = []
    private(set) var selectedSubtitle: SubtitleTrack?
    private(set) var subtitleText: String?
    var subtitleDelay: Double = 0
    private(set) var variants: [HLSPlaylist.Variant] = []
    private(set) var maxHeight: Int?
    private(set) var pausedSince: Date?
    /// The player page showing instead of AVPlayer, when the current source is an embed: the
    /// watch page draws it in a guarded web view, which reports its time back here.
    private(set) var embed: VideoSource?

    @ObservationIgnored private(set) var request: PlayRequest?
    @ObservationIgnored private var cues: [SubtitleCue] = []
    @ObservationIgnored private var settings = Settings()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var keyValueObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var loadTimeout: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var seekTarget: Double?
    @ObservationIgnored private var stallSince: Date?
    @ObservationIgnored private var stallPosition: Double = -1
    @ObservationIgnored private var nudged = false
    @ObservationIgnored private var pendingSeek: Double = 0
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var skippedWindows: Set<Double> = []
    /// The window whose pop-up is running, and how long has played inside it.
    @ObservationIgnored private var popupWindow: Double?
    @ObservationIgnored private var popupPlayed: Double = 0
    @ObservationIgnored private var countdownPlayed: Double = 0
    @ObservationIgnored private var nextRefused = false
    @ObservationIgnored private var lastTick: Double = 0
    /// Set once the viewer picks a quality, which then holds over Settings' default.
    @ObservationIgnored private var viewerPickedQuality = false
    /// Whether the item playing now was opened through `StreamProxy`.
    @ObservationIgnored private var proxiedAttempt = false
    /// The online servers are still being found behind a downloaded copy that's already playing.
    @ObservationIgnored private var onlinePending = false
    /// The downloaded copy failed before they were found, so the first of them plays when they are.
    @ObservationIgnored private var waitingForOnline = false
    /// The show's poster for the lock screen and Control Center, once `ImagePipeline` has it.
    @ObservationIgnored private var artwork: (url: URL, art: MPMediaItemArtwork)?
    @ObservationIgnored private var artworkLoad: Task<Void, Never>?
    @ObservationIgnored var onProgress: ((Double, Double) -> Void)?
    @ObservationIgnored var onNextEpisode: (() -> Void)?

    /// The preferences the engine reads, taken when an episode opens.
    struct Settings {
        var autoSkip = false
        var autoplay = true
        var subtitlesByDefault = true
        var subtitlesWithDub = false
        /// Preferred, then second choice; Automatic entries are skipped.
        var subtitleLanguages: [TrackLanguage] = []
        var audioLanguages: [TrackLanguage] = []
        var skipSeconds = PlaybackPolicy.manualSkipSeconds
        var defaultQuality = DefaultQuality.fallback
        var buffer = PlaybackBufferSize.automatic
    }

    static let startTimeout: Duration = .seconds(20)
    static let stallLimit: TimeInterval = 15

    // MARK: - Opening

    /// `lastResort` is a saved copy in the other audio, played when no server can be reached.
    func open(_ request: PlayRequest, startAt: Double, settings: Settings, offline: VideoSource? = nil, lastResort: VideoSource? = nil) async {
        saveProgress(force: true)
        detach()
        player.replaceCurrentItem(with: nil)
        self.request = request
        self.settings = settings
        phase = .resolving
        status = "Finding a stream…"
        sources = []
        current = nil
        attempts = []
        lastEvent = nil
        position = 0
        duration = 0
        buffered = 0
        skipTimes = request.info?.skip
        skipOffer = nil
        autoSkipCountdown = nil
        nextCountdown = nil
        nextRefused = false
        skippedWindows = []
        popupWindow = nil
        subtitleTracks = []
        selectedSubtitle = nil
        subtitleText = nil
        cues = []
        variants = []
        maxHeight = nil
        viewerPickedQuality = false
        pendingSeek = startAt
        onlinePending = false
        waitingForOnline = false
        Log.info("player", "open \(request.media.id) \"\(request.media.title.preferred)\" ep \(request.episode) \(request.audio.rawValue), resume at \(Self.clock(startAt)), skip \(skipTimes.map(String.init(describing:)) ?? "none")")
        loadArtwork(for: request)
        updateNowPlaying()
        if let offline {
            // The saved copy plays at once; the online servers join behind it as failover.
            Log.info("player", "playing the downloaded copy: \(offline.label)")
            sources = [offline]
            onlinePending = true
            play(offline)
            let online = (try? await SourceHub.shared.sources(for: request.media, episode: request.episode, audio: request.audio)) ?? []
            guard self.request?.id == request.id else { return }
            onlinePending = false
            sources += online
            if waitingForOnline {
                waitingForOnline = false
                if let first = online.first {
                    play(first)
                } else {
                    phase = .failed("None of the \(sources.count) servers would play this episode.")
                }
            }
            return
        }
        do {
            let resolved = try await SourceHub.shared.sources(for: request.media, episode: request.episode, audio: request.audio)
            guard !Task.isCancelled else { return }
            sources = resolved
            Log.info("player", "\(resolved.count) sources: \(resolved.map(\.label).joined(separator: ", "))")
            play(resolved[0])
        } catch {
            guard !Task.isCancelled else { return }
            Log.error("player", "no sources: \(Log.describe(error))")
            if let lastResort {
                Log.info("player", "playing the downloaded copy in the other audio: \(lastResort.label)")
                sources = [lastResort]
                play(lastResort)
                return
            }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Manual server switch: keeps the position the viewer was at.
    func switchTo(_ source: VideoSource) {
        Log.info("player", "viewer switched to \(source.label)")
        rememberPosition()
        play(source)
    }

    func stop() {
        if embed != nil, duration > 0, position > 0 { onProgress?(position, duration) }
        saveProgress(force: true)
        player.pause()
        detach()
        artworkLoad?.cancel()
        artworkLoad = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UsageReporter.playing(false)
    }

    // MARK: - Transport

    func togglePlay() {
        if player.timeControlStatus == .paused {
            if duration > 0, position >= duration - 0.5 { seek(to: 0, why: "restart") }
            player.playImmediately(atRate: speed)
        } else {
            player.pause()
        }
    }

    func seek(by seconds: Double) {
        let target = min(max(0, (seekTarget ?? position) + seconds), duration > 0 ? duration - 0.5 : .greatestFiniteMagnitude)
        seek(to: target, why: seconds > 0 ? "+\(Int(seconds))s" : "\(Int(seconds))s")
    }

    func setSpeed(_ rate: Float) {
        speed = rate
        player.defaultRate = rate
        if player.timeControlStatus != .paused { player.rate = rate }
        Log.info("player", "speed \(rate)x")
        updateNowPlaying()
    }

    /// Holding the screen plays at `rate` until released (Android's hold-to-speed).
    func holdSpeed(_ rate: Float?) {
        if let rate {
            if player.timeControlStatus != .paused { player.rate = rate }
        } else if player.timeControlStatus != .paused {
            player.rate = speed
        }
    }

    func setQuality(_ height: Int?) {
        viewerPickedQuality = true
        applyQuality(height)
    }

    private func applyQuality(_ height: Int?) {
        maxHeight = height
        player.currentItem?.preferredMaximumResolution = height.map { CGSize(width: Double($0) * 16 / 9, height: Double($0)) } ?? .zero
        Log.info("player", "quality \(height.map { "\($0)p max" } ?? "auto")")
    }

    func takeSkip() {
        guard let offer = skipOffer else { return }
        autoSkipCountdown = nil
        if offer.isWindow, let start = activeWindow?.start { skippedWindows.insert(start) }
        seek(to: offer.target, why: offer.label)
        skipOffer = nil
    }

    func cancelAutoSkip() {
        if let start = activeWindow?.start { skippedWindows.insert(start) }
        autoSkipCountdown = nil
        Log.info("player", "auto-skip cancelled")
    }

    func playNext() {
        nextCountdown = nil
        nextRefused = true
        saveProgress(force: true)
        onNextEpisode?()
    }

    func refuseNext() {
        nextCountdown = nil
        nextRefused = true
        Log.info("player", "next episode refused")
    }

    // MARK: - Subtitles

    func selectSubtitle(_ track: SubtitleTrack?) {
        selectedSubtitle = track
        cues = []
        subtitleText = nil
        guard let track, let source = current else {
            Log.info("player", "subtitles off")
            return
        }
        Task {
            do {
                let loaded = try await Subtitles.load(track, headers: source.headers)
                guard self.selectedSubtitle == track else { return }
                self.cues = loaded
            } catch {
                Log.error("subtitles", "\(track.label) failed: \(Log.describe(error))")
                self.lastEvent = "Subtitles failed: \(error.localizedDescription)"
            }
        }
    }

    func nudgeSubtitles(by seconds: Double) {
        subtitleDelay = ((subtitleDelay + seconds) * 10).rounded() / 10
        Log.info("subtitles", "delay \(subtitleDelay)s")
    }

    // MARK: - Playback

    private func play(_ source: VideoSource, direct: Bool = false) {
        detach()
        waitingForOnline = false
        if source.kind == .embed {
            showEmbed(source)
            return
        }
        embed = nil
        current = source
        phase = .loading
        status = "Loading \(source.label)…"
        attempts.append(Attempt(source: source, outcome: "loading"))
        // Online HLS goes through the on-device proxy (`StreamProxy`): it carries the headers to
        // every request, unwraps segments dressed as images and writes out Kwik's IVs. A source
        // that fails through it is tried once directly before the next server.
        let proxied = source.kind == .hls && !direct && source.url.host != "127.0.0.1"
            ? StreamProxy.shared.address(for: source.url, headers: source.headers, key: source.aesKey) : nil
        proxiedAttempt = proxied != nil
        Log.info("player", "trying \(source.label) [\(source.kind.rawValue)]\(proxied != nil ? " via the proxy" : direct ? " directly" : "") \(source.url.absoluteString) headers: \(source.headers)")

        var options: [String: Any] = [AVURLAssetHTTPUserAgentKey: HTTP.safariUserAgent]
        if proxied == nil, !source.headers.isEmpty {
            // Not a published constant, but the long-standing way to send headers with an asset;
            // AVFoundation applies them to the playlists, keys and segments it fetches.
            options["AVURLAssetHTTPHeaderFieldsKey"] = source.headers
        }
        if source.kind == .hls {
            // Miruro's playlist URLs rarely end in .m3u8 and are often served as text/plain or
            // octet-stream, which AVFoundation would not recognise as HLS on its own.
            options[AVURLAssetOverrideMIMETypeKey] = "application/vnd.apple.mpegurl"
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: proxied ?? source.url, options: options))
        if let maxHeight { item.preferredMaximumResolution = CGSize(width: Double(maxHeight) * 16 / 9, height: Double(maxHeight)) }
        // Settings → Player → Buffer size; 0 leaves it to AVFoundation.
        item.preferredForwardBufferDuration = settings.buffer.seconds
        player.replaceCurrentItem(with: item)
        player.defaultRate = speed
        observe(item, source: source)
        player.playImmediately(atRate: speed)
        prepareSubtitles(for: source)
        if source.kind == .hls {
            Task {
                let found = (try? await HLSPlaylist.load(source.url, headers: source.headers)) ?? []
                guard self.current == source else { return }
                self.variants = found
                // Settings → Player → Default quality, until the viewer picks one themselves.
                if !self.viewerPickedQuality, let height = self.settings.defaultQuality.pickHeight(found.compactMap(\.height)) {
                    Log.info("player", "default quality \(self.settings.defaultQuality.label): capped at \(height)p")
                    self.applyQuality(height)
                }
            }
        }

        loadTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.startTimeout)
            guard !Task.isCancelled, let self, self.current == source, item.status != .readyToPlay else { return }
            self.fail(source, "didn't start within \(Self.startTimeout)")
        }
    }

    /// Turns subtitles on for a soft-sub server (or a dub, when Settings asks), in the preferred
    /// language when the server has it.
    private func prepareSubtitles(for source: VideoSource) {
        subtitleTracks = source.subtitles
        let wanted = source.softSub ? settings.subtitlesByDefault : (settings.subtitlesWithDub && request?.audio == .dub)
        guard wanted, !source.subtitles.isEmpty else {
            if selectedSubtitle != nil { selectSubtitle(nil) }
            return
        }
        // The preferred language, then the second choice; Automatic keeps the server's own pick.
        let pick = TrackLanguage.pick(source.subtitles, preferences: settings.subtitleLanguages) { $0.language }
            ?? TrackLanguage.pick(source.subtitles, preferences: settings.subtitleLanguages) { $0.label }
            ?? source.subtitles.first(where: \.isDefault)
            ?? source.subtitles.first
        selectSubtitle(pick)
    }

    private func observe(_ item: AVPlayerItem, source: VideoSource) {
        keyValueObservations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error.map(Log.describe)
            Task { @MainActor in self?.itemStatusChanged(status, error: error, source: source) }
        })
        keyValueObservations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            let reason = player.reasonForWaitingToPlay?.rawValue
            Task { @MainActor in self?.timeControlChanged(status, reason: reason) }
        })
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { [weak self] _ in
            guard let event = item.errorLog()?.events.last else { return }
            let line = "error log: \(event.errorStatusCode) \(event.errorDomain) \(event.errorComment ?? "") uri=\(Log.short(event.uri.flatMap(URL.init(string:))))"
            MainActor.assumeIsolated {
                self?.lastEvent = line
                Log.warning("player", "\(source.label) \(line)")
            }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.newAccessLogEntryNotification, object: item, queue: .main) { [weak self] _ in
            guard let event = item.accessLog()?.events.last else { return }
            let line = String(format: "access: %.0f kbps indicated, %.0f observed, stalls %ld", event.indicatedBitrate / 1000, event.observedBitrate / 1000, event.numberOfStalls)
            MainActor.assumeIsolated {
                self?.lastEvent = line
                Log.debug("player", "\(source.label) \(line)")
            }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { _ in
            MainActor.assumeIsolated { Log.warning("player", "\(source.label) stalled") }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let error = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error).map(Log.describe) ?? "unknown"
            MainActor.assumeIsolated { self?.fail(source, "stopped mid-way: \(error)") }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.info("player", "\(source.label) played to the end")
                self.saveProgress(force: true)
                if self.settings.autoplay, !self.nextRefused, self.request?.nextEpisode != nil { self.playNext() }
            }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: String?, source: VideoSource) {
        guard source == current else { return }
        switch status {
        case .readyToPlay:
            loadTimeout?.cancel()
            let length = player.currentItem?.duration.seconds ?? .nan
            duration = length.isFinite ? length : 0
            Log.info("player", "\(source.label) ready, duration \(duration > 0 ? Self.clock(duration) : "unknown")")
            setOutcome(source, "played")
            phase = .ready
            markShowing(source)
            if pendingSeek > 0 {
                seek(to: pendingSeek, why: "resume")
                pendingSeek = 0
            }
            startWatchdog(for: source)
            if skipTimes == nil { Task { await fetchSkipTimes() } }
            if let item = player.currentItem { Task { await applyAudioLanguage(item, source: source) } }
            updateNowPlaying()
        case .failed:
            fail(source, error ?? "AVPlayerItem failed without an error")
        default:
            break
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus, reason: String?) {
        isPlaying = status == .playing
        UsageReporter.playing(isPlaying)
        isBuffering = status == .waitingToPlayAtSpecifiedRate
        switch status {
        case .waitingToPlayAtSpecifiedRate:
            self.status = "Buffering…"
            pausedSince = nil
            Log.debug("player", "waiting: \(reason ?? "?")")
        case .playing:
            pausedSince = nil
            if let current { markShowing(current) }
        case .paused:
            pausedSince = Date()
        @unknown default:
            break
        }
        updateNowPlaying()
    }

    /// Settings → Player → Preferred audio language and Second choice audio, for a stream that
    /// carries several dubs; one that carries a single track is left alone.
    private func applyAudioLanguage(_ item: AVPlayerItem, source: VideoSource) async {
        // A stream that is sub and dub at once names the track the request was for; that comes
        // before the viewer's general language preferences.
        let wanted = source.audioLanguage.map { TrackLanguage.stored($0, in: TrackLanguage.audio) }.flatMap { $0.isAutomatic ? nil : $0 }
        let preferences = (wanted.map { [$0] } ?? []) + settings.audioLanguages.filter { !$0.isAutomatic }
        guard !preferences.isEmpty,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
              group.options.count > 1, current == source else { return }
        let tag: (AVMediaSelectionOption) -> String? = { $0.extendedLanguageTag ?? $0.locale?.identifier ?? $0.displayName }
        guard let option = TrackLanguage.pick(group.options, preferences: preferences, tag: tag)
            ?? TrackLanguage.pick(group.options, preferences: preferences, tag: { $0.displayName }) else {
            Log.info("player", "audio: none of \(group.options.map(\.displayName)) is \(preferences.map(\.label).joined(separator: " or "))")
            return
        }
        item.select(option, in: group)
        Log.info("player", "audio: \(option.displayName) (preferred \(preferences.map(\.label).joined(separator: ", ")))")
    }

    /// An embed has no stream for AVPlayer: the web view plays the page, and there's no failure
    /// the app can see, so failover stops here until the viewer picks another server.
    private func showEmbed(_ source: VideoSource) {
        player.replaceCurrentItem(with: nil)
        current = source
        embed = source
        attempts.append(Attempt(source: source, outcome: "played"))
        phase = .ready
        status = source.label
        position = 0
        duration = 0
        subtitleTracks = []
        selectedSubtitle = nil
        subtitleText = nil
        variants = []
        Log.info("player", "showing \(source.label) in the web player: \(source.url.absoluteString)")
    }

    /// The web player's clock, once a second: progress is saved from it as from AVPlayer's.
    func embedTick(position: Double, duration: Double, playing: Bool) {
        guard embed != nil, position.isFinite, duration.isFinite, duration > 0 else { return }
        self.position = position
        self.duration = duration
        isPlaying = playing
        if Date().timeIntervalSince(lastSave) >= 5, position > 0 {
            lastSave = Date()
            onProgress?(position, duration)
        }
    }

    /// The page's video reached its end: saved as finished, and on to the next episode as with
    /// AVPlayer when Autoplay is on.
    func embedEnded() {
        guard let source = embed else { return }
        Log.info("player", "\(source.label) played to the end")
        if duration > 0 { onProgress?(duration, duration) }
        if settings.autoplay, !nextRefused, request?.nextEpisode != nil { playNext() }
    }

    private func markShowing(_ source: VideoSource) {
        status = source.label
    }

    private func fetchSkipTimes() async {
        guard let request, duration > 0 else { return }
        let found = await SkipTimesService.shared.skipTimes(anilistID: request.media.id, malID: request.media.idMal, episode: request.episode, length: duration)
        if self.request?.id == request.id, let found { skipTimes = found }
    }

    /// Records why `source` didn't play and moves to the next one; only when every source has
    /// failed is it the viewer's problem.
    private func fail(_ source: VideoSource, _ reason: String) {
        guard source == current else { return }
        loadTimeout?.cancel()
        Log.error("player", "\(source.label) failed: \(reason)")
        setOutcome(source, reason)
        rememberPosition()
        if proxiedAttempt {
            Log.info("player", "\(source.label) failed through the proxy; trying it directly")
            play(source, direct: true)
            return
        }
        if let index = sources.firstIndex(of: source), index + 1 < sources.count {
            play(sources[index + 1])
        } else if onlinePending {
            // A broken saved copy fails in a moment, before the servers behind it are known.
            Log.info("player", "\(source.label) failed; waiting for the online servers")
            detach()
            player.replaceCurrentItem(with: nil)
            current = nil
            waitingForOnline = true
            phase = .resolving
            status = "Finding a stream…"
        } else {
            detach()
            player.replaceCurrentItem(with: nil)
            current = nil
            phase = .failed("None of the \(sources.count) servers would play this episode.")
        }
    }

    private func setOutcome(_ source: VideoSource, _ outcome: String) {
        if let index = attempts.lastIndex(where: { $0.source == source }) { attempts[index].outcome = outcome }
    }

    private func rememberPosition() {
        let at = seekTarget ?? player.currentTime().seconds
        if at.isFinite, at > 1 { pendingSeek = at }
    }

    /// Every seek goes through here, so the log says where it was headed and whether it landed.
    func seek(to seconds: Double, why: String) {
        let from = player.currentTime().seconds
        seekTarget = seconds
        stallSince = nil
        position = seconds
        Log.info("player", "seek \(why): \(Self.clock(from)) → \(Self.clock(seconds))")
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                if finished {
                    self.seekTarget = nil
                    Log.debug("player", "seek \(why) landed at \(Self.clock(self.player.currentTime().seconds))")
                } else {
                    Log.debug("player", "seek \(why) to \(Self.clock(seconds)) was superseded")
                }
            }
        }
    }

    // MARK: - Every tick

    private func tick(_ time: Double) {
        guard time.isFinite else { return }
        let played = max(0, time - lastTick)
        lastTick = time
        if seekTarget == nil { position = time }
        if let item = player.currentItem {
            let length = item.duration.seconds
            if length.isFinite, length > 0 { duration = length }
            buffered = item.loadedTimeRanges.map(\.timeRangeValue).first { $0.containsTime(CMTime(seconds: time, preferredTimescale: 600)) }.map { $0.end.seconds } ?? buffered
        }
        subtitleText = cues.isEmpty ? nil : Subtitles.text(at: time, in: cues, delay: subtitleDelay)
        updateSkip(time, played: played)
        updateNext(time, played: played)
        saveProgress(force: false)
    }

    private var activeWindow: SkipTimes.Window? {
        guard let times = skipTimes else { return nil }
        if let intro = times.intro, intro.contains(position) { return intro }
        if let outro = times.outro, PlaybackPolicy.outroIsCredits(outro, duration: duration), outro.contains(position) { return outro }
        return nil
    }

    private func updateSkip(_ time: Double, played: Double) {
        guard let times = skipTimes else {
            // No timings: the fixed-length skip (Settings → Player → Skip button length), offered
            // across the episode (the controls decide when it shows).
            let target = min(time + Double(settings.skipSeconds), max(0, duration - 1))
            skipOffer = duration > 0 ? SkipOffer(label: "+\(settings.skipSeconds)s", target: target, isWindow: false) : nil
            return
        }
        let window: SkipTimes.Window?
        let label: String
        if let intro = times.intro, intro.contains(time) {
            window = intro
            label = "Skip Intro"
        } else if let outro = times.outro, PlaybackPolicy.outroIsCredits(outro, duration: duration), outro.contains(time) {
            window = outro
            label = "Skip Outro"
        } else {
            window = nil
            label = ""
        }
        guard let window else {
            skipOffer = nil
            autoSkipCountdown = nil
            popupWindow = nil
            return
        }
        if popupWindow != window.start {
            popupWindow = window.start
            popupPlayed = 0
        } else {
            // Capped: a seek reads as one long step, and a resume seek into the opening would
            // otherwise use the pop-up up before it is seen. A tick is a quarter second.
            popupPlayed += min(played, 1)
        }
        let target = duration > 0 ? min(window.end, duration - 0.5) : window.end
        let floats = window != times.intro || popupPlayed < PlaybackPolicy.skipPopupSeconds
        skipOffer = SkipOffer(label: label, target: target, isWindow: true, floats: floats)
        guard settings.autoSkip, !skippedWindows.contains(window.start) else { return }
        // The countdown runs in played time, so a pause holds it.
        if autoSkipCountdown == nil {
            autoSkipCountdown = PlaybackPolicy.autoSkipCountdown
            countdownPlayed = 0
        } else {
            countdownPlayed += played
            let left = PlaybackPolicy.autoSkipCountdown - Int(countdownPlayed)
            if left <= 0 {
                Log.info("player", "auto-skipped \(label)")
                takeSkip()
            } else {
                autoSkipCountdown = left
            }
        }
    }

    private func updateNext(_ time: Double, played: Double) {
        guard settings.autoplay, !nextRefused, request?.nextEpisode != nil else {
            nextCountdown = nil
            return
        }
        let trigger = PlaybackPolicy.nextTrigger(position: time, duration: duration, outro: skipTimes?.outro)
        guard trigger != .none, player.timeControlStatus == .playing || nextCountdown != nil else {
            if trigger == .none { nextCountdown = nil }
            return
        }
        if nextCountdown == nil {
            nextCountdown = PlaybackPolicy.nextEpisodeCountdown
            countdownPlayed = 0
            Log.info("player", "next episode card (\(trigger))")
        } else {
            countdownPlayed += played
            let left = PlaybackPolicy.nextEpisodeCountdown - Int(countdownPlayed)
            if left <= 0 { playNext() } else { nextCountdown = left }
        }
    }

    private func saveProgress(force: Bool) {
        guard force || Date().timeIntervalSince(lastSave) >= 5 else { return }
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let at = player.currentTime().seconds
        let length = item.duration.seconds
        guard at.isFinite, length.isFinite, length > 0, at > 0 else { return }
        lastSave = Date()
        onProgress?(at, length)
    }

    // MARK: - Stall watchdog

    /// Checks once a second that a playing item's clock moves. AVPlayer can sit in
    /// waitingToPlay forever after a seek with segments downloading and nothing decoding (the
    /// black screen of 2026-10-12), and no AVFoundation error ever says so. After `stallLimit`
    /// it re-seeks once; if that doesn't help either, the server counts as failed.
    private func startWatchdog(for source: VideoSource) {
        watchdog?.cancel()
        stallSince = nil
        nudged = false
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.checkProgress(source)
            }
        }
    }

    private func checkProgress(_ source: VideoSource) {
        guard source == current, let item = player.currentItem, item.status == .readyToPlay else { return }
        let at = player.currentTime().seconds
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate, at.isFinite else {
            stallSince = nil
            nudged = false
            return
        }
        if stallSince == nil || abs(at - stallPosition) > 0.25 {
            stallSince = Date()
            stallPosition = at
            return
        }
        let stalled = Date().timeIntervalSince(stallSince ?? Date())
        guard stalled >= Self.stallLimit else { return }
        let state = "buffer empty \(item.isPlaybackBufferEmpty), likely to keep up \(item.isPlaybackLikelyToKeepUp), loaded \(Self.loadedRanges(item)), reason \(player.reasonForWaitingToPlay?.rawValue ?? "?")"
        if !nudged {
            nudged = true
            Log.warning("player", "\(source.label) stuck \(Int(stalled))s at \(Self.clock(at)) (\(state)); re-seeking once")
            seek(to: (seekTarget ?? at) + 0.1, why: "unstick")
            stallSince = Date()
        } else {
            fail(source, "stuck at \(Self.clock(seekTarget ?? at)) for \(Int(Self.stallLimit * 2))s with nothing decoding (\(state))")
        }
    }

    private func detach() {
        loadTimeout?.cancel()
        loadTimeout = nil
        watchdog?.cancel()
        watchdog = nil
        stallSince = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        keyValueObservations.forEach { $0.invalidate() }
        keyValueObservations = []
    }

    // MARK: - Lock screen

    private func updateNowPlaying() {
        guard let request else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: request.info?.title ?? "Episode \(request.episode)",
            MPMediaItemPropertyAlbumTitle: request.media.title.preferred,
            MPMediaItemPropertyArtist: "Episode \(request.episode)",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork, artwork.url == Self.posterURL(request.media) { info[MPMediaItemPropertyArtwork] = artwork.art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private static func posterURL(_ media: Media) -> URL? {
        media.coverImage?.best ?? media.heroImage
    }

    /// Fetches the poster through `ImagePipeline` (so it is usually cached already, and kept for
    /// downloads played offline), then puts it on the lock screen.
    private func loadArtwork(for request: PlayRequest) {
        artworkLoad?.cancel()
        artworkLoad = nil
        guard let url = Self.posterURL(request.media) else {
            artwork = nil
            return
        }
        guard artwork?.url != url else { return }
        artwork = nil
        artworkLoad = Task { [weak self] in
            guard let image = await ImagePipeline.shared.image(for: url), !Task.isCancelled,
                  let self, self.request?.id == request.id else { return }
            self.artwork = (url, Self.artwork(image))
            self.updateNowPlaying()
        }
    }

    /// Nonisolated on purpose: MediaPlayer calls the request handler off the main thread, and a
    /// closure formed on the main actor would trap there under Swift 6.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// The lock screen and headphone controls.
    func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player.playImmediately(atRate: self?.speed ?? 1) }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlay() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.seek(by: 10) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.seek(by: -10) }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.playNext() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime, why: "lock screen") }
            return .success
        }
    }

    func removeRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipForwardCommand,
                        center.skipBackwardCommand, center.nextTrackCommand, center.changePlaybackPositionCommand] {
            command.removeTarget(nil)
        }
    }

    // MARK: - Formatting

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    static func loadedRanges(_ item: AVPlayerItem) -> String {
        let ranges = item.loadedTimeRanges.map { value -> String in
            let range = value.timeRangeValue
            return "\(clock(range.start.seconds))–\(clock(range.end.seconds))"
        }
        return ranges.isEmpty ? "none" : ranges.joined(separator: ", ")
    }
}
#endif
