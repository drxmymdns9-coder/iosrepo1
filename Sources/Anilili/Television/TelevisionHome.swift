#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// Measures shared by the TV layout's pages (Android's `AppDeviceProfile` on television).
enum TelevisionMetrics {
    /// The page's side margin: Android TV's 48.
    static let pagePadding: CGFloat = 48
    static let posterWidth: CGFloat = 168
    static let wideCardWidth: CGFloat = 380
    static let railSpacing: CGFloat = 20
}

/// Home in the TV layout, after Android's `TvHomeScreen`: a full-bleed spotlight under the top
/// navigation with the title's logo, facts, synopsis and its actions on the left, then the same
/// rows as the phone (Arrange Home's order) as large titled rails, Continue watching as wide cards.
extension HomeView {
    var televisionHome: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let heroHeight = min(max(proxy.size.height * 0.64, 440), 680) + safeTop
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    if let collections {
                        TelevisionHero(items: Array(collections.spotlight.prefix(8)), height: heroHeight, topInset: safeTop) { media in
                            let resume = library.history.shows[media.id]?.resumeEpisode ?? 1
                            resuming = PlayRequest(media: media, episode: resume, audio: preferredAudio, listing: .empty)
                        }
                        SigningBanner().padding(.horizontal, TelevisionMetrics.pagePadding - Metrics.pagePadding)
                        televisionRows(collections)
                        Button {
                            arranging = true
                        } label: {
                            Label("Arrange Home", systemImage: "slider.horizontal.3")
                                .font(AppFont.titleSmall)
                                .foregroundStyle(palette.primary)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 12)
                                .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    } else if let error {
                        ErrorState(message: error) { await load(force: true) }
                            .padding(.top, safeTop + 60)
                    } else {
                        LoadingState()
                            .frame(height: proxy.size.height)
                    }
                }
                .padding(.bottom, 40)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > heroHeight - safeTop - 40
            } action: { _, past in
                if router.televisionPastHero != past { router.televisionPastHero = past }
            }
            .onDisappear { router.televisionPastHero = false }
            .refreshable { await load(force: true) }
            .ignoresSafeArea(edges: .top)
        }
    }

    @ViewBuilder
    private func televisionRows(_ collections: AniListClient.HomeCollections) -> some View {
        ForEach(AppearanceStore.shared.homeLayout.visible) { row in
            switch row {
            case .continueWatching:
                TelevisionContinueRow(shows: Array(continueWatching.prefix(12))) { show in
                    resuming = PlayRequest(media: show.media, episode: show.resumeEpisode, audio: preferredAudio, listing: .empty)
                }
            case .forYou: TelevisionRail(title: row.label, items: personal.forYou)
            case .because:
                if let seed = personal.becauseSeed {
                    TelevisionRail(title: "Because you watched \(seed.title.preferred)", items: personal.because)
                }
            case .newest: TelevisionRail(title: row.label, items: collections.newest)
            case .trending: TelevisionRail(title: row.label, items: collections.spotlight)
            case .popular: TelevisionRail(title: row.label, items: collections.popular)
            case .topRated: TelevisionRail(title: row.label, items: collections.topRated)
            case .movies: TelevisionRail(title: row.label, items: collections.movies)
            case .upcoming: TelevisionRail(title: row.label, items: collections.upcoming)
            }
        }
    }
}

// MARK: - Spotlight

/// The spotlight: one title at a time across the whole width, swiped through or advancing every
/// eight seconds, its page dots at the bottom right as on Android TV.
private struct TelevisionHero: View {
    @Environment(\.palette) private var palette
    let items: [Media]
    let height: CGFloat
    let topInset: CGFloat
    let onPlay: (Media) -> Void
    @State private var page = 0

