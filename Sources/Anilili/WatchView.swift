#if canImport(UIKit)
import AnililiCore
import SwiftUI
import SwiftVLC

/// The watch page, after the Android app's phone layout: the player on top and, under it, the
/// episode, the show, the server and audio pickers and the episode list. Turning the phone (or
/// the fullscreen button) gives the player the whole screen.
///
/// An iPad can't be turned by the app, so turning it never means fullscreen there: held
/// sideways it keeps the page beside the player, and only the button goes fullscreen (and back).
/// In the TV layout the player is the whole page, as on Android TV.
struct WatchView: View {
    enum Sheet: String, Identifiable {
        case settings, servers, subtitles, episodes
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library
    @Environment(\.palette) private var palette
    @AppStorage(Setting.playerContentScale) private var screenSize = ScreenSize.fit.rawValue
    @AppStorage(Setting.autoplay) private var autoplay = true
    @AppStorage(Setting.autoSkipIntroOutro) private var autoSkip = false
    @AppStorage(Setting.playOnOpen) private var playOnOpen = true
    @AppStorage("subtitles_by_default") private var subtitlesByDefault = true
    @AppStorage("subtitles_with_dub") private var subtitlesWithDub = false
    @AppStorage(TrackLanguage.subtitleKey) private var subtitleLanguage = ""
    @AppStorage(TrackLanguage.secondarySubtitleKey) private var secondSubtitleLanguage = ""
    @AppStorage(TrackLanguage.audioKey) private var audioLanguage = ""
    @AppStorage(TrackLanguage.secondaryAudioKey) private var secondAudioLanguage = ""
    @AppStorage(PlayerLimits.skipButtonKey) private var skipSeconds = PlayerLimits.skipButtonDefault
    @AppStorage(DefaultQuality.key) private var defaultQuality = DefaultQuality.fallback.rawValue
    @AppStorage(PlaybackBufferSize.key) private var bufferSize = PlaybackBufferSize.automatic.rawValue
    @AppStorage(PlayerLimits.defaultSpeedKey) private var defaultSpeed = 1.0
    @AppStorage(Setting.openInExternalPlayer) private var openExternally = false
    @AppStorage(Setting.videoEngine) private var videoEngine = VideoEngineChoice.ask.rawValue
    @AppStorage(Setting.playerStatusBar) private var statusBarWithControls = true
    @State private var request: PlayRequest
    @State private var engine = PlayerEngine()
    @State private var vlcPlayer = SwiftVLC.Player()
    @State private var usingVLC = false
    @State private var pictureInPicture = PictureInPictureHandle()
    @State private var fullscreen = false
    @State private var landscape = false
    private var television = TelevisionLayout()
    @State private var sheet: Sheet?
    @State private var synopsisExpanded = false
    @State private var episodeQuery = ""
    @State private var logo: URL?
    @State private var controlsShown = true
    /// The stream to hand over when Open episodes in external player is on and no app is named.
    @State private var askExternal: URL?
    @State private var choosingVideoEngine = false
    @State private var chosenVideoEngine: VideoEngineChoice?

    init(request: PlayRequest) {
        _request = State(initialValue: request)
    }

    private var isPad: Bool { TelevisionLayout.isPad }

    /// The player has the whole screen: always in the TV layout, after the button, or while a
    /// phone is held sideways.
    private var full: Bool { television.isOn || fullscreen || (!isPad && landscape) }

