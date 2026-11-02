#if canImport(UIKit)
import AnililiCore
import Observation
import SwiftUI

/// The media index's dub list, behind every poster's DUB tag. Loaded once at launch; until then
/// (or if it fails) cards simply show no tag.
@MainActor
@Observable
final class DubIndexStore {
    static let shared = DubIndexStore()
    private(set) var ids: Set<Int> = []

    func load() async {
        ids = await MediaIndex.shared.dubbedIDs()
    }

    func hasDub(_ id: Int) -> Bool { ids.contains(id) }
}

/// The one shape every label drawn over poster artwork takes (Android's `PosterTag`): a near-opaque
/// black plate so white text reads on any frame, and a thin accent outline so it reads as the
/// app's rather than the artwork's.
struct PosterTag: View {
    @Environment(\.palette) private var palette
    let text: String
    var systemImage: String?
    var container: Color = .black.opacity(0.78)
    var content: Color = .white
    var outlined = true

    var body: some View {
        HStack(spacing: 2) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.primary)
            }
            Text(text)
                .font(AppFont.labelSmall.weight(.bold))
                .foregroundStyle(content)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(container, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            if outlined {
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(palette.primary.opacity(0.6), lineWidth: 1)
            }
        }
    }
}

/// AniList's community score: the one plain tag, since the star already carries the accent.
struct RatingBadge: View {
    let score: Int
    var body: some View {
        PosterTag(text: "\(score)%", systemImage: "star.fill", outlined: false)
            .accessibilityLabel("Rated \(score) percent")
    }
}

struct DubBadge: View {
    var body: some View {
        PosterTag(text: "DUB").accessibilityLabel("English dub available")
    }
}

struct AdultBadge: View {
    @Environment(\.palette) private var palette
    var body: some View {
        PosterTag(text: "18+", container: palette.error, content: palette.onError, outlined: false)
            .accessibilityLabel("Adult content")
    }
}

/// "3 NEW" on a library poster whose series has aired past where the viewer left it.
struct NewEpisodesBadge: View {
    @Environment(\.palette) private var palette
    let count: Int
    var body: some View {
        PosterTag(text: count > 99 ? "99+ NEW" : "\(count) NEW", container: palette.primary, content: palette.onPrimary, outlined: false)
    }
}

/// A poster's artwork with its corner tags, shared by every card presentation.
struct PosterArtwork: View {
    @Environment(\.palette) private var palette
    let media: Media
    var cornerRadius: CGFloat = 8

    var body: some View {
        let appearance = AppearanceStore.shared
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                RemoteImage(url: media.coverImage?.card) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        palette.surfaceVariant
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if appearance.shows(.score), let score = media.averageScore {
                    RatingBadge(score: score).padding(5)
                }
            }
            .overlay(alignment: .topLeading) {
                if appearance.shows(.adult), media.isAdult == true {
                    AdultBadge().padding(5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if appearance.shows(.dub), DubIndexStore.shared.hasDub(media.id) {
                    DubBadge().padding(5)
                }
            }
    }
}

/// The dense poster card shared by Home, Browse and the library (Android's `AnimeCard`): artwork,
/// a two-line title block that keeps its height so neighbouring captions line up, and the
/// `TV · 2016 · 13 EP` line. Holding it opens the list actions.
struct AnimeCard: View {
    @Environment(\.palette) private var palette
    let media: Media

    var body: some View {
        let appearance = AppearanceStore.shared
        VStack(alignment: .leading, spacing: 0) {
            PosterArtwork(media: media)
            if appearance.shows(.title) {
                Text(media.title.preferred)
                    .font(AppFont.labelLarge)
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 5)
            }
            if appearance.shows(.details) {
                Text(media.cardDetails)
                    .font(AppFont.labelSmall)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(1)
                    .padding(.top, appearance.shows(.title) ? 2 : 5)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { ListActions(media: media) }
        .accessibilityElement(children: .combine)
    }
}

/// The long-press menu on any poster. AniList and MAL list statuses arrive with account sign-in;
/// until then it's the on-device watchlist.
struct ListActions: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    let media: Media

