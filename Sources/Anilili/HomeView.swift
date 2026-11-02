#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// Home, after the Android app's phone layout: a spotlight carousel running under a transparent
/// header, then the viewer's rows in the order Arrange Home keeps.
struct HomeView: View {
    @Environment(LibraryStore.self) var library
    @Environment(AppRouter.self) var router
    @Environment(\.palette) var palette
    @State var collections: AniListClient.HomeCollections?
    @State var personal = PersonalRows()
    @State private var rollingDice = false
    @State private var touring = false
    @State var error: String?
    @State private var heroBottom: CGFloat = .infinity
    @State var arranging = false
    @State var resuming: PlayRequest?
    /// Settings → Content → Only episodes you can watch, and the schedule it judges rows by.
    @AppStorage(ContinueVisibility.key) private var onlyWatchable = false
    @State private var upcoming: ContinueVisibility.Upcoming = [:]
    @State private var judgedAt = Date()
    private var television = TelevisionLayout()

    /// The genre shortcuts Android pins under the header.
    static let genres = [
        "Action", "Adventure", "Comedy", "Drama", "Fantasy", "Romance",
        "Sci-Fi", "Slice of Life", "Sports", "Supernatural", "Mystery", "Thriller",
    ]

    var body: some View {
        Group {
            if television.isOn {
                televisionHome
            } else {
                phoneHome
            }
        }
        .background(palette.background)
        .toolbar(.hidden, for: .navigationBar)
        .task { if collections == nil { await load(force: false) } }
        .task(id: "\(library.history.continueWatching.first?.media.id ?? 0)-\(AccountStore.shared.library.entries.count)") { await loadPersonal() }
        .task(id: onlyWatchable) {
            guard onlyWatchable else { return }
            upcoming = await ScheduleService.shared.upcoming()
            // Judge again when the first hidden row's episode can be played, as Android does.
            while !Task.isCancelled {
                judgedAt = Date()
                let shows = AccountStore.shared.continueWatching(library.history)
                guard let next = shows.compactMap({ ContinueVisibility.returnsAt($0, upcoming: upcoming, now: judgedAt) }).min() else { break }
                try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            }
        }
        .sheet(isPresented: $arranging) { ArrangeHomeSheet() }
        .fullScreenCover(item: $resuming) { WatchView(request: $0) }
        .sheet(isPresented: $touring) { WhatsNewTour() }
        .task {
            // Once Home has drawn, so the rows it talks about are behind it.
            guard WhatsNewTour.shouldShow else { return }
            try? await Task.sleep(for: .seconds(1.2))
            touring = true
        }
        .fullScreenCover(isPresented: $rollingDice) {
            RandomDeckView { router.push($0) }
                .environment(\.palette, palette)
                .environment(library)
        }
        .onChange(of: personal.forYou.map(\.id)) { _, _ in RandomDeckModel.shared.taste = personal.forYou }
    }

