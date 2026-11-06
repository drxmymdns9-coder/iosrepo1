#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// The show page, after the Android app's `DetailScreen`: a hero with the cover and the series'
/// logo, the list and watch actions, the series progress, and Home / Episodes / Related tabs. The
/// whole page takes the show's colour when Appearance says so.
struct DetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case home = "Home", episodes = "Episodes", related = "Related"
        var id: String { rawValue }
    }

    enum EpisodeState {
        case loading
        case loaded(EpisodeListing)
        case failed(String)
    }

    @Environment(LibraryStore.self) var library
    @Environment(AppRouter.self) var router
    @Environment(\.palette) private var appPalette
    @State var media: Media
    @State private var tab: Tab = .home
    @State var audio: AudioTrack
    @State var playing: PlayRequest?
    @State var logo: URL?
    /// The season chain, empty until the walk lands (the page's own neighbours stand in).
    @State private var series: [Media] = []
    @State private var seriesLoading = true
    @State private var recommendations: [Media] = []
    @State private var recommendationsLoading = true
    @State var selectedSeason: Int
    @State var listings: [Int: EpisodeState] = [:]
    @State var showingCover = false
    @State private var heroBottom: CGFloat = 400
    /// The TV layout's page: its tab (Episodes first, as on Android TV) and episode block.
    @State var televisionTab: Tab = .episodes
    @State var televisionBlock: Int?
    @State private var startingWatch = false
    @AppStorage("episode_order") var episodeOrder = "oldest"
    private var television = TelevisionLayout()

    init(media: Media) {
        _media = State(initialValue: media)
        _selectedSeason = State(initialValue: media.id)
        _audio = State(initialValue: PlaybackSettings.preferredAudio)
    }

    /// The show's own palette, or the app's when the setting is off or the cover is grey.
    var palette: Palette { AppearanceStore.shared.showPalette(media.coverImage?.color) ?? appPalette }

    var isMovie: Bool { media.format == "MOVIE" }

    /// The chain as far as it's known: the walk's, or until it lands the title and its direct
    /// prequel and sequel, as Android seeds it.
    private var knownSeries: [Media] {
        series.isEmpty ? WatchOrder.seeded(media, hideAdult: ContentSettings.hideAdult) : series
    }

    /// The season picker's entries: TheTVDB's numbered run when it places this title (Android's
    /// `tvdbSeasonChain`), else the chain's episodic entries.
    var seasons: [Media] {
        WatchOrder.seasonChain(media, series: knownSeries, ref: TVDBSeasons.ref)
    }

    var seasonMedia: Media {
        seasons.first { $0.id == selectedSeason } ?? media
    }

    var listing: EpisodeListing? {
        if case .loaded(let listing) = listings[selectedSeason] { return listing }
        return nil
    }

    var body: some View {
        Group {
            if television.isOn {
                televisionPage
            } else {
                phonePage
            }
        }
        .background(palette.background)
        .environment(\.palette, palette)
        .tint(palette.primary)
        .onAppear { Log.info("detail", "open \(media.id) \"\(media.title.preferred)\"") }
        .task { await loadDetails() }
        .task { await loadSeries() }
        .task(id: selectedSeason) { await loadEpisodes(selectedSeason) }
        .fullScreenCover(item: $playing) { WatchView(request: $0) }
        .fullScreenCover(isPresented: $showingCover) { CoverPreview(media: media) }
    }

    /// The phone's page: the hero, the actions and the pinned tabs in one scroll.
    private var phonePage: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // The scroll view keeps the top safe area, so the tabs below pin under the
                    // navigation bar; the banner alone reaches up behind the bars.
                    hero(topInset: topInset)
                        .padding(.top, -topInset)
                        .background {
                            GeometryReader { hero in
                                Color.clear.preference(key: DetailHeroBottomKey.self, value: hero.frame(in: .named("detail")).maxY)
                            }
                        }
                    actions
                    seriesProgress
                    Section {
                        switch tab {
                        case .home: DetailHomeTab(media: media)
                        case .episodes: episodesTab
                        case .related: relatedTab
                        }
                    } header: {
                        tabs
                    }
                }
                .padding(.bottom, 30)
            }
            .coordinateSpace(name: "detail")
            .onPreferenceChange(DetailHeroBottomKey.self) { heroBottom = $0 }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(heroBottom < 140 ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(palette.background.opacity(0.92), for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if heroBottom < 140 {
                    Text(media.title.preferred).font(AppFont.titleSmall).foregroundStyle(palette.onSurface).lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { shareButton }
        }
    }

    @ViewBuilder
    var shareButton: some View {
        if let link = URL(string: "anilili://anime/\(media.id)") {
            ShareLink(item: link, subject: Text(media.title.preferred), message: Text(media.title.preferred)) {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }

    // MARK: - Hero

    private func hero(topInset: CGFloat) -> some View {
        let bannerHeight = topInset + 190
        return ZStack(alignment: .bottomLeading) {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: bannerHeight)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        RemoteImage(url: media.bannerURL ?? media.coverImage?.best) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() } else { palette.surfaceVariant.opacity(0.4) }
                        }
                    }
                    .clipped()
                    .overlay(LinearGradient(colors: [.clear, palette.background], startPoint: .top, endPoint: .bottom))
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 14) {
                Button {
                    showingCover = true
                } label: {
                    CoverImage(media: media)
                        .frame(width: 98, height: 147)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.outline, lineWidth: 1))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(.black.opacity(0.72), in: Circle())
                                .padding(6)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View larger cover")
                VStack(alignment: .leading, spacing: 0) {
                    SeriesTitle(media: media, logo: logo)
                        .frame(height: 60, alignment: .bottomLeading)
                        .padding(.bottom, 4)
                    if let studio = media.mainStudio, let name = studio.name {
                        StudioBadge(name: name) {
                            if let id = studio.id { router.openStudio(id: id, name: name) }
                        }
                    }
                    Text(heroFacts)
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(palette.primary)
                        .padding(.top, 4)
                }
                .padding(.bottom, 4)
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.vertical, 10)
        }
        .frame(height: topInset + 286)
    }

    private var heroFacts: String {
        var parts: [String] = []
        if let score = media.averageScore { parts.append("\(score)% score") }
        if let members = media.popularity, members > 0 { parts.append("\(Self.compact(members)) members") }
        if isMovie {
            if let duration = media.duration { parts.append("\(duration) min") }
        } else if let episodes = media.episodes {
            parts.append("\(episodes) episodes")
        }
        return parts.joined(separator: " · ")
    }

    /// "1.1M", "461.5K": Android's compact member count.
    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        case 1_000...: return String(format: "%.1fK", Double(value) / 1_000).replacingOccurrences(of: ".0K", with: "K")
        default: return "\(value)"
        }
    }

    // MARK: - Actions

    var resumeShow: WatchHistory.Show? { library.history.shows[selectedSeason] ?? library.history.shows[media.id] }

    private var actions: some View {
        let saved = library.watchlist.contains(media.id)
        let available = listing?.available(audio).map(\.number) ?? []
        let loadingEpisodes: Bool = {
            if case .loading = listings[selectedSeason] { return true }
            return false
        }()
        // The first visit often has no cached episode list yet. Keep the button tappable so the
        // tap starts the fetch instead of looking like a dead control until the app is restarted.
        let canWatch = true
        let status = AccountStore.shared.statuses[media.id]
        return HStack(spacing: 10) {
            Button {
                router.listSheet = media
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: status != nil || saved ? "heart.fill" : "heart")
                    Text(status?.label ?? (saved ? "In library" : "Add to list")).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                }
                .font(AppFont.labelLarge)
                .foregroundStyle(palette.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .overlay(Capsule().strokeBorder(palette.outline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            // The viewer's own score, for a title on the account only (the list sheet has it too).
            if status != nil {
                let score = AccountStore.shared.score(of: media.id)
                Button {
                    router.scoreSheet = media
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: score == nil ? "star" : "star.fill")
                        if let score { Text(ListScore.format(score)) }
                    }
                    .font(AppFont.labelLarge)
                    .foregroundStyle(palette.primary)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 46)
                    .frame(height: 46)
                    .overlay(Capsule().strokeBorder(palette.outline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(score.map { "Your score: \(ListScore.format($0)) out of 10" } ?? "Rate this season")
            }
            Button {
                startWatching(available: available)
            } label: {
                HStack(spacing: 6) {
                    if loadingEpisodes || startingWatch {
                        ProgressView().controlSize(.small).tint(palette.onPrimary)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(watchLabel(available)).lineLimit(1)
                }
                .font(AppFont.labelLarge.weight(.bold))
                .foregroundStyle(palette.onPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(canWatch ? palette.primary : palette.disabledFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canWatch)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.bottom, 14)
    }

    func watchLabel(_ available: [Int]) -> String {
        if isMovie { return resumeShow == nil ? "Watch" : "Resume" }
        if resumeShow != nil { return "Continue \(resumeTarget(available))" }
        return "Watch"
    }

    func resumeTarget(_ available: [Int]) -> Int {
        if let show = resumeShow, available.contains(show.resumeEpisode) { return show.resumeEpisode }
        return available.first ?? 1
    }

    func play(_ episode: Int, available: [Int]) {
        guard let listing, available.contains(episode) else { return }
        playing = PlayRequest(media: seasonMedia, episode: episode, audio: audio, listing: listing)
    }

    private func startWatching(available: [Int]) {
        if !available.isEmpty {
            play(resumeTarget(available), available: available)
            return
        }
        guard !startingWatch else { return }
        startingWatch = true
        Task {
            // If the screen's automatic first load is already running, wait for it instead of
            // launching a second request that could race and overwrite a successful result.
            while case .loading = listings[selectedSeason] {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if listing == nil {
                await loadEpisodes(selectedSeason, force: true)
            }
            let loaded = listing?.available(audio).map(\.number) ?? []
            if !loaded.isEmpty { play(resumeTarget(loaded), available: loaded) }
            startingWatch = false
        }
    }

    @ViewBuilder
    private var seriesProgress: some View {
        let total = max(listing?.episodes.count ?? 0, seasonMedia.episodes ?? 0)
        if let show = resumeShow, total > 0 {
            let fraction = min(1, max(0, (Double(show.lastEpisode - 1) + (show.episodes[show.lastEpisode]?.fraction ?? 0)) / Double(total)))
            VStack(spacing: 6) {
                HStack {
                    Text(isMovie ? "Movie progress" : "Episode \(show.lastEpisode) of \(total)")
                        .font(AppFont.labelMedium)
                        .foregroundStyle(palette.onSurfaceVariant)
                    Spacer()
                    Text("\(Int(fraction * 100))%").font(AppFont.labelMedium).foregroundStyle(palette.primary)
                }
                ProgressLine(fraction: fraction)
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Tabs

    private var tabs: some View {
        HStack(spacing: 8) {
            ForEach(Tab.allCases.filter { !(isMovie && $0 == .episodes) }) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.rawValue)
                        .font(AppFont.labelLarge)
                        .foregroundStyle(tab == item ? palette.onPrimary : palette.onSurfaceVariant)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(tab == item ? palette.primary : palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(palette.background)
    }

    // MARK: - Episodes

    @ViewBuilder
    private var episodesTab: some View {
        let seasons = self.seasons
        if seasons.count > 1 {
            let labels = SeasonLabels.labels(seasons, ref: TVDBSeasons.ref)
            let chips = HStack(spacing: 8) {
                ForEach(Array(seasons.enumerated()), id: \.element.id) { index, season in
                    SeasonChip(season: season, label: labels[season.id] ?? "Season \(index + 1)",
                               selected: season.id == selectedSeason,
                               choosable: SeasonLabels.choosable(season, selected: selectedSeason)) {
                        selectedSeason = season.id
                    }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.vertical, 8)
            // Centred when the chips fit, scrolling when they don't, as on Android.
            ViewThatFits(in: .horizontal) {
                chips.frame(maxWidth: .infinity)
                ScrollView(.horizontal, showsIndicators: false) { chips }
            }
        }
        switch listings[selectedSeason] ?? .loading {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading episodes…").font(AppFont.bodyMedium).foregroundStyle(palette.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        case .failed(let message):
            ErrorState(message: message) { await loadEpisodes(selectedSeason, force: true) }
        case .loaded(let listing):
            EpisodeBrowser(
                media: seasonMedia,
                listing: listing,
                audio: $audio,
                cover: seasonMedia.bannerImage ?? media.bannerImage ?? media.coverImage?.best?.absoluteString,
                onPlay: { number in play(number, available: listing.available(audio).map(\.number)) }
            )
        }
    }

    // MARK: - Related

    /// Derived, as on Android: the chain's members carry their relations, so the whole franchise
    /// is read off them, and the shelf numbers the same seasons the Episodes tab's chips do.
    var relatedTab: some View {
        let hideAdult = ContentSettings.hideAdult
        let guide = WatchOrder.build(media, series: knownSeries, seasons: seasons, hideAdult: hideAdult)
        return RelatedTab(
            entries: guide,
            suggestions: WatchOrder.suggestions(recommendations, current: media.id, guide: guide, hideAdult: hideAdult),
            loading: seriesLoading || recommendationsLoading,
            onWatch: watch
        )
    }

    /// A related title's play button: where it was left off, else its first episode (Android's
    /// `onSeasonWatch`).
    private func watch(_ title: Media) {
        let resume = library.history.shows[title.id]?.resumeEpisode ?? 1
        playing = PlayRequest(media: title, episode: resume, audio: PlaybackSettings.preferredAudio, listing: .empty)
    }

    // MARK: - Loading

    private func loadDetails() async {
        if media.description == nil || media.studios == nil || media.relations == nil {
            do {
                media = try await AniListClient.shared.media(id: media.id)
            } catch {
                Log.warning("detail", "full entry for \(media.id) failed: \(Log.describe(error))")
            }
        }
        if AppearanceStore.shared.seriesLogos { logo = await MediaIndex.shared.logo(media.id) }
        do {
            recommendations = try await AniListClient.shared.recommendations(id: media.id)
        } catch {
            Log.warning("detail", "recommendations for \(media.id) failed: \(Log.describe(error))")
        }
        recommendationsLoading = false
    }

    private func loadSeries() async {
        let indexSeries = await MediaIndex.shared.detail(media.id)?.series
        do {
            series = try await WatchOrder.series(media.id, indexSeries: indexSeries, hideAdult: ContentSettings.hideAdult)
            Log.info("detail", "\(media.id) series: \(series.count) members, \(seasons.count) seasons")
        } catch {
            Log.warning("detail", "series for \(media.id) failed: \(Log.describe(error))")
        }
        seriesLoading = false
    }

    func loadEpisodes(_ seasonID: Int, force: Bool = false) async {
        if !force, case .loaded = listings[seasonID] { return }
        listings[seasonID] = .loading
        let target = seasonID == media.id ? media : seasonMedia
        do {
            async let index = MediaIndex.shared.episodes(seasonID)
            async let filler = MediaIndex.shared.fillerEpisodes(seasonID)
            let listing = try await SourceHub.shared.episodes(for: target)
            let merged = EpisodeCatalog.merge(listing, index: await index, streaming: target.streamingEpisodes ?? [], filler: await filler)
            if merged.available(audio).isEmpty, !merged.available(audio == .sub ? .dub : .sub).isEmpty {
                audio = audio == .sub ? .dub : .sub
            }
            listings[seasonID] = .loaded(merged)
        } catch {
            Log.error("detail", "episodes for \(seasonID) failed: \(Log.describe(error))")
            listings[seasonID] = .failed("Couldn't reach any source: \(error.localizedDescription)")
        }
    }
}

private struct DetailHeroBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 400
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The series' own logo where the media index has one and Appearance → Series logos is on,
/// otherwise its name.
struct SeriesTitle: View {
    @Environment(\.palette) private var palette
    let media: Media
    let logo: URL?

    var body: some View {
        if let logo {
            RemoteImage(url: logo) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    name
                }
            }
            .accessibilityLabel(media.title.preferred)
        } else {
            name
        }
    }

    private var name: some View {
        Text(media.title.preferred)
            .font(AppFont.titleLarge.weight(.black))
            .foregroundStyle(palette.onSurface)
            .lineLimit(3)
            .minimumScaleFactor(0.7)
    }
}

/// The animation studio as a tappable badge in the accent; it opens Browse on that studio.
private struct StudioBadge: View {
    @Environment(\.palette) private var palette
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(name).font(AppFont.labelLarge.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(palette.primary)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .background(palette.primary.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(palette.primary.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.top, 5)
        .accessibilityLabel("Browse \(name) titles")
    }
}

// MARK: - Home tab

struct DetailHomeTab: View {
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL
    let media: Media
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            facts
            if let next = media.nextAiringEpisode {
                NextEpisodeCard(episode: next.episode, date: next.date)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 8)
            }
            if let genres = media.genres, !genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(genres, id: \.self) { genre in
                            Text(genre)
                                .font(AppFont.labelMedium)
                                .foregroundStyle(palette.onSurface)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                }
                .padding(.vertical, 8)
            }
            if let description = media.description, !description.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Overview").font(AppFont.titleMedium.weight(.bold)).foregroundStyle(palette.onSurface)
                    Text(HTML.plainDescription(description))
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(palette.onSurfaceVariant)
                        .lineLimit(expanded ? nil : 4)
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
            }
            if let trailer = media.trailer, let url = trailer.watchURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trailer").font(AppFont.titleMedium.weight(.bold)).foregroundStyle(palette.onSurface)
                    Button {
                        openURL(url)
                    } label: {
                        Color.clear
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .overlay {
                                RemoteImage(url: trailer.thumbnail.flatMap(URL.init(string:))) { phase in
                                    if let image = phase.image { image.resizable().scaledToFill() } else { palette.surfaceVariant }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white)
                                    .frame(width: 56, height: 56)
                                    .background(.black.opacity(0.55), in: Circle())
                            }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.vertical, 8)
            }
            metadata
        }
    }

    private var facts: some View {
        let cells: [(String, String)] = [
            media.statusLabel.map { ($0, "Status") },
            media.formatLabel.map { ($0, "Format") },
            media.seasonYear.map { (String($0), "Year") },
            media.duration.map { ("\($0) min", "Duration") },
        ].compactMap { $0 }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(cells.indices, id: \.self) { index in
                    VStack(spacing: 3) {
                        Text(cells[index].0).font(AppFont.titleMedium).foregroundStyle(palette.onSurface).lineLimit(1)
                        Text(cells[index].1).font(AppFont.labelSmall).foregroundStyle(palette.onSurfaceVariant)
                    }
                    .frame(width: 112)
                    .padding(.vertical, 12)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.outline, lineWidth: 1))
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.vertical, 8)
            .frame(minWidth: Metrics.screenWidth)
        }
    }

    @ViewBuilder
    private var metadata: some View {
        let rows: [(String, String)] = [
            media.startDate?.date.map { ("Start date", $0.formatted(date: .abbreviated, time: .omitted)) },
            media.endDate?.date.map { ("End date", $0.formatted(date: .abbreviated, time: .omitted)) },
            media.season.map { ("Season", $0.capitalized) },
            media.popularity.map { ("Members", $0.formatted()) },
            media.favourites.map { ("Favorites", $0.formatted()) },
        ].compactMap { $0 }
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack {
                        Text(rows[index].0).foregroundStyle(palette.onSurfaceVariant)
                        Spacer()
                        Text(rows[index].1).fontWeight(.semibold).foregroundStyle(palette.onSurface)
                    }
                    .font(AppFont.bodyMedium)
                    .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.outline, lineWidth: 1))
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.vertical, 8)
        }
    }
}