    var body: some View {
        let saved = library.watchlist.contains(media.id)
        let account = AccountStore.shared
        if account.isSignedIn {
            Button {
                router.listSheet = media
            } label: {
                if let status = account.statuses[media.id] {
                    Label("On your list: \(status.label)", systemImage: "list.bullet")
                } else {
                    Label("Add to \(account.service?.label ?? "list")…", systemImage: "text.badge.plus")
                }
            }
            // Only for a title on the account: either service would otherwise make an entry to
            // hold the score.
            if account.statuses[media.id] != nil {
                Button {
                    router.scoreSheet = media
                } label: {
                    if let score = account.score(of: media.id) {
                        Label("Your score: \(ListScore.format(score)) / 10", systemImage: "star.fill")
                    } else {
                        Label("Rate this season", systemImage: "star")
                    }
                }
            }
        }
        Button {
            library.toggleWatchlist(media)
        } label: {
            Label(saved ? "Remove from watchlist" : "Add to watchlist", systemImage: saved ? "bookmark.slash" : "bookmark")
        }
        if library.history.shows[media.id] != nil {
            Button(role: .destructive) {
                library.remove(mediaID: media.id)
            } label: {
                Label("Remove from Continue Watching", systemImage: "xmark")
            }
        }
    }
}

/// A round button drawn on a card's artwork (Android's `CardCornerAction`): its own tap target, so
/// pressing it never also opens the card, on a disc that keeps the glyph legible over any frame.
/// The disc is 30 points but the target is a finger-sized 44: callers place it with their padding
/// less `touchInset`, so the disc sits where they meant and the extra margin reaches outward.
struct CardCornerAction: View {
    static let touchInset: CGFloat = 7

    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .smokedGlass(.home, in: Circle(), liveTint: 0.30, paintedTint: 0.55)
                .padding(Self.touchInset)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A rail's title line, with an optional trailing control (Expand, Edit).
struct RailTitle<Trailing: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.titleLarge)
                    .foregroundStyle(palette.onSurface)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.labelSmall)
                        .foregroundStyle(palette.onSurfaceVariant)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Metrics.pagePadding)
    }
}

extension RailTitle where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Android's "Expand" / "Carousel" text button beside a rail title.
struct ExpandToggle: View {
    @Environment(\.palette) private var palette
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "list.bullet" : "square.grid.2x2")
                    .font(.system(size: 15, weight: .semibold))
                Text(expanded ? "Carousel" : "Expand")
                    .font(AppFont.labelLarge)
            }
            .foregroundStyle(palette.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A horizontal rail of poster cards that can expand into a three-column grid (Android's
/// `MediaRail`).
struct MediaRail: View {
    @Environment(\.palette) private var palette
    let title: String
    let items: [Media]
    var expandable = true
    /// The catalogue row behind this rail, which Load More pages through once it's expanded.
    var row: HomeRow?
    @State private var expanded = false
    @State private var more: [Media] = []
    @State private var page = 1
    @State private var exhausted = false
    @State private var loading = false

    private var shown: [Media] {
        var seen = Set<Int>()
        return (items + more).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                RailTitle(title: title) {
                    if expandable {
                        ExpandToggle(expanded: expanded) { withAnimation(.snappy) { expanded.toggle() } }
                    }
                }
                if expanded {
                    let columns = Array(repeating: GridItem(.flexible(), spacing: Metrics.gridSpacing, alignment: .top), count: Metrics.posterColumns)
                    LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
                        ForEach(shown) { media in
                            NavigationLink(value: media) { AnimeCard(media: media) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 8)
                    if row?.isCatalogue == true && !exhausted {
                        loadMoreButton
                    }
                } else {
                    let width = Metrics.railPosterWidth(screenWidth: Metrics.screenWidth)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: Metrics.railSpacing) {
                            ForEach(shown) { media in
                                NavigationLink(value: media) { AnimeCard(media: media).frame(width: width) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    /// Android's outlined "Load More <row>" button under an expanded grid.
    private var loadMoreButton: some View {
        Button {
            Task { await loadMore() }
        } label: {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                Text(loading ? "Loading…" : "Load More \(title)")
                    .font(AppFont.labelLarge.weight(.bold))
            }
            .foregroundStyle(palette.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func loadMore() async {
        guard let row, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await AniListClient.shared.homeRow(row, page: page + 1, hideAdult: ContentSettings.hideAdult)
            more += next.items
            page = next.page
            exhausted = !next.hasNextPage || next.items.isEmpty
            Log.info("home", "\(row.rawValue) page \(next.page): \(next.items.count) more")
        } catch {
            Log.error("home", "\(row.rawValue) page \(page + 1) failed: \(Log.describe(error))")
        }
    }
}
#endif