    /// The phone's Home: the spotlight under a transparent header, the rows, and the dice.
    private var phoneHome: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let headerHeight = safeTop + HomeHeader.barHeight + HomeHeader.pillRowHeight
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let collections {
                        HeroPager(items: Array(collections.spotlight.prefix(6)), topInset: headerHeight)
                            .background {
                                GeometryReader { hero in
                                    Color.clear.preference(key: HeroBottomKey.self, value: hero.frame(in: .named("home")).maxY)
                                }
                            }
                        SigningBanner()
                        rows(collections)
                        arrangeButton
                    } else if let error {
                        ErrorState(message: error) { await load(force: true) }
                            .padding(.top, headerHeight + 40)
                    } else {
                        LoadingState()
                            .frame(height: proxy.size.height)
                    }
                }
                .padding(.bottom, 24)
            }
            .coordinateSpace(name: "home")
            .tucksChrome()
            .onPreferenceChange(HeroBottomKey.self) { heroBottom = $0 }
            .refreshable { await load(force: true) }
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .top) {
                HomeHeader(safeTop: safeTop, overHero: heroBottom > headerHeight) { genre in
                    router.openGenre(genre)
                }
                .ignoresSafeArea(edges: .top)
                .offset(y: router.chromeHidden ? -(headerHeight + 20) : 0)
            }
            .overlay(alignment: .bottomTrailing) {
                FloatingNavDisc(systemImage: "dice.fill", label: "Pick something at random") { rollingDice = true }
                    .padding(.trailing, 16)
                    .padding(.bottom, 14)
                    .offset(y: router.chromeHidden ? 140 : 0)
            }
        }
    }

    /// Continue Watching as Home draws it: less the titles caught up with their broadcast, when
    /// Settings asks. My List keeps them.
    var continueWatching: [WatchHistory.Show] {
        let shows = AccountStore.shared.continueWatching(library.history)
        return onlyWatchable ? ContinueVisibility.visible(shows, upcoming: upcoming, now: judgedAt) : shows
    }

    // MARK: - Rows

    @ViewBuilder
    private func rows(_ collections: AniListClient.HomeCollections) -> some View {
        ForEach(AppearanceStore.shared.homeLayout.visible) { row in
            switch row {
            case .continueWatching:
                ContinueRail(shows: Array(continueWatching.prefix(12))) { show in
                    resuming = PlayRequest(media: show.media, episode: show.resumeEpisode, audio: preferredAudio, listing: .empty)
                }
            case .forYou:
                MediaRail(title: row.label, items: personal.forYou, expandable: false)
            case .because:
                if let seed = personal.becauseSeed {
                    MediaRail(title: "Because you watched \(seed.title.preferred)", items: personal.because, expandable: false)
                }
            case .newest: MediaRail(title: row.label, items: collections.newest, row: row)
            case .trending: MediaRail(title: row.label, items: collections.spotlight, row: row)
            case .popular: MediaRail(title: row.label, items: collections.popular, row: row)
            case .topRated: MediaRail(title: row.label, items: collections.topRated, row: row)
            case .movies: MediaRail(title: row.label, items: collections.movies, row: row)
            case .upcoming: MediaRail(title: row.label, items: collections.upcoming, row: row)
            }
        }
    }

    private var arrangeButton: some View {
        Button {
            arranging = true
        } label: {
            Label("Arrange Home", systemImage: "slider.horizontal.3")
                .font(AppFont.labelLarge)
                .foregroundStyle(palette.primary)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    var preferredAudio: AudioTrack { PlaybackSettings.preferredAudio }

    // MARK: - Loading

    func load(force: Bool) async {
        do {
            let fresh = try await AniListClient.shared.homeCollections(hideAdult: ContentSettings.hideAdult)
            collections = fresh
            error = nil
            Log.info("home", "rows: spotlight \(fresh.spotlight.count), newest \(fresh.newest.count), popular \(fresh.popular.count), movies \(fresh.movies.count), top \(fresh.topRated.count), upcoming \(fresh.upcoming.count)")
        } catch {
            Log.error("home", "feed failed: \(Log.describe(error))")
            if collections == nil { self.error = error.localizedDescription }
        }
    }

    /// For You and Because you watched, from AniList's community recommendations for what the
    /// viewer has been watching. Empty for someone with nothing watched, and the rows hide.
    private func loadPersonal() async {
        if await loadPersonalFromGraph() { return }
        let recent = library.history.continueWatching.prefix(3).map(\.media)
        guard let seed = recent.first else {
            personal = PersonalRows()
            return
        }
        let watched = Set(library.history.shows.keys)
        var forYou: [Media] = []
        var because: [Media] = []
        for (index, media) in recent.enumerated() {
            guard let picks = try? await AniListClient.shared.recommendations(id: media.id) else { continue }
            let fresh = picks.filter { !watched.contains($0.id) && !(ContentSettings.hideAdult && $0.isAdult == true) }
            if index == 0 { because = fresh }
            forYou += fresh
        }
        var seen = Set<Int>()
        forYou = forYou.filter { seen.insert($0.id).inserted }.sorted { ($0.averageScore ?? 0) > ($1.averageScore ?? 0) }
        personal = PersonalRows(forYou: Array(forYou.prefix(20)), becauseSeed: seed, because: because)
        Log.info("home", "personal rows: for you \(personal.forYou.count), because \(seed.title.preferred) \(because.count)")
    }

    /// For You and Because you watched from the media index's neighbour graph, as Android and the
    /// desktop draw them: the account's list and this device's history as taste, each franchise
    /// one seed. False when there's no graph or nothing to go on (AniList's recommendations then).
    private func loadPersonalFromGraph() async -> Bool {
        guard let graph = await MediaIndex.shared.neighbourGraph() else { return false }
        let now = Int(Date().timeIntervalSince1970)
        let account = AccountStore.shared.library
        let list = account.entries.map {
            Recommendations.Rating(id: $0.media.id, status: $0.status, score: $0.score, updatedAt: Int($0.updatedAt.timeIntervalSince1970))
        }
        let shows = library.history.continueWatching
        let played = shows.map {
            Recommendations.Played(id: $0.media.id, episodesWatched: $0.episodes.values.filter(\.isFinished).count,
                                   updatedAt: Int($0.updatedAt.timeIntervalSince1970))
        }
        let signals = Recommendations.signals(list: list, played: played, feedback: DiceFeedback.all, now: now)
        guard !signals.isEmpty else { return false }
        let exclude = Set(library.history.shows.keys).union(account.entries.map(\.media.id))
        let hideAdult = ContentSettings.hideAdult
        let forYou = Recommendations.recommend(graph, signals: signals, exclude: exclude, hideAdult: hideAdult, limit: 20)
        let seedID = Recommendations.featuredSeed(graph, list: list, played: played, now: now)
        let because = seedID.map { Recommendations.because(graph, seed: $0, exclude: exclude, hideAdult: hideAdult, limit: 20) } ?? []
        var wanted = (forYou + because).map(\.id)
        let knownSeed = seedID.flatMap { id in shows.first { $0.media.id == id }?.media ?? account.entries.first { $0.media.id == id }?.media }
        if let seedID, knownSeed == nil { wanted.append(seedID) }
        guard let fetched = try? await AniListClient.shared.media(ids: Array(Set(wanted))) else { return false }
        let byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visible: (Media) -> Bool = { !(hideAdult && $0.isAdult == true) }
        personal = PersonalRows(
            forYou: forYou.compactMap { byID[$0.id] }.filter(visible),
            becauseSeed: knownSeed ?? seedID.flatMap { byID[$0] },
            because: because.compactMap { byID[$0.id] }.filter(visible)
        )
        Log.info("home", "personal rows from the neighbour graph: for you \(personal.forYou.count) from \(signals.count) signals, because \(personal.becauseSeed?.title.preferred ?? "-") \(personal.because.count)")
        return !personal.forYou.isEmpty
    }

}

struct PersonalRows {
    var forYou: [Media] = []
    var becauseSeed: Media?
    var because: [Media] = []
}

private struct HeroBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The header over Home: the wordmark, notifications and the schedule, with the genre pills under
/// them. Transparent while the spotlight is behind it; glass once the page scrolls past.
private struct HomeHeader: View {
    @Environment(\.palette) private var palette
    let safeTop: CGFloat
    let overHero: Bool
    let onGenre: (String?) -> Void

    static let barHeight: CGFloat = 56
    static let pillRowHeight: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Wordmark(height: 22)
                Spacer()
                NavigationLink(value: Route.notifications) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .overlay(alignment: .topTrailing) {
                            let unread = AccountStore.shared.unreadNotifications
                            if unread > 0 {
                                Text(unread > 99 ? "99+" : "\(unread)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .frame(minWidth: 17, minHeight: 17)
                                    .background(Color.red, in: Capsule())
                                    .offset(x: -3, y: 5)
                            }
                        }
                }
                .accessibilityLabel(AccountStore.shared.unreadNotifications > 0 ? "Notifications, \(AccountStore.shared.unreadNotifications) unread" : "Notifications")
                NavigationLink(value: Route.schedule) {
                    Image(systemName: "calendar")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Airing schedule")
            }
            .foregroundStyle(.white)
            .padding(.leading, Metrics.pagePadding)
            .padding(.trailing, 8)
            .frame(height: Self.barHeight)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    GenrePill(label: "All", highlighted: true) { onGenre(nil) }
                    ForEach(HomeView.genres, id: \.self) { genre in
                        GenrePill(label: genre, highlighted: false) { onGenre(genre) }
                    }
                }
                .padding(.horizontal, Metrics.pagePadding)
            }
            .frame(height: Self.pillRowHeight - 12)
            .padding(.bottom, 12)
        }
        .padding(.top, safeTop)
        .background {
            ZStack {
                if overHero {
                    // A soft shade keeps the white glyphs readable over bright artwork.
                    LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                } else if AppearanceStore.shared.glassEnabled(.home) {
                    Rectangle().fill(.ultraThinMaterial).overlay(palette.background.opacity(0.55))
                } else {
                    palette.background.opacity(0.97)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: overHero)
        }
    }
}