/// "Next episode 12 · Sun, Oct 18 at 4:30 PM · in 2d 4h" (Android's `NextEpisodeCountdown`).
struct NextEpisodeCard: View {
    @Environment(\.palette) private var palette
    let episode: Int
    let date: Date

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock").font(.system(size: 22)).foregroundStyle(palette.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next episode \(episode)").font(AppFont.titleSmall).foregroundStyle(palette.onSurface)
                Text("\(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) at \(AirTime.format(date))")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(Self.countdown(to: date, now: context.date))
                    .font(AppFont.labelLarge.weight(.bold))
                    .foregroundStyle(palette.primary)
            }
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.outline, lineWidth: 1))
    }

    static func countdown(to date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "Out now" }
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3_600, minutes = (seconds % 3_600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(minutes)m"
    }
}

// MARK: - Episode browser

/// The Episodes tab, after Android's `EpisodeBrowser`: sub/dub, range blocks for long-runners, a
/// filter that doubles as jump-to-episode, newest/oldest, list or grid; rows with stills, filler
/// tags, progress and the watched eye.
private struct EpisodeBrowser: View {
    @Environment(\.palette) private var palette
    @Environment(LibraryStore.self) private var library
    @AppStorage("episode_layout") private var layout = "list"
    @AppStorage("episode_order") private var order = "oldest"
    let media: Media
    let listing: EpisodeListing
    @Binding var audio: AudioTrack
    let cover: String?
    let onPlay: (Int) -> Void
    @State private var query = ""
    @State private var block: Int?

