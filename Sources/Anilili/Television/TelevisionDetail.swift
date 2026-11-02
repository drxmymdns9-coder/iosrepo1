#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// The show page in the TV layout, after Android's `TvDetailScreen`: the artwork across the whole
/// page with the title, the episode to continue, the facts and synopsis on the left, the actions
/// under them, then Episodes / Related / About, the episodes as a rail of wide stills.
extension DetailView {
    var televisionPage: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                televisionBackdrop
                    .frame(width: proxy.size.width, height: proxy.size.height + proxy.safeAreaInsets.top)
                    .ignoresSafeArea(edges: .top)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        televisionHeader
                            .frame(maxWidth: 720, alignment: .leading)
                            .padding(.top, max(24, proxy.size.height * 0.12))
                        televisionActions
                        televisionTabs
                        televisionTabContent
                    }
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { shareButton } }
    }

    // MARK: - Backdrop and header

    /// The resume episode's still when there is one, as Android TV shows the focused episode's;
    /// else the banner, darkened from the left and into the page below.
    private var televisionBackdrop: some View {
        let still = listing?.episode(resumeTarget(listing?.available(audio).map(\.number) ?? []))?.thumbnail
        return Color.clear
            .overlay {
                RemoteImage(url: still ?? media.heroImage) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        (Color(hex: media.coverImage?.color) ?? palette.surfaceVariant).opacity(0.35)
                    }
                }
            }
            .clipped()
            .overlay(LinearGradient(stops: [.init(color: palette.background.opacity(0.95), location: 0),
                                            .init(color: palette.background.opacity(0.72), location: 0.4),
                                            .init(color: palette.background.opacity(0.35), location: 1)],
                                    startPoint: .leading, endPoint: .trailing))
            .overlay(LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: palette.background, location: 0.92)],
                                    startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
    }

    private var televisionHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            SeriesTitle(media: media, logo: logo)
                .frame(maxWidth: 520, maxHeight: 130, alignment: .bottomLeading)
                .fixedSize(horizontal: false, vertical: true)
            if let line = continueLine {
                Text(line)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(1)
            }
            HStack(spacing: 14) {
                Text(HeroCardLabels.facts(media))
                    .font(AppFont.titleSmall.weight(.semibold))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(1)
                if let studio = media.mainStudio, let name = studio.name {
                    Button {
                        if let id = studio.id { router.openStudio(id: id, name: name) }
                    } label: {
                        Text(name)
                            .font(AppFont.labelLarge.weight(.semibold))
                            .foregroundStyle(palette.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let synopsis = media.description.map(HTML.plainDescription), !synopsis.isEmpty {
                Text(synopsis)
                    .font(AppFont.bodyLarge)
                    .foregroundStyle(palette.onSurface.opacity(0.85))
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, TelevisionMetrics.pagePadding)
    }

    /// "E2 - Tavoo", the episode Continue would play, when the viewer has started the show.
    private var continueLine: String? {
        guard !isMovie, resumeShow != nil, let listing else { return nil }
        let episode = resumeTarget(listing.available(audio).map(\.number))
        let title = listing.episode(episode)?.title
        return "E\(episode)" + (title.map { " - \($0)" } ?? "")
    }

    // MARK: - Actions

    private var televisionActions: some View {
        let available = listing?.available(audio).map(\.number) ?? []
        let saved = library.watchlist.contains(media.id)
        let status = AccountStore.shared.statuses[media.id]
        return HStack(spacing: 14) {
            Button {
                play(resumeTarget(available), available: available)
            } label: {
                HStack(spacing: 10) {
                    if case .loading = listings[selectedSeason] ?? .loading {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(watchLabel(available).replacingOccurrences(of: "Continue ", with: "Continue E"))
                }
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 26)
                .frame(height: 54)
                .background(available.isEmpty ? Color.white.opacity(0.4) : .white, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(available.isEmpty)
            Button {
                router.listSheet = media
            } label: {
                Label(status?.label ?? (saved ? "In library" : "Add to list"), systemImage: status != nil || saved ? "checkmark" : "plus")
                    .font(AppFont.titleSmall.weight(.semibold))
                    .foregroundStyle(palette.onSurface)
                    .padding(.horizontal, 20)
                    .frame(height: 54)
                    .smokedGlass(.details, in: Capsule())
            }
            .buttonStyle(.plain)
            if status != nil {
                let score = AccountStore.shared.score(of: media.id)
                Button {
                    router.scoreSheet = media
                } label: {
                    Label(score.map { "\(ListScore.format($0)) / 10" } ?? "Rate", systemImage: score == nil ? "star" : "star.fill")
                        .font(AppFont.titleSmall.weight(.semibold))
                        .foregroundStyle(palette.onSurface)
                        .padding(.horizontal, 20)
                        .frame(height: 54)
                        .smokedGlass(.details, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if !isMovie, let listing {
                let missing = listing.available(audio).filter {
                    DownloadStore.shared.record(mediaID: seasonMedia.id, episode: $0.number, audio: audio) == nil
                }
                Menu {
                    Button(DownloadQueue.batchLabel(count: missing.count, audio: audio), systemImage: "arrow.down.circle") {
                        for episode in missing {
                            DownloadStore.shared.enqueue(seasonMedia, episode: episode.number, audio: audio, title: episode.title, thumbnail: episode.thumbnail)
                        }
                    }
                    .disabled(missing.isEmpty)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(palette.onSurface)
                        .frame(width: 54, height: 54)
                        .smokedGlass(.details, in: Circle())
                }
                .accessibilityLabel("Download this season")
            }
            Button {
                showingCover = true
            } label: {
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.onSurface)
                    .frame(width: 54, height: 54)
                    .smokedGlass(.details, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View the cover")
        }
        .padding(.horizontal, TelevisionMetrics.pagePadding)
    }

    // MARK: - Tabs

    private var televisionTabs: some View {
        let tabs: [Tab] = isMovie ? [.related, .home] : [.episodes, .related, .home]
        let current = shownTelevisionTab
        return HStack(spacing: 10) {
            ForEach(tabs) { item in
                Button {
                    televisionTab = item
                } label: {
                    Text(item == .home ? "About" : item.rawValue)
                        .font(AppFont.titleSmall.weight(.bold))
                        .foregroundStyle(current == item ? palette.onSecondaryContainer : palette.onSurfaceVariant)
                        .padding(.horizontal, 24)
                        .frame(height: 46)
                        .background(current == item ? palette.secondaryContainer : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, TelevisionMetrics.pagePadding)
    }

    private var shownTelevisionTab: Tab {
        isMovie && televisionTab == .episodes ? .home : televisionTab
    }

    @ViewBuilder
    private var televisionTabContent: some View {
        switch shownTelevisionTab {
        case .episodes:
            televisionEpisodes
        case .related:
            relatedTab
                .frame(maxWidth: 960, alignment: .leading)
                .padding(.horizontal, TelevisionMetrics.pagePadding - Metrics.pagePadding)
        case .home:
            DetailHomeTab(media: media)
                .frame(maxWidth: 960, alignment: .leading)
                .padding(.horizontal, TelevisionMetrics.pagePadding - Metrics.pagePadding)
        }
    }

    // MARK: - Episodes

    @ViewBuilder
    private var televisionEpisodes: some View {
        VStack(alignment: .leading, spacing: 16) {
            televisionEpisodeControls
            switch listings[selectedSeason] ?? .loading {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading episodes…").font(AppFont.bodyMedium).foregroundStyle(palette.onSurfaceVariant)
                }
                .padding(.horizontal, TelevisionMetrics.pagePadding)
                .padding(.vertical, 30)
            case .failed(let message):
                ErrorState(message: message) { await loadEpisodes(selectedSeason, force: true) }
            case .loaded(let listing):
                TelevisionEpisodeRail(
                    media: seasonMedia,
                    listing: listing,
                    audio: audio,
                    episodes: televisionShownEpisodes(listing),
                    resume: library.history.shows[seasonMedia.id]?.resumeEpisode,
                    fallbackStill: seasonMedia.heroImage ?? media.heroImage,
                    nextAiring: seasonMedia.nextAiringEpisode,
                    onPlay: { number in play(number, available: listing.available(audio).map(\.number)) }
                )
            }
        }
    }

    /// The seasons, sub or dub, the 100-episode blocks and the order, in one row that scrolls.
    private var televisionEpisodeControls: some View {
        let seasons = self.seasons
        let labels = SeasonLabels.labels(seasons, ref: TVDBSeasons.ref)
        let blocks = listing.map { EpisodeCatalog.blocks(televisionEpisodeList($0)) } ?? []
        let block = televisionBlockIndex(blocks)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if seasons.count > 1 {
                    ForEach(Array(seasons.enumerated()), id: \.element.id) { index, season in
                        SeasonChip(season: season, label: labels[season.id] ?? "Season \(index + 1)",
                                   selected: season.id == selectedSeason,
                                   choosable: SeasonLabels.choosable(season, selected: selectedSeason)) {
                            selectedSeason = season.id
                            televisionBlock = nil
                        }
                    }
                    Divider().frame(height: 28).padding(.horizontal, 4)
                }
                if let listing, !listing.dubbed.isEmpty {
                    ForEach(AudioTrack.allCases) { track in
                        FilterChip(label: track.label, selected: audio == track) { audio = track }
                    }
                }
                if blocks.count > 1 {
                    ForEach(blocks.indices, id: \.self) { item in
                        FilterChip(label: blocks[item].label, selected: item == block) { televisionBlock = item }
                    }
                }
                FilterChip(label: episodeOrder == "newest" ? "Newest first" : "Oldest first", systemImage: "arrow.up.arrow.down", selected: false) {
                    episodeOrder = episodeOrder == "newest" ? "oldest" : "newest"
                }
            }
            .padding(.horizontal, TelevisionMetrics.pagePadding)
        }
    }

    /// What this audio has, plus what hasn't aired anywhere yet, in the viewer's order (the phone
    /// page's rule).
    private func televisionEpisodeList(_ listing: EpisodeListing) -> [EpisodeInfo] {
        let available = Set(listing.available(audio).map(\.number))
        let rows = listing.episodes.filter { episode in
            available.contains(episode.number) || (!listing.subbed.contains(episode.number) && !listing.dubbed.contains(episode.number))
        }
        return episodeOrder == "newest" ? rows.reversed() : rows
    }

    private func televisionBlockIndex(_ blocks: [EpisodeCatalog.Block]) -> Int {
        let resume = library.history.shows[seasonMedia.id]?.resumeEpisode
        return min(televisionBlock ?? EpisodeCatalog.blockIndex(blocks, holding: resume), max(0, blocks.count - 1))
    }

    private func televisionShownEpisodes(_ listing: EpisodeListing) -> [EpisodeInfo] {
        let blocks = EpisodeCatalog.blocks(televisionEpisodeList(listing))
        guard !blocks.isEmpty else { return [] }
        return blocks[televisionBlockIndex(blocks)].episodes
    }
}

/// The episodes as Android TV lays them out: a rail of wide stills with the number in the corner,
/// the watched eye on the picture and progress along its foot, the title and the download button
/// on the line beneath, and the next episode's countdown at the end while it airs. It opens on the
/// episode to continue.
private struct TelevisionEpisodeRail: View {
    @Environment(\.palette) private var palette
    @Environment(LibraryStore.self) private var library
    let media: Media
    let listing: EpisodeListing
    let audio: AudioTrack
    let episodes: [EpisodeInfo]
    let resume: Int?
    let fallbackStill: URL?
    let nextAiring: Media.NextAiring?
    let onPlay: (Int) -> Void

    static let cardWidth: CGFloat = 300

    var body: some View {
        if episodes.isEmpty {
            Text("No episode information is available yet.")
                .font(AppFont.bodyMedium)
                .foregroundStyle(palette.onSurfaceVariant)
                .padding(.horizontal, TelevisionMetrics.pagePadding)
        } else {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: TelevisionMetrics.railSpacing) {
                        ForEach(episodes) { episode in
                            card(episode).id(episode.number)
                        }
                        if let nextAiring, !episodes.contains(where: { $0.number == nextAiring.episode }) {
                            countdown(episode: nextAiring.episode, at: nextAiring.date)
                        }
                    }
                    .padding(.horizontal, TelevisionMetrics.pagePadding)
                    .padding(.vertical, 6)
                }
                .onAppear {
                    if let resume, episodes.contains(where: { $0.number == resume }) {
                        reader.scrollTo(resume, anchor: .leading)
                    }
                }
            }
        }
    }

    private func card(_ episode: EpisodeInfo) -> some View {
        let canPlay = listing.available(audio).contains { $0.number == episode.number }
        let progress = library.history.progress(mediaID: media.id, episode: episode.number)
        let watched = progress?.isFinished == true
        let blur = AppearanceStore.shared.blurEpisodeImages && !watched
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .frame(width: Self.cardWidth, height: Self.cardWidth * 9 / 16)
                .overlay {
                    RemoteImage(url: episode.thumbnail ?? fallbackStill) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill().blur(radius: blur ? 14 : 0)
                        } else {
                            palette.surfaceVariant
                        }
                    }
                }
                .overlay(LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    Text(String(format: "E%02d", episode.number))
                        .font(AppFont.labelLarge.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(10)
                }
                .overlay(alignment: .bottomLeading) {
                    if episode.isFiller {
                        PosterTag(text: "FILLER", container: Color.orange.opacity(0.9), content: .black, outlined: false)
                            .padding(.leading, 12)
                            .padding(.bottom, progress != nil ? 18 : 12)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress, progress.fraction > 0.01 {
                        ProgressLine(fraction: progress.isFinished ? 1 : progress.fraction)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                    }
                }
                .contentShape(shape)
                .onTapGesture { if canPlay { onPlay(episode.number) } }
                .overlay(alignment: .topLeading) {
                    // The eye on the picture it marks, as on Android TV: no doubt which episode it
                    // belongs to.
                    if canPlay {
                        Button {
                            library.setWatched(media, episode: episode.number, !watched)
                        } label: {
                            Image(systemName: watched ? "eye.fill" : "eye")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(watched ? palette.primary : .white)
                                .frame(width: 36, height: 36)
                                .background(.black.opacity(0.55), in: Circle())
                                .padding(8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(watched ? "Mark episode \(episode.number) unwatched" : "Mark episode \(episode.number) watched")
                    }
                }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title ?? "Episode \(episode.number)")
                        .font(AppFont.titleMedium.weight(.bold))
                        .foregroundStyle(palette.onSurface)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    Text(caption(episode, canPlay: canPlay))
                        .font(AppFont.labelMedium)
                        .foregroundStyle(palette.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if canPlay {
                    DownloadButton(media: media, episode: episode, audio: audio)
                }
            }
            .frame(width: Self.cardWidth)
        }
        .opacity(canPlay ? 1 : 0.4)
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

    private func caption(_ episode: EpisodeInfo, canPlay: Bool) -> String {
        if !canPlay {
            if let aired = episode.airedOn { return "Airs \(aired)" }
            return "Not released yet"
        }
        var parts = ["Episode \(episode.number)"]
        if let duration = episode.duration, duration > 0 { parts.append("\(Int(duration / 60)) min") }
        if audio == .dub { parts.append("Dub") }
        return parts.joined(separator: "  •  ")
    }

    /// Android TV's last card while the show airs: "NEXT EPISODE IN 6d 03:39".
    private func countdown(episode: Int, at date: Date) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 8) {
                    Text("NEXT EPISODE IN")
                        .font(AppFont.labelLarge.weight(.bold))
                        .tracking(2)
                        .foregroundStyle(palette.onSurfaceVariant)
                    Text(NextEpisodeCard.countdown(to: date, now: context.date))
                        .font(.system(size: 34, weight: .heavy).monospacedDigit())
                        .foregroundStyle(palette.onSurface)
                }
                .frame(width: Self.cardWidth, height: Self.cardWidth * 9 / 16)
                .background(palette.surface.opacity(0.85), in: shape)
                .overlay(shape.strokeBorder(palette.outline.opacity(0.5), lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    Text(String(format: "E%02d", episode))
                        .font(AppFont.labelLarge.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(10)
                }
            }
            Text("Episode \(episode)")
                .font(AppFont.titleMedium.weight(.bold))
                .foregroundStyle(palette.onSurfaceVariant)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