/// One genre shortcut: smoked glass over the spotlight, the accent fill when selected.
struct GenrePill: View {
    @Environment(\.palette) private var palette
    let label: String
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(AppFont.labelLarge.weight(highlighted ? .bold : .semibold))
                .foregroundStyle(highlighted ? palette.onPrimary : .white.opacity(0.92))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background {
                    if highlighted {
                        Capsule().fill(palette.primary)
                    }
                }
                .modifier(PillGlass(enabled: !highlighted))
                .overlay(Capsule().strokeBorder(highlighted ? .clear : .white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct PillGlass: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.smokedGlass(.home, in: Capsule())
        } else {
            content
        }
    }
}

// MARK: - Spotlight

/// The spotlight carousel: six trending titles, advancing every seven seconds.
private struct HeroPager: View {
    @Environment(\.palette) private var palette
    let items: [Media]
    let topInset: CGFloat
    @State private var page = 0

    var body: some View {
        if !items.isEmpty {
            let height = topInset + 334
            ZStack(alignment: .bottom) {
                TabView(selection: $page) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, media in
                        HeroCard(media: media, index: index, count: items.count, topInset: topInset)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? palette.primary : .white.opacity(0.4))
                            .frame(width: index == page ? 18 : 5, height: 5)
                    }
                }
                .animation(.snappy, value: page)
                .padding(.bottom, 10)
            }
            .frame(height: height)
            .task(id: page) {
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled, items.count > 1 else { return }
                withAnimation(.easeInOut(duration: 0.5)) { page = (page + 1) % items.count }
            }
        }
    }
}