    private var playable: Set<Int> { Set(listing.available(audio).map(\.number)) }

    /// Every episode the page knows: what this audio has, plus what hasn't aired anywhere yet.
    private var all: [EpisodeInfo] {
        let available = playable
        // Playable in this audio, or not out anywhere yet (shown dimmed with its air date).
        let rows = listing.episodes.filter { episode in
            available.contains(episode.number) || (!listing.subbed.contains(episode.number) && !listing.dubbed.contains(episode.number))
        }
        return order == "newest" ? rows.reversed() : rows
    }

    var body: some View {
        let blocks = EpisodeCatalog.blocks(all)
        let resume = library.history.shows[media.id]?.resumeEpisode
        let index = min(block ?? EpisodeCatalog.blockIndex(blocks, holding: resume), max(0, blocks.count - 1))
        let shown = query.isEmpty ? (blocks.isEmpty ? [] : blocks[index].episodes) : EpisodeCatalog.filter(all, query)
        VStack(alignment: .leading, spacing: 0) {
            controls(blocks: blocks, index: index)
            HStack {
                Text("\(all.count) episodes").font(AppFont.labelLarge).foregroundStyle(palette.onSurfaceVariant)
                Spacer()
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.vertical, 8)
            if shown.isEmpty {
                Text(query.isEmpty ? "No episode information is available yet." : "No episode matches \u{201C}\(query)\u{201D}.")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if layout == "grid" {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(shown) { episode in numberChip(episode) }
                }
                .padding(.horizontal, Metrics.pagePadding)
            } else {
                ForEach(shown) { episode in row(episode) }
            }
        }
    }