    var body: some View {
        if !items.isEmpty {
            ZStack(alignment: .bottomTrailing) {
                TabView(selection: $page) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, media in
                        TelevisionHeroPage(media: media, topInset: topInset, onPlay: onPlay)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? Color.white : .white.opacity(0.4))
                            .frame(width: index == page ? 26 : 7, height: 7)
                    }
                }
                .animation(.snappy, value: page)
                .padding(.trailing, TelevisionMetrics.pagePadding)
                .padding(.bottom, 28)
                .accessibilityHidden(true)
            }
            .frame(height: height)
            .task(id: page) {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, items.count > 1 else { return }
                withAnimation(.easeInOut(duration: 0.6)) { page = (page + 1) % items.count }
            }
        }
    }
}

private struct TelevisionHeroPage: View {
    @Environment(\.palette) private var palette
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    let media: Media
    let topInset: CGFloat
    let onPlay: (Media) -> Void
    @State private var logo: URL?

    var body: some View {
        let resume = library.history.shows[media.id]
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay {
                    RemoteImage(url: media.heroImage) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            (Color(hex: media.coverImage?.color) ?? palette.surfaceVariant).opacity(0.4)
                        }
                    }
                }
                .clipped()
            // Android TV's scrims: dark from the left for the text, into the page at the bottom.
            LinearGradient(stops: [.init(color: palette.background.opacity(0.94), location: 0),
                                   .init(color: palette.background.opacity(0.70), location: 0.34),
                                   .init(color: palette.background.opacity(0), location: 0.72)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.55), .init(color: palette.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Capsule().fill(palette.primary).frame(width: 4, height: 20)
                    Text(HeroCardLabels.kicker(media))
                        .font(AppFont.labelLarge.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.85))
                }
                title
                Text(HeroCardLabels.facts(media))
                    .font(AppFont.titleSmall.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                if let synopsis = media.description.map(HTML.plainDescription), !synopsis.isEmpty {
                    Text(synopsis)
                        .font(AppFont.bodyLarge)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(3)
                }
                HStack(spacing: 12) {
                    Button {
                        onPlay(media)
                    } label: {
                        Label(resume.map { "Continue Episode \($0.resumeEpisode)" } ?? "Watch now", systemImage: "play.fill")
                            .font(AppFont.titleSmall.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 22)
                            .frame(height: 50)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    NavigationLink(value: media) {
                        Label("Details", systemImage: "info.circle")
                            .font(AppFont.titleSmall.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .frame(height: 50)
                            .smokedGlass(.home, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        router.listSheet = media
                    } label: {
                        Image(systemName: library.watchlist.contains(media.id) || AccountStore.shared.statuses[media.id] != nil ? "checkmark" : "plus")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 50, height: 50)
                            .smokedGlass(.home, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add to list")
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.leading, TelevisionMetrics.pagePadding)
            .padding(.trailing, 24)
            .padding(.top, topInset + 12)
            .padding(.bottom, 64)
        }
        .foregroundStyle(.white)
        .task(id: media.id) {
            guard AppearanceStore.shared.seriesLogos else { return }
            logo = await MediaIndex.shared.logo(media.id)
        }
    }

    /// The series logo when there is one, else the name.
    @ViewBuilder
    private var title: some View {
        if let logo, AppearanceStore.shared.seriesLogos {
            RemoteImage(url: logo) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                        .frame(maxWidth: 460, maxHeight: 140, alignment: .leading)
                        .shadow(color: .black.opacity(0.45), radius: 10)
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
            .font(.system(size: 44, weight: .black))
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .shadow(color: .black.opacity(0.4), radius: 8)
    }
}

/// The spotlight's text lines, shared with the TV show page.
enum HeroCardLabels {
    /// "Airing · Episode 5 in 2d 4h", or "Trending now".
    static func kicker(_ media: Media) -> String {
        if let next = media.nextAiringEpisode {
            guard let seconds = next.timeUntilAiring, seconds > 0 else { return "EPISODE \(next.episode) OUT SOON" }
            let days = seconds / 86_400
            let hours = (seconds % 86_400) / 3_600
            let minutes = (seconds % 3_600) / 60
            let time = days > 0 ? "\(days)D \(hours)H" : hours > 0 ? "\(hours)H \(minutes)M" : "\(minutes)M"
            return "EPISODE \(next.episode) IN \(time)"
        }
        return "TRENDING NOW"
    }

    /// "★ 87%  •  TV  •  1999  •  24m  •  Action  •  Adventure" (Android TV's meta strip).
    static func facts(_ media: Media) -> String {
        var parts: [String] = []
        if let score = media.averageScore, score > 0 { parts.append("★ \(score)%") }
        if let format = media.formatLabel { parts.append(format) }
        if let year = media.seasonYear ?? media.startDate?.year { parts.append(String(year)) }
        if media.format == "MOVIE" {
            if let duration = media.duration, duration > 0 { parts.append("\(duration)m") }
        } else if let episodes = media.releasedEpisodes, episodes > 0 {
            parts.append("\(episodes) episodes")
        }
        parts += (media.genres ?? []).prefix(2)
        return parts.joined(separator: "  •  ")
    }
}

// MARK: - Rows

/// A row's title as Android TV sets it: large and bold, with a short rule after it.
struct TelevisionRowTitle: View {
    @Environment(\.palette) private var palette
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                Text(title)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(1)
                Capsule().fill(palette.onSurfaceVariant.opacity(0.7)).frame(width: 44, height: 3)
            }
            if let subtitle {
                Text(subtitle).font(AppFont.labelMedium).foregroundStyle(palette.onSurfaceVariant)
            }
        }
        .padding(.horizontal, TelevisionMetrics.pagePadding)
    }
}