private struct HeroCard: View {
    @Environment(\.palette) private var palette
    let media: Media
    let index: Int
    let count: Int
    let topInset: CGFloat
    /// The series logo from the media index, in place of the title (Appearance → Series logos).
    @State private var logo: URL?

    var body: some View {
        NavigationLink(value: media) {
            ZStack {
                // The cover fills a phone's near-square hero far better than a 1900x400 banner.
                Color.clear
                    .overlay {
                        RemoteImage(url: media.coverImage?.best ?? media.heroImage) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                (Color(hex: media.coverImage?.color) ?? palette.surfaceVariant).opacity(0.5)
                            }
                        }
                    }
                    .clipped()
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.30), location: 0),
                        .init(color: .black.opacity(0.12), location: 0.42),
                        .init(color: .black.opacity(0.45), location: 0.72),
                        .init(color: palette.background, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        if let countdown = Self.countdown(media) {
                            HeroPill {
                                Image(systemName: "clock").font(.system(size: 12, weight: .semibold))
                                Text(countdown).font(AppFont.labelMedium.weight(.semibold))
                            }
                        }
                        Spacer()
                        if count > 1 {
                            HeroPill {
                                Text("\(index + 1)").font(AppFont.labelMedium.weight(.bold))
                                Text(" / \(count)").font(AppFont.labelSmall).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }
                    .padding(.top, topInset)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 14)
                    Spacer(minLength: 0)
                    VStack(spacing: 0) {
                        HeroMetaRow(media: media)
                        title.padding(.top, 10)
                        let genres = (media.genres ?? []).prefix(3).joined(separator: "  ·  ")
                        if !genres.isEmpty {
                            HeroPill { Text(genres).font(AppFont.labelMedium) }
                                .padding(.top, 12)
                        }
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 26)
                    .padding(.bottom, 22)
                }
            }
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open details for \(media.title.preferred)")
        .task(id: media.id) {
            guard AppearanceStore.shared.seriesLogos else { return }
            logo = await MediaIndex.shared.logo(media.id)
        }
    }

    /// The series logo when there is one, else the name; the name also shows while it loads.
    @ViewBuilder
    private var title: some View {
        if let logo, AppearanceStore.shared.seriesLogos {
            RemoteImage(url: logo) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                        .frame(maxWidth: 280, maxHeight: 96)
                        .shadow(color: .black.opacity(0.5), radius: 8)
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
            .font(AppFont.headlineMedium)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
    }

    /// "EP 4  5D 8H": the biggest two non-zero units, or nil when nothing is airing.
    static func countdown(_ media: Media) -> String? {
        guard let next = media.nextAiringEpisode else { return nil }
        guard let seconds = next.timeUntilAiring, seconds > 0 else { return "EP \(next.episode) SOON" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let time = days > 0 ? "\(days)D \(hours)H" : hours > 0 ? "\(hours)H \(minutes)M" : "\(minutes)M"
        return "EP \(next.episode)  \(time)"
    }
}

/// The hero's centred strip: format, released episodes, score, runtime.
private struct HeroMetaRow: View {
    let media: Media

    /// Android's warm gold for the hero's star.
    private static let star = Color(argb: 0xFFEF_C66B)

    private struct Cell {
        var icon: String?
        var text: String
        var gold = false
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if index > 0 {
                    Text("•").font(AppFont.labelMedium).foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 8)
                }
                HStack(spacing: 3) {
                    if let icon = cell.icon {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(cell.gold ? Self.star : .white)
                    }
                    Text(cell.text).font(AppFont.labelMedium.weight(.semibold))
                }
            }
        }
    }

    private var cells: [Cell] {
        let released = media.nextAiringEpisode.map { $0.episode - 1 } ?? media.episodes
        var cells: [Cell] = []
        if let format = media.formatLabel { cells.append(Cell(icon: nil, text: format)) }
        if let released, released > 0 { cells.append(Cell(icon: "captions.bubble.fill", text: "\(released)")) }
        if let score = media.averageScore, score > 0 { cells.append(Cell(icon: "star.fill", text: "\(score)", gold: true)) }
        if let duration = media.duration, duration > 0 { cells.append(Cell(icon: "clock", text: "\(duration) mins")) }
        return cells
    }
}