    private func controls(blocks: [EpisodeCatalog.Block], index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Audio", selection: $audio) {
                    Text("Sub").tag(AudioTrack.sub)
                    Text("Dub").tag(AudioTrack.dub)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .disabled(listing.dubbed.isEmpty)
                if all.count > EpisodeCatalog.browserMinimum {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(palette.onSurfaceVariant)
                        TextField("Filter episodes…", text: $query)
                            .font(AppFont.bodyMedium)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
                } else {
                    Spacer()
                }
                Button {
                    order = order == "newest" ? "oldest" : "newest"
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(width: 38, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
                }
                .accessibilityLabel(order == "newest" ? "Newest first" : "Oldest first")
                Menu {
                    let missing = (blocks.isEmpty ? [] : blocks[index].episodes).filter {
                        playable.contains($0.number) && DownloadStore.shared.record(mediaID: media.id, episode: $0.number, audio: audio) == nil
                    }
                    Button(DownloadQueue.batchLabel(count: missing.count, audio: audio), systemImage: "arrow.down.circle") {
                        for episode in missing {
                            DownloadStore.shared.enqueue(media, episode: episode.number, audio: audio, title: episode.title, thumbnail: episode.thumbnail)
                        }
                    }
                    .disabled(missing.isEmpty)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .frame(width: 38, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
                }
                .accessibilityLabel("Download these episodes")
                Button {
                    layout = layout == "grid" ? "list" : "grid"
                } label: {
                    Image(systemName: layout == "grid" ? "list.bullet" : "square.grid.2x2").frame(width: 38, height: 38)
                }
                .accessibilityLabel(layout == "grid" ? "Show as list" : "Show as grid")
            }
            .foregroundStyle(palette.onSurface)
            if blocks.count > 1 && query.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(blocks.indices, id: \.self) { item in
                            FilterChip(label: blocks[item].label, selected: item == index) { block = item }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 6)
    }

    private func row(_ episode: EpisodeInfo) -> some View {
        let canPlay = playable.contains(episode.number)
        let progress = library.history.progress(mediaID: media.id, episode: episode.number)
        let watched = progress?.isFinished == true
        let blur = AppearanceStore.shared.blurEpisodeImages
        return HStack(spacing: 13) {
            Color.clear
                .frame(width: 132, height: 74)
                .overlay {
                    RemoteImage(url: episode.thumbnail ?? cover.flatMap(URL.init(string:))) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill().blur(radius: blur && !watched ? 12 : 0)
                        } else {
                            palette.surfaceVariant
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if episode.isFiller {
                        PosterTag(text: "FILLER", container: Color.orange.opacity(0.9), content: .black, outlined: false)
                            .padding(.leading, 5)
                            .padding(.bottom, (progress?.fraction ?? 0) > 0.01 ? 12 : 5)
                    }
                }
                .overlay(alignment: (progress?.fraction ?? 0) > 0.01 ? .topTrailing : .bottomTrailing) {
                    PosterTag(text: "EP \(episode.number)").padding(5)
                }
                .overlay(alignment: .bottom) {
                    // A watched episode carries a full line (Android's watched underline), which is
                    // what the EP tag moves up to make room for.
                    if let progress, progress.fraction > 0.01 {
                        ProgressLine(fraction: progress.isFinished ? 1 : progress.fraction).padding(.horizontal, 6).padding(.bottom, 5)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // The watched eye sits on the still it marks (as on Android TV): stacked at the
                    // row's right edge with the download, testers couldn't tell which episode
                    // either button belonged to.
                    if canPlay {
                        Button {
                            library.setWatched(media, episode: episode.number, !watched)
                        } label: {
                            Image(systemName: watched ? "eye.fill" : "eye")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(watched ? palette.primary : .white)
                                .frame(width: 26, height: 26)
                                .background(.black.opacity(0.62), in: Circle())
                                .padding(4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(watched ? "Mark episode \(episode.number) unwatched" : "Mark episode \(episode.number) watched")
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title ?? "Episode \(episode.number)")
                    .font(AppFont.titleMedium)
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle(episode, canPlay: canPlay))
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // The download in line with its episode, centred on the row.
            if canPlay {
                DownloadButton(media: media, episode: episode, audio: audio)
            }
        }
        .frame(height: 74)
        .opacity(canPlay ? 1 : 0.38)
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            // A rule between episodes, so each row's buttons read as its own.
            Rectangle()
                .fill(palette.line)
                .frame(height: 1)
                .padding(.horizontal, Metrics.pagePadding)
        }
        .contentShape(Rectangle())
        .onTapGesture { if canPlay { onPlay(episode.number) } }
        .contextMenu {
            if canPlay {
                Button(watched ? "Mark unwatched" : "Mark watched", systemImage: watched ? "eye.slash" : "eye") {
                    library.setWatched(media, episode: episode.number, !watched)
                }
                if let saved = DownloadStore.shared.record(mediaID: media.id, episode: episode.number, audio: audio) {
                    Button(saved.isDone ? "Remove download" : "Cancel download", systemImage: "trash", role: .destructive) {
                        DownloadStore.shared.remove(saved.id)
                    }
                } else {
                    Button("Download", systemImage: "arrow.down.circle") {
                        DownloadStore.shared.enqueue(media, episode: episode.number, audio: audio, title: episode.title, thumbnail: episode.thumbnail)
                    }
                }
            }
        }
    }

    private func subtitle(_ episode: EpisodeInfo, canPlay: Bool) -> String {
        if !canPlay {
            if let aired = episode.airedOn, let date = Self.dayFormatter.date(from: aired) {
                return "Airs \(date.formatted(.dateTime.day().month(.abbreviated).year()))"
            }
            return "Not released yet"
        }
        let dub = listing.dubbed.contains(episode.number) && audio == .dub
        if episode.title != nil { return "Episode \(episode.number)" + (dub ? "  •  Dub" : "") }
        return dub ? "Dub" : (episode.duration.map { "\(Int($0 / 60)) min" } ?? "")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private func numberChip(_ episode: EpisodeInfo) -> some View {
        let canPlay = playable.contains(episode.number)
        let progress = library.history.progress(mediaID: media.id, episode: episode.number)
        return Button {
            if canPlay { onPlay(episode.number) }
        } label: {
            Text("\(episode.number)")
                .font(AppFont.titleSmall.monospacedDigit())
                .foregroundStyle(palette.onSurface)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(progress?.isFinished == true ? palette.secondaryContainer : palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(episode.isFiller ? Color.orange : palette.outline, lineWidth: 1))
                .overlay(alignment: .bottom) {
                    if let progress, progress.fraction > 0.01, !progress.isFinished {
                        ProgressLine(fraction: progress.fraction).padding(.horizontal, 6).padding(.bottom, 4)
                    }
                }
        }
        .buttonStyle(.plain)
        .opacity(canPlay ? 1 : 0.38)
        .disabled(!canPlay)
        .contextMenu {
            if canPlay {
                let watched = progress?.isFinished == true
                Button(watched ? "Mark unwatched" : "Mark watched") { library.setWatched(media, episode: episode.number, !watched) }
            }
        }
    }
}

// MARK: - Related tab

/// The Related tab, after Android's: the franchise as a running order on its shelves (seasons,
/// films, then the extras), then AniList's community picks for titles outside it. The chips narrow
/// to one shelf; the numbers stay franchise-wide, so they still say what comes first. One switch
/// draws everything as rows with artwork or as bare titles, and where the story's order differs
/// from the airing order the seasons offer it (the desktop's Chronological).
private struct RelatedTab: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", seasons = "Seasons", movies = "Movies", ovas = "OVAs", specials = "Specials", other = "Other", more = "More like this"
        var id: String { rawValue }
        var shelf: WatchOrder.Shelf? {
            switch self {
            case .seasons: return .seasons
            case .movies: return .movies
            case .ovas: return .ovas
            case .specials: return .specials
            case .other: return .other
            case .all, .more: return nil
            }
        }
    }

    @Environment(\.palette) private var palette
    /// Android's `related_layout`: "list" (rows with artwork) or "titles".
    @AppStorage("related_layout") private var layout = "list"
    @AppStorage("watch_order_story") private var storyOrder = false
    let entries: [WatchOrder.Entry]
    let suggestions: [Media]
    let loading: Bool
    let onWatch: (Media) -> Void
    @State private var filter: Filter = .all

    /// A franchise of one is this page and nothing else.
    private var franchise: [WatchOrder.Entry] { entries.count > 1 ? entries : [] }
    private var titlesOnly: Bool { layout == "titles" }

    private var filters: [Filter] {
        Filter.allCases.filter { item in
            switch item {
            case .all: return true
            case .more: return !suggestions.isEmpty
            default: return franchise.contains { $0.shelf == item.shelf }
            }
        }
    }

    /// A chip can lose its shelf between loads (the walk replaces the seeded chain).
    private var active: Filter { filters.contains(filter) ? filter : .all }

    private var shelves: [WatchOrder.Shelf] {
        guard active != .more else { return [] }
        return WatchOrder.Shelf.allCases.filter { shelf in
            (active == .all || active.shelf == shelf) && franchise.contains { $0.shelf == shelf }
        }
    }

    private var showsSuggestions: Bool { (active == .all || active == .more) && !suggestions.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Chips that only ever say "All" are furniture.
            if filters.count > 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(filters) { item in
                            FilterChip(label: item.rawValue, selected: active == item) { filter = item }
                        }
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                }
                .padding(.vertical, 6)
            }
            ForEach(Array(shelves.enumerated()), id: \.element) { index, shelf in
                let shelfEntries = ordered(franchise.filter { $0.shelf == shelf })
                header(shelf.label, count: shelfEntries.count, storyToggle: shelf == .seasons && hasStoryOrder, layoutToggle: index == 0)
                ForEach(shelfEntries) { entry in
                    if titlesOnly {
                        RelatedTitleRow(media: entry.media, meta: entry.metaLine, position: entry.position, isCurrent: entry.isCurrent)
                    } else {
                        WatchOrderRow(entry: entry) { onWatch(entry.media) }
                    }
                }
            }
            if showsSuggestions {
                header("More like this", count: suggestions.count, storyToggle: false, layoutToggle: shelves.isEmpty)
                ForEach(suggestions) { media in
                    if titlesOnly {
                        RelatedTitleRow(media: media, meta: media.relatedMetaLine)
                    } else {
                        SuggestionRow(media: media) { onWatch(media) }
                    }
                }
            }
            if franchise.isEmpty && suggestions.isEmpty {
                VStack(spacing: 12) {
                    if loading { ProgressView() }
                    Text(loading ? "Finding titles to recommend…" : "No recommendations found.")
                        .font(AppFont.bodyLarge)
                        .foregroundStyle(palette.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            }
        }
    }

    /// Whether the story's order differs from airing order anywhere.
    private var hasStoryOrder: Bool { franchise.contains { $0.chronological != $0.position } }

    private func ordered(_ list: [WatchOrder.Entry]) -> [WatchOrder.Entry] {
        storyOrder && hasStoryOrder ? list.sorted { $0.chronological < $1.chronological } : list
    }

    private func header(_ title: String, count: Int, storyToggle: Bool, layoutToggle: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).font(AppFont.titleMedium.weight(.bold)).foregroundStyle(palette.onSurface)
            Spacer(minLength: 0)
            if storyToggle {
                Menu {
                    Picker("Order", selection: $storyOrder) {
                        Text("Release order").tag(false)
                        Text("Story order").tag(true)
                    }
                } label: {
                    Text(storyOrder ? "Story order" : "Release order").font(AppFont.labelLarge).foregroundStyle(palette.primary)
                }
            }
            Text("\(count)").font(AppFont.labelMedium).foregroundStyle(palette.onSurfaceVariant)
            // One switch for the whole tab, on whichever heading comes first. The glyph shows the
            // layout a press switches to, as the episode toggle's does.
            if layoutToggle {
                Button {
                    layout = titlesOnly ? "list" : "titles"
                } label: {
                    Image(systemName: titlesOnly ? "rectangle.grid.1x2" : "list.bullet")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(palette.onSurface)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(titlesOnly ? "Show with artwork" : "Show titles only")
            }
        }
        .frame(minHeight: 40)
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }
}