    var body: some View {
        GeometryReader { proxy in
            // From the geometry itself rather than `landscape`, which arrives a moment later.
            let wide = proxy.size.width > proxy.size.height
            let full = television.isOn || fullscreen || (!isPad && wide)
            if full {
                player(full: true)
                    .ignoresSafeArea()
            } else if isPad && wide {
                // The player and its page on the left, the episodes on the right.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        player(full: false)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .background(Color.black)
                        ScrollView { info.padding(.bottom, 28) }
                    }
                    .frame(width: proxy.size.width * 0.62)
                    Divider()
                    ScrollView { episodes.padding(.bottom, 28) }
                }
                .background(palette.background)
            } else {
                VStack(spacing: 0) {
                    player(full: false)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .background(Color.black)
                    details
                }
                .background(palette.background)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { landscape = $0 }
        .background(Color.black.ignoresSafeArea())
        // Settings → Player → Status bar over the player: the clock and battery with the controls.
        .statusBarHidden(full && !(statusBarWithControls && controlsShown))
        .persistentSystemOverlays(full ? .hidden : .automatic)
        .task(id: request.id) { await start() }
        .task {
            if AppearanceStore.shared.seriesLogos { logo = await MediaIndex.shared.logo(request.media.id) }
        }
        .onAppear {
            OrientationLock.allow(.allButUpsideDown)
            engine.installRemoteCommands()
        }
        .onDisappear {
            engine.stop()
            vlcPlayer.stop()
            engine.removeRemoteCommands()
            OrientationLock.allow(.portrait, turnTo: isPad ? nil : .portrait)
        }
        .confirmationDialog(MenuLanguage.usesArabic ? "فتح الحلقة في" : "Open this episode in", isPresented: Binding(get: { askExternal != nil }, set: { if !$0 { askExternal = nil } }), titleVisibility: .visible) {
            ForEach(ExternalPlayer.allCases) { app in
                Button(app.name) {
                    if let stream = askExternal { app.open(stream) }
                    askExternal = nil
                }
            }
            Button(MenuLanguage.usesArabic ? "التشغيل هنا بدلًا من ذلك" : "Play here instead") {
                askExternal = nil
                engine.player.play()
            }
        } message: {
            Text(MenuLanguage.usesArabic ? "الإعدادات ← المشغل ترسل الحلقات إلى تطبيق آخر." : "Settings → Player sends episodes to another app.")
        }
        .confirmationDialog(
            MenuLanguage.usesArabic ? "اختر مشغل الفيديو" : "Choose video player",
            isPresented: $choosingVideoEngine,
            titleVisibility: .visible
        ) {
            Button("AVPlayer") { chooseVideoEngine(.avPlayer) }
            Button("VLC") { chooseVideoEngine(.vlc) }
            Button(MenuLanguage.usesArabic ? "إلغاء" : "Cancel", role: .cancel) { chosenVideoEngine = .avPlayer }
        } message: {
            Text(MenuLanguage.usesArabic ? "اختر المشغل لهذه الحلقة فقط." : "Choose the player for this episode only.")
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .settings:
                PlayerSettingsSheet(engine: engine, request: request) { audio in request.audio = audio }
            case .servers:
                ServersSheet(engine: engine, request: request) { audio in request.audio = audio }
            case .subtitles:
                SubtitlesSheet(engine: engine)
            case .episodes:
                NavigationStack {
                    ScrollView { episodeList.padding(.vertical, 8) }
                        .background(palette.background)
                        .navigationTitle(MenuLanguage.usesArabic ? "الحلقات" : "Episodes")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private var gravity: ScreenSize { ScreenSize.stored(screenSize) }

    @ViewBuilder
    private func player(full: Bool) -> some View {
        if usingVLC {
            ZStack {
                Color.black
                VideoView(vlcPlayer)
                VLCPlayerOverlay(player: vlcPlayer, fullscreen: full) {
                    vlcPlayer.stop()
                    usingVLC = false
                    back(full: full)
                }
            }
        } else if let embed = engine.embed {
            embedPlayer(embed, full: full)
        } else {
            nativePlayer(full: full)
        }
    }

    /// A server that only offers its own web player: the page with its own controls, and a slim
    /// bar of the app's (back, episodes, servers, fullscreen) over its top edge.
    private func embedPlayer(_ source: VideoSource, full: Bool) -> some View {
        ZStack(alignment: .top) {
            Color.black
            EmbedWebPlayer(
                source: source,
                onTick: { engine.embedTick(position: $0, duration: $1, playing: $2) },
                onEnded: { engine.embedEnded() }
            )
            .id(source.url)
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 56)
                .allowsHitTesting(false)
            HStack(spacing: 4) {
                embedButton(leavesFullscreen(full) ? "chevron.down" : "chevron.left", leavesFullscreen(full) ? "Leave fullscreen" : "Back") {
                    back(full: full)
                }
                Text(source.label)
                    .font(AppFont.labelMedium)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
                if let previous = request.previousEpisode {
                    embedButton("backward.end.fill", "Previous episode") { change(to: previous) }
                }
                if let next = request.nextEpisode {
                    embedButton("forward.end.fill", "Next episode") { change(to: next) }
                }
                if full { embedButton("list.bullet", "Episodes") { sheet = .episodes } }
                embedButton("server.rack", "Servers") { sheet = .servers }
                if !television.isOn {
                    embedButton(full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", full ? "Exit fullscreen" : "Fullscreen") {
                        setFullscreen(!full)
                    }
                }
            }
            .padding(.horizontal, full ? 16 : 4)
            .padding(.top, full ? 8 : 2)
        }
        .onAppear { controlsShown = true }
    }

    private func embedButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func nativePlayer(full: Bool) -> some View {
        ZStack {
            Color.black
            PlayerSurface(player: engine.player, gravity: gravity.gravity, pictureInPicture: pictureInPicture)
            PlayerOverlay(
                engine: engine,
                seriesTitle: request.media.title.preferred,
                episodeTitle: episodeLine,
                fullscreen: full,
                backLeavesFullscreen: leavesFullscreen(full),
                canToggleFullscreen: !television.isOn,
                pictureInPicture: pictureInPicture,
                onBack: { back(full: full) },
                onToggleFullscreen: { setFullscreen(!full) },
                onPrevious: request.previousEpisode.map { previous in { change(to: previous) } },
                onNext: request.nextEpisode.map { next in { change(to: next) } },
                onSettings: { sheet = .settings },
                onSources: { sheet = .servers },
                onSubtitles: { sheet = .subtitles },
                onEpisodes: full ? { sheet = .episodes } : nil,
                onRetry: { Task { await start() } },
                logo: logo,
                synopsis: synopsis,
                onControlsVisible: { controlsShown = $0 }
            )
        }
    }

    private var synopsis: String? {
        request.info?.synopsis ?? request.media.description.map(HTML.plainDescription)
    }

    private var episodeLine: String {
        var text = "Episode \(request.episode)"
        if let title = request.info?.title { text += " · \(title)" }
        return text
    }

    /// Whether back leaves fullscreen rather than the player: never in the TV layout, where
    /// fullscreen is the only way the player is drawn.
    private func leavesFullscreen(_ full: Bool) -> Bool { full && !television.isOn }

    private func back(full: Bool) {
        if leavesFullscreen(full) {
            setFullscreen(false)
        } else {
            dismiss()
        }
    }

    private func setFullscreen(_ on: Bool) {
        fullscreen = on
        // A phone turns with it; an iPad stays as it's held and only the layout changes.
        if !isPad {
            OrientationLock.allow(.allButUpsideDown, turnTo: on ? .landscapeRight : .portrait)
        }
        Log.info("player", on ? "fullscreen" : "windowed")
    }

    private func change(to episode: Int) {
        Log.info("player", "episode \(request.episode) → \(episode)")
        request.episode = episode
    }

    private func chooseVideoEngine(_ choice: VideoEngineChoice) {
        chosenVideoEngine = choice
        choosingVideoEngine = false
        Task { await start() }
    }

    // MARK: - Details (portrait)

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                info
                episodes
            }
            .padding(.bottom, 28)
        }
    }