/// A translucent rounded chip for the hero's corner tags and genre line.
private struct HeroPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 5) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .smokedGlass(.home, in: Capsule(), liveTint: 0.22, paintedTint: 0.42)
    }
}

// MARK: - Continue Watching

/// Android's Continue Watching rail: 16:9 cards with the details and remove buttons in the corners
/// and the episode's progress along the bottom. A tap resumes; a long press manages.
private struct ContinueRail: View {
    @Environment(\.palette) private var palette
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    let shows: [WatchHistory.Show]
    let resume: (WatchHistory.Show) -> Void
    @State private var removing: WatchHistory.Show?

    var body: some View {
        if !shows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                RailTitle(title: "Continue Watching", subtitle: "Long-press a title to move it on your anime list")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Metrics.railSpacing) {
                        ForEach(shows, id: \.media.id) { show in
                            card(show)
                        }
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 12)
                }
            }
            .confirmationDialog(
                removing.map { "Remove \($0.media.title.preferred)?" } ?? "",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let removing {
                        if library.history.shows[removing.media.id] != nil {
                            library.remove(mediaID: removing.media.id)
                        } else {
                            AccountStore.shared.dismissSeed(removing.media.id)
                        }
                    }
                    removing = nil
                }
            } message: {
                Text("It comes off this row only.")
            }
        }
    }

    private func card(_ show: WatchHistory.Show) -> some View {
        let episode = show.resumeEpisode
        let fraction = show.episodes[episode]?.fraction ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    RemoteImage(url: show.media.heroImage) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() } else { palette.surfaceVariant }
                    }
                }
                .overlay(Color.black.opacity(0.3))
                .overlay { Image(systemName: "play.fill").font(.system(size: 20)).foregroundStyle(.white) }
                .overlay(alignment: .bottom) { ProgressStrip(fraction: max(0.03, fraction)) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { resume(show) }
                // Above the resume tap, not inside it, so a touch on a corner button never also
                // starts the episode.
                .overlay(alignment: .top) {
                    HStack {
                        CardCornerAction(systemImage: "info", label: "Details for \(show.media.title.preferred)") {
                            router.push(show.media)
                        }
                        Spacer()
                        CardCornerAction(systemImage: "xmark", label: "Remove \(show.media.title.preferred) from Continue Watching") {
                            removing = show
                        }
                    }
                    .padding(5 - CardCornerAction.touchInset)
                }
            Text(show.media.title.preferred)
                .font(AppFont.labelLarge)
                .foregroundStyle(palette.onSurface)
                .lineLimit(1)
                .padding(.top, 6)
            Text("Episode \(episode)")
                .font(AppFont.labelSmall)
                .foregroundStyle(palette.onSurfaceVariant)
        }
        .frame(width: 174)
        .contextMenu { ListActions(media: show.media) }
    }
}

/// A 4-point progress strip along the bottom of a thumbnail.
struct ProgressStrip: View {
    @Environment(\.palette) private var palette
    let fraction: Double

    var body: some View {
        GeometryReader { bar in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.25))
                Rectangle().fill(palette.primary).frame(width: bar.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Arrange Home

/// Android's Arrange Home dialog: every row, in order, each switchable.
struct ArrangeHomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var layout = AppearanceStore.shared.homeLayout

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(layout.order) { row in
                        Toggle(isOn: Binding(
                            get: { !layout.hidden.contains(row) },
                            set: { layout = layout.withHidden(row, !$0) }
                        )) {
                            Text(row.label)
                        }
                        .tint(palette.switchTint)
                    }
                    .onMove { source, destination in
                        layout.order.move(fromOffsets: source, toOffset: destination)
                    }
                } footer: {
                    Text("Drag to reorder. Rows with nothing in them yet stay hidden until they have.")
                }
                Section {
                    Button("Reset to default") { layout = .standard }
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle("Arrange Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        AppearanceStore.shared.setHomeLayout(layout)
                        Log.info("home", "layout → \(layout.encode())")
                        dismiss()
                    }
                }
            }
        }
        .tint(palette.primary)
        .presentationDetents([.medium, .large])
    }
}
#endif