/// A cover with the banner, then a plain tile, behind it: AniList doesn't always hand a relation
/// node its cover.
private struct RelatedArtwork: View {
    @Environment(\.palette) private var palette
    let media: Media
    let width: CGFloat

    var body: some View {
        palette.surfaceVariant
            .overlay {
                if let url = media.coverImage?.best ?? media.bannerURL {
                    RemoteImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                } else {
                    Image(systemName: "play.fill").foregroundStyle(palette.onSurfaceVariant.opacity(0.5))
                }
            }
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The trailing play button of a related row.
private struct RelatedPlayButton: View {
    @Environment(\.palette) private var palette
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 18))
                .foregroundStyle(palette.onSurface)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Watch \(title)")
    }
}

/// One entry of the watch guide: its place in the running order, its artwork, what it is, and a
/// play button. The page's own entry is listed, marked and inert, so the numbering doesn't skip.
private struct WatchOrderRow: View {
    @Environment(\.palette) private var palette
    let entry: WatchOrder.Entry
    let onWatch: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 0) {
            NavigationLink(value: entry.media) {
                HStack(spacing: 10) {
                    Text("\(entry.position)")
                        .font(AppFont.labelMedium.weight(.bold).monospacedDigit())
                        .foregroundStyle(entry.isCurrent ? palette.onPrimary : palette.onSurfaceVariant)
                        .frame(width: 26, height: 26)
                        .background(entry.isCurrent ? palette.primary : palette.surfaceVariant, in: Circle())
                    RelatedArtwork(media: entry.media, width: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.media.title.preferred)
                            .font(AppFont.titleSmall)
                            .foregroundStyle(palette.onSurface)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if !entry.metaLine.isEmpty {
                            Text(entry.metaLine).font(AppFont.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                        }
                        if entry.isCurrent {
                            Text("You are here").font(AppFont.labelSmall.weight(.bold)).foregroundStyle(palette.primary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(entry.isCurrent)
            RelatedPlayButton(title: entry.media.title.preferred, action: onWatch)
        }
        .padding(9)
        .background(entry.isCurrent ? palette.primary.opacity(0.12) : palette.surface, in: shape)
        .overlay(shape.strokeBorder(entry.isCurrent ? palette.primary : palette.outline, lineWidth: 1))
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 5)
    }
}

/// A "More like this" title: artwork, title, format and year, and a play button.
private struct SuggestionRow: View {
    @Environment(\.palette) private var palette
    let media: Media
    let onWatch: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let meta = [media.formatLabel, media.seasonYear.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        HStack(spacing: 0) {
            NavigationLink(value: media) {
                HStack(spacing: 12) {
                    RelatedArtwork(media: media, width: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(media.title.preferred)
                            .font(AppFont.titleMedium)
                            .foregroundStyle(palette.onSurface)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if !meta.isEmpty {
                            Text(meta).font(AppFont.bodyMedium).foregroundStyle(palette.onSurfaceVariant)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RelatedPlayButton(title: media.title.preferred, action: onWatch)
        }
        .padding(9)
        .background(palette.surface, in: shape)
        .overlay(shape.strokeBorder(palette.outline, lineWidth: 1))
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 6)
    }
}

/// The titles-only row: the title and one line of format, year and episodes. Guide entries keep
/// their number, and the page's own entry its accent; the artwork and play button are what it
/// leaves out.
private struct RelatedTitleRow: View {
    @Environment(\.palette) private var palette
    let media: Media
    let meta: String
    var position: Int?
    var isCurrent = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let line = isCurrent ? [meta, "You are here"].filter { !$0.isEmpty }.joined(separator: " · ") : meta
        NavigationLink(value: media) {
            HStack(spacing: 0) {
                if let position {
                    Text("\(position)")
                        .font(AppFont.labelMedium.weight(.bold).monospacedDigit())
                        .foregroundStyle(isCurrent ? palette.primary : palette.onSurfaceVariant)
                        .frame(width: 26, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title.preferred)
                        .font(AppFont.titleSmall)
                        .foregroundStyle(palette.onSurface)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !line.isEmpty {
                        Text(line)
                            .font(AppFont.bodySmall)
                            .foregroundStyle(isCurrent ? palette.primary : palette.onSurfaceVariant)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isCurrent ? palette.primary.opacity(0.12) : palette.surface, in: shape)
            .overlay(shape.strokeBorder(isCurrent ? palette.primary : palette.outline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 3)
    }
}

// MARK: - Cover preview

/// The cover, full screen, pinch to zoom (Android's `CoverImagePreview`).
private struct CoverPreview: View {
    @Environment(\.dismiss) private var dismiss
    let media: Media
    @State private var scale: CGFloat = 1
    @State private var settled: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteImage(url: media.coverImage?.best) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .scaleEffect(scale)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in scale = max(1, min(5, settled * value.magnification)) }
                    .onEnded { _ in settled = scale }
            )
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    scale = scale > 1 ? 1 : 2.5
                    settled = scale
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .padding()
            .accessibilityLabel("Close")
        }
        .overlay(alignment: .bottom) {
            Text(media.title.preferred).font(AppFont.titleSmall).foregroundStyle(.white).padding(.bottom, 30)
        }
    }
}
#endif