/// A rail of posters at the TV layout's size.
struct TelevisionRail: View {
    let title: String
    let items: [Media]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                TelevisionRowTitle(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: TelevisionMetrics.railSpacing) {
                        ForEach(items) { media in
                            NavigationLink(value: media) {
                                AnimeCard(media: media).frame(width: TelevisionMetrics.posterWidth)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, TelevisionMetrics.pagePadding)
                }
            }
        }
    }
}

/// Continue watching as Android TV draws it: wide artwork cards with the title and episode on the
/// picture, the episode's progress along the bottom, details and remove in the top corners.
private struct TelevisionContinueRow: View {
    @Environment(\.palette) private var palette
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    let shows: [WatchHistory.Show]
    let resume: (WatchHistory.Show) -> Void
    @State private var removing: WatchHistory.Show?

    var body: some View {
        if !shows.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                TelevisionRowTitle(title: "Continue watching")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: TelevisionMetrics.railSpacing + 8) {
                        ForEach(shows, id: \.media.id) { show in
                            card(show)
                        }
                    }
                    .padding(.horizontal, TelevisionMetrics.pagePadding)
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
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return Color.clear
            .frame(width: TelevisionMetrics.wideCardWidth, height: TelevisionMetrics.wideCardWidth * 9 / 16 * 0.82)
            .overlay {
                RemoteImage(url: show.media.heroImage) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { palette.surfaceVariant }
                }
            }
            .overlay(LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.78)], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(show.media.title.preferred)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("Ep \(episode)")
                        .font(AppFont.titleSmall)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
            .overlay(alignment: .bottom) { ProgressStrip(fraction: max(0.03, fraction)) }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .contentShape(shape)
            .onTapGesture { resume(show) }
            .overlay(alignment: .top) {
                HStack {
                    CardCornerAction(systemImage: "info", label: "Details for \(show.media.title.preferred)") {
                        router.push(show.media)
                    }
                    Spacer()
                    CardCornerAction(systemImage: "xmark", label: "Remove \(show.media.title.preferred) from Continue watching") {
                        removing = show
                    }
                }
                .padding(14 - CardCornerAction.touchInset)
            }
            .contextMenu { ListActions(media: show.media) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(show.media.title.preferred), episode \(episode)")
    }
}
#endif