    /// The episode, the show and the pickers.
    private var info: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.top, 16)
            showRow
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.top, 14)
            selectors
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var episodes: some View {
        if request.media.format != "MOVIE" {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(MenuLanguage.usesArabic ? "الحلقات" : "Episodes").font(AppFont.titleMedium.weight(.bold)).foregroundStyle(palette.onSurface)
                    Text("  \(request.listing.available(request.audio).count)").font(AppFont.bodyMedium).foregroundStyle(palette.onSurfaceVariant)
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.vertical, 14)
                episodeList
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.info?.title ?? "Episode \(request.episode)")
                .font(AppFont.titleLarge)
                .foregroundStyle(palette.onSurface)
            Text([request.media.averageScore.map { "\($0)% score" }, "Episode \(request.episode)"].compactMap { $0 }.joined(separator: " · "))
                .font(AppFont.bodyMedium)
                .foregroundStyle(palette.onSurfaceVariant)
            if let synopsis, !synopsis.isEmpty {
                Text(synopsis)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(synopsisExpanded ? nil : 2)
                Button(synopsisExpanded ? "Less" : "More") { withAnimation(.snappy) { synopsisExpanded.toggle() } }
                    .font(AppFont.labelLarge)
                    .foregroundStyle(palette.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var showRow: some View {
        let saved = library.watchlist.contains(request.media.id)
        return HStack(spacing: 12) {
            CoverImage(media: request.media)
                .frame(width: 52, height: 52)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(request.media.title.preferred).font(AppFont.titleSmall).foregroundStyle(palette.onSurface).lineLimit(1)
                if let popularity = request.media.popularity {
                    Text("\(DetailView.compact(popularity)) popularity").font(AppFont.labelSmall).foregroundStyle(palette.onSurfaceVariant)
                }
            }
            Spacer()
            Button {
                library.toggleWatchlist(request.media)
            } label: {
                Image(systemName: saved ? "heart.fill" : "heart")
                    .font(.system(size: 22))
                    .foregroundStyle(saved ? palette.primary : palette.onSurface)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(saved ? "Remove from watchlist" : "Add to watchlist")
        }
    }

    private var selectors: some View {
        HStack(spacing: 10) {
            Button {
                sheet = .servers
            } label: {
                HStack(spacing: 6) {
                    if let current = engine.current, ServerSummary.canDownload(current) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.primary)
                            .accessibilityLabel("Can be saved offline")
                    }
                    Text(engine.current.map { "\($0.provider) · \($0.server)" } ?? "Servers").lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                }
                .font(AppFont.labelLarge)
                .foregroundStyle(palette.onSurface)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.outline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows every server for this episode, by audio and language")
            ForEach(AudioTrack.allCases) { audio in
                let has = (audio == .sub ? request.listing.subbed : request.listing.dubbed).contains(request.episode)
                if has {
                    Button {
                        request.audio = audio
                    } label: {
                        Text(audio.label)
                            .font(AppFont.labelLarge)
                            .foregroundStyle(request.audio == audio ? palette.onPrimary : palette.onSurface)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(request.audio == audio ? palette.primary : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(request.audio == audio ? .clear : palette.outline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
    }

    private var episodeList: some View {
        let episodes = request.listing.available(request.audio)
        let shown = EpisodeCatalog.filter(episodes, episodeQuery)
        return LazyVStack(alignment: .leading, spacing: 0) {
            if episodes.count > EpisodeCatalog.browserMinimum {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.onSurfaceVariant)
                    TextField("Filter episodes…", text: $episodeQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.bottom, 6)
            }
            ForEach(shown) { episode in
                let selected = episode.number == request.episode
                let progress = library.history.progress(mediaID: request.media.id, episode: episode.number)
                Button {
                    change(to: episode.number)
                    if sheet == .episodes { sheet = nil }
                } label: {
                    HStack(spacing: 13) {
                        Color.clear
                            .frame(width: 132, height: 74)
                            .overlay {
                                RemoteImage(url: episode.thumbnail ?? request.media.heroImage) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFill()
                                            .blur(radius: AppearanceStore.shared.blurEpisodeImages && progress?.isFinished != true && !selected ? 12 : 0)
                                    } else {
                                        palette.surfaceVariant
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(alignment: (progress?.fraction ?? 0) > 0.01 ? .topTrailing : .bottomTrailing) {
                                PosterTag(text: "EP \(episode.number)").padding(5)
                            }
                            .overlay(alignment: .bottom) {
                                // A watched episode keeps a full line, as on the show page.
                                if let progress, progress.fraction > 0.01 {
                                    ProgressLine(fraction: progress.isFinished ? 1 : progress.fraction).padding(.horizontal, 6).padding(.bottom, 5)
                                }
                            }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(episode.title ?? "Episode \(episode.number)")
                                .font(AppFont.titleMedium)
                                .foregroundStyle(palette.onSurface)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if selected {
                                Text("Now playing").font(AppFont.bodyMedium).foregroundStyle(palette.primary)
                            } else if episode.title != nil {
                                Text("Episode \(episode.number)").font(AppFont.bodyMedium).foregroundStyle(palette.onSurfaceVariant)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .background(selected ? palette.surfaceVariant : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Metrics.pagePadding - 6)
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Opening an episode

    private func start() async {
        let configuredEngine = VideoEngineChoice(rawValue: videoEngine) ?? .automatic
        if configuredEngine == .ask && chosenVideoEngine == nil {
            choosingVideoEngine = true
            return
        }
        let engineForEpisode = chosenVideoEngine ?? configuredEngine
        chosenVideoEngine = nil
        vlcPlayer.stop()
        usingVLC = false
        Log.info("player", "video engine preference: \(engineForEpisode.rawValue)")
        // Continue Watching opens the player straight from Home, before any episode list exists.
        if request.listing.isEmpty {
            do {
                let listing = try await SourceHub.shared.episodes(for: request.media)
                async let index = MediaIndex.shared.episodes(request.media.id)
                request.listing = EpisodeCatalog.merge(listing, index: await index, streaming: request.media.streamingEpisodes ?? [])
            } catch {
                Log.warning("player", "episode list for \(request.media.id) failed: \(Log.describe(error)); playing without it")
            }
        }
        let current = request
        let library = library
        engine.onProgress = { position, duration in
            library.record(current.media, episode: current.episode, position: position, duration: duration)
        }
        engine.onNextEpisode = {
            guard let next = current.nextEpisode, request.id == current.id else { return }
            Log.info("player", "next episode \(next)")
            request.episode = next
        }
        engine.setSpeed(Float(PlayerLimits.speed(defaultSpeed, default: 1)))
        let startAt = current.start ?? library.history.resumePosition(mediaID: current.media.id, episode: current.episode)
        request.start = nil
        var offline: VideoSource? = current.localSource
        var otherAudio: VideoSource?
        if offline == nil, let saved = DownloadStore.shared.saved(mediaID: current.media.id, episode: current.episode, prefer: current.audio) {
            // The other audio's saved copy only stands in when no server answers (offline): online
            // the viewer gets the audio they picked.
            if saved.audio == current.audio {
                offline = await DownloadStore.shared.offlineSource(for: saved)
            } else {
                otherAudio = await DownloadStore.shared.offlineSource(for: saved)
            }
        }
        let isMKV = offline?.url.pathExtension.lowercased() == "mkv"
        let shouldUseVLC = engineForEpisode == .vlc || (engineForEpisode == .automatic && isMKV)
        if shouldUseVLC, let local = offline, local.url.isFileURL {
            do {
                usingVLC = true
                try playVLC(url: local.url, headers: local.headers, importedSubtitle: importedSubtitleURL())
                return
            } catch {
                usingVLC = false
                Log.warning("vlc", "couldn't open local file; falling back to AVPlayer: \(error)")
            }
        }
        usingVLC = false
        await engine.open(
            current,
            startAt: startAt,
            settings: PlayerEngine.Settings(
                autoSkip: autoSkip,
                autoplay: autoplay,
                subtitlesByDefault: subtitlesByDefault,
                subtitlesWithDub: subtitlesWithDub,
                subtitleLanguages: [subtitleLanguage, secondSubtitleLanguage].map { TrackLanguage.stored($0, in: TrackLanguage.subtitles) },
                audioLanguages: [audioLanguage, secondAudioLanguage].map { TrackLanguage.stored($0, in: TrackLanguage.audio) },
                skipSeconds: PlayerLimits.skipSeconds(skipSeconds),
                defaultQuality: DefaultQuality.stored(defaultQuality),
                buffer: PlaybackBufferSize.stored(bufferSize)
            ),
            offline: offline,
            lastResort: otherAudio
        )
        if engineForEpisode == .vlc, engine.embed == nil, let resolved = engine.current {
            do {
                // The normal AVPlayer path uses StreamProxy to carry Referer/Origin,
                // rewrite nested HLS URLs and serve gated AES keys. VLC must use the
                // same proxy URL; the provider URL alone is not playable for these hosts.
                let vlcURL: URL
                if resolved.kind == .hls {
                    vlcURL = StreamProxy.shared.address(for: resolved.url, headers: resolved.headers, key: resolved.aesKey) ?? resolved.url
                } else {
                    vlcURL = resolved.url
                }
                try playVLC(url: vlcURL, headers: resolved.headers, importedSubtitle: importedSubtitleURL())
                usingVLC = true
                engine.player.pause()
            } catch {
                Log.warning("vlc", "couldn't open resolved source; keeping AVPlayer: \(error)")
                usingVLC = false
            }
        }
        if !playOnOpen { engine.player.pause() }
        // Settings → Player → Open episodes in external player: the stream goes to the chosen app
        // (or the viewer picks one), and this player waits paused behind it. A saved download
        // plays here: other apps can't read the app's own files.
        if openExternally, offline == nil, engine.embed == nil, let stream = engine.current?.url, request.id == current.id {
            engine.player.pause()
            if let app = ExternalPlayer.chosen {
                app.open(stream)
            } else {
                askExternal = stream
            }
        }
    }

    private func playVLC(url: URL, headers: [String: String] = [:], importedSubtitle: URL? = nil) throws {
        let userAgent = headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
        let referrer = headers.first { $0.key.caseInsensitiveCompare("Referer") == .orderedSame || $0.key.caseInsensitiveCompare("Referrer") == .orderedSame }?.value
        let media = try SwiftVLC.Media(url: url, httpUserAgent: userAgent, httpReferrer: referrer)
        if let importedSubtitle {
            try media.addSlave(from: importedSubtitle, type: .subtitle)
        }
        try vlcPlayer.play(media)
    }

    private func importedSubtitleURL() -> URL? {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportedSubtitles", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix(request.id + ".") }
    }
}
#endif
