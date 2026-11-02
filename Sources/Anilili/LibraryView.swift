#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// The My List tab, after the Android app's library: your lists as chips, a filter, and a rail for
/// each list. Signed in, the account's lists (each status, custom lists, Favourites) join the
/// device's watchlist and Continue Watching.
struct LibraryView: View {
    /// One rail: a device list, an account status, a custom list or Favourites.
    struct Shelf: Hashable, Identifiable {
        enum Kind: Hashable {
            case watchlist, watching
            case status(ListStatus)
            case custom(String)
            case favourites
        }
        var kind: Kind
        var id: Kind { kind }

        var title: String {
            switch kind {
            case .watchlist: return "Watchlist"
            case .watching: return "Continue Watching"
            case .status(let status): return status.label
            case .custom(let name): return name
            case .favourites: return "Favourites"
            }
        }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.palette) private var palette
    /// Read so My List redraws when Settings hides or shows a MyAnimeList tag.
    @AppStorage(Setting.hiddenMALTags) private var hiddenMALTags = ""
    @State private var query = ""
    @State private var hidden: Set<Shelf> = []
    @State private var format: String?
    @State private var sort: Sort = .recent
    @State private var signingIn: AccountService?
    @State private var showingAccount = false

    private var account: AccountStore { .shared }

    /// Android's order: the account's lists first when signed in, then the device's.
    private var shelves: [Shelf] {
        var list: [Shelf] = []
        if account.isSignedIn {
            for status in [ListStatus.current, .repeating, .planning, .completed, .paused, .dropped]
            where status != .repeating || !account.library.entries(.repeating).isEmpty {
                list.append(Shelf(kind: .status(status)))
            }
            // Settings → Accounts & sync → MyAnimeList tags as lists keeps some tags off My List.
            let hiddenTags = account.service == .mal ? MALTags.hidden(hiddenMALTags) : []
            list += account.customListNames.filter { !MALTags.isHidden($0, in: hiddenTags) }.map { Shelf(kind: .custom($0)) }
            if account.service == .anilist { list.append(Shelf(kind: .favourites)) }
        }
        list.append(Shelf(kind: .watchlist))
        list.append(Shelf(kind: .watching))
        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "My List") {
                    // Signed out there's no account to put in a pill: the card below is the way in.
                    if account.isSignedIn { accountPill }
                }
                if !account.isSignedIn {
                    SignInCard { signingIn = $0 }
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.top, 12)
                }
                searchField.padding(.top, 10)
                chips.padding(.top, 12)
                filterRow.padding(.top, 6)
                Text("\(filteredCount) anime · Long-press a title to move it on your anime list")
                    .font(AppFont.labelSmall)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 8)
                if let problem = account.problem {
                    Text(problem)
                        .font(AppFont.labelSmall)
                        .foregroundStyle(palette.error)
                        .padding(.horizontal, Metrics.pagePadding)
                        .padding(.top, 6)
                }

                ForEach(shelves.filter { !hidden.contains($0) }) { shelf in
                    LibraryRail(
                        title: shelf.kind == .watchlist ? "My watchlist" : shelf.title,
                        subtitle: subtitle(shelf),
                        empty: empty(shelf),
                        items: items(shelf),
                        progress: { progress(shelf, $0) },
                        badge: { media in
                            let count = newEpisodes(media)
                            return count > 0 ? "\(count) NEW" : nil
                        }
                    )
                    .padding(.top, 22)
                }
            }
            .padding(.bottom, 24)
        }
        .refreshable { await account.refresh(force: true) }
        .sheet(item: $signingIn) { service in
            SignInView(service: service).environment(\.palette, palette)
        }
        .sheet(isPresented: $showingAccount) {
            AccountSheet()
                .environment(\.palette, palette)
                .environment(library)
                .environment(router)
        }
        .tucksChrome()
        .statusBarShade()
        .scrollDismissesKeyboard(.immediately)
        .background(palette.background)
        .toolbar(.hidden, for: .navigationBar)
    }

    /// The signed-in account: avatar and name, opening the account sheet (Android's profile pill).
    private var accountPill: some View {
        Button {
            showingAccount = true
        } label: {
            HStack(spacing: 8) {
                RemoteImage(url: account.profile?.avatar) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle.fill").resizable()
                    }
                }
                .frame(width: 26, height: 26)
                .clipShape(Circle())
                Text(account.profile?.name ?? account.service?.label ?? "Account")
                    .font(AppFont.titleSmall)
                    .lineLimit(1)
            }
            .foregroundStyle(palette.onSurface)
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.onSurfaceVariant)
            TextField("Search library", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, Metrics.pagePadding + 4)
        .frame(height: 48)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(shelves) { shelf in
                    let count = items(shelf).count
                    let on = !hidden.contains(shelf)
                    Button {
                        if on { hidden.insert(shelf) } else { hidden.remove(shelf) }
                    } label: {
                        HStack(spacing: 6) {
                            if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
                            Text(shelf.title).font(AppFont.labelLarge)
                            Text("\(count)").font(AppFont.labelLarge.weight(.bold))
                        }
                        .foregroundStyle(palette.onSurface)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(on ? palette.containerHighest : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
        }
    }

    private var filterRow: some View {
        HStack {
            Menu {
                Picker("Format", selection: $format) {
                    Text("Any format").tag(String?.none)
                    ForEach(DiscoverFilters.formats) { Text($0.label).tag(String?.some($0.value)) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(DiscoverFilters.formats.first { $0.value == format }?.label ?? "Any format")
                        .font(AppFont.labelLarge)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(palette.onSurface)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            Spacer()
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 12, weight: .bold))
                    Text(sort.rawValue).font(AppFont.labelLarge)
                }
                .foregroundStyle(palette.onSurface)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recent"
        case title = "Title"
        case score = "Score"
        case newEpisodes = "New episodes"
        var id: String { rawValue }
    }

    /// Aired episodes past what you've watched (Android's "3 NEW"), for shows you're watching.
    private func newEpisodes(_ media: Media) -> Int {
        let local = library.history.shows[media.id].map { $0.episodes.filter { $0.value.isFinished }.keys.max() ?? 0 }
        let watching = local != nil || account.statuses[media.id]?.isWatching == true
        guard watching, let released = media.releasedEpisodes else { return 0 }
        let watched = max(local ?? 0, account.progress(of: media.id) ?? 0)
        return watched > 0 ? max(0, released - watched) : 0
    }

    // MARK: - Filtering

    private func passes(_ media: Media) -> Bool {
        if let format, media.format != format { return false }
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return true }
        let names = media.title.all.joined(separator: " ").lowercased()
        return words.allSatisfy { names.contains($0) }
    }

    private func items(_ shelf: Shelf) -> [Media] {
        let all: [Media]
        switch shelf.kind {
        case .watchlist: all = library.watchlist.items
        case .watching: all = account.continueWatching(library.history).map(\.media)
        case .status(let status): all = account.library.entries(status).map(\.media)
        case .custom(let name): all = account.library.entries(inCustomList: name).map(\.media)
        case .favourites: all = account.favourites
        }
        let shown = all.filter(passes)
        switch sort {
        case .recent: return shown
        case .title: return shown.sorted { $0.title.preferred.localizedCaseInsensitiveCompare($1.title.preferred) == .orderedAscending }
        case .score: return shown.sorted { ($0.averageScore ?? 0) > ($1.averageScore ?? 0) }
        case .newEpisodes: return shown.sorted { newEpisodes($0) > newEpisodes($1) }
        }
    }

    private func subtitle(_ shelf: Shelf) -> String {
        let count = items(shelf).count
        switch shelf.kind {
        case .watchlist: return "\(count) anime · Saved on this device"
        case .watching: return "Long-press a title to remove it or move it on your anime list"
        case .favourites: return "\(count) anime · Favourited on AniList"
        case .status, .custom: return "\(count) anime · On \(account.service?.label ?? "your account")"
        }
    }

    private func empty(_ shelf: Shelf) -> String {
        switch shelf.kind {
        case .watchlist: return "Long-press any anime and choose Add to watchlist."
        case .watching: return "Shows you start watching appear here."
        case .favourites: return "Titles you favourite on AniList appear here."
        case .status: return "Nothing on this list. Long-press a title to move it here."
        case .custom: return "Nothing in this list yet."
        }
    }

    /// "watched/total", from this device's history, or the account's count where it knows more.
    private func progress(_ shelf: Shelf, _ media: Media) -> String? {
        let local = library.history.shows[media.id].map { $0.episodes.values.filter(\.isFinished).count }
        let remote = account.progress(of: media.id)
        guard let watched = [local, remote].compactMap({ $0 }).max(), watched > 0 || shelf.kind == .watching else { return nil }
        return "\(watched)/\(media.episodes.map(String.init) ?? "?")"
    }

    private var filteredCount: Int {
        Set(shelves.filter { !hidden.contains($0) }.flatMap { items($0).map(\.id) }).count
    }
}

/// One of the library's rails: posters with an optional progress tag, expandable into a grid.
private struct LibraryRail: View {
    @Environment(\.palette) private var palette
    let title: String
    let subtitle: String
    let empty: String
    let items: [Media]
    let progress: (Media) -> String?
    var badge: (Media) -> String? = { _ in nil }
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RailTitle(title: title, subtitle: subtitle) {
                if !items.isEmpty {
                    ExpandToggle(expanded: expanded) { withAnimation(.snappy) { expanded.toggle() } }
                }
            }
            if items.isEmpty {
                Text(empty)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 12)
            } else if expanded {
                let columns = Array(repeating: GridItem(.flexible(), spacing: Metrics.gridSpacing, alignment: .top), count: Metrics.posterColumns)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { media in card(media) }
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.top, 12)
            } else {
                let width = Metrics.railPosterWidth(screenWidth: Metrics.screenWidth) * 1.2
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Metrics.railSpacing) {
                        ForEach(items) { media in card(media).frame(width: width) }
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private func card(_ media: Media) -> some View {
        NavigationLink(value: media) {
            AnimeCard(media: media)
                .overlay(alignment: .topTrailing) {
                    if AppearanceStore.shared.shows(.progress), let progress = progress(media) {
                        // Below the score's corner, so the two tags never overlap.
                        PosterTag(text: progress).padding(5).offset(y: 22)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let badge = badge(media) {
                        PosterTag(text: badge, container: palette.primary, content: palette.onPrimary, outlined: false).padding(5)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

/// AniList's notification feed (Android's `NotificationsScreen`): new episodes of listed shows,
/// related titles and data changes, and follows, replies and likes. Opening it marks them read.
struct NotificationsView: View {
    @Environment(\.palette) private var palette
    @Environment(AppRouter.self) private var router
    @State private var loading = false
    @State private var filter: AccountNotification.Kind?

    private var account: AccountStore { .shared }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if account.service != .anilist {
                    ComingNote(text: account.service == .mal
                               ? "MyAnimeList has no notifications to show. Episode reminders from the Schedule still arrive as alerts."
                               : "Sign in to AniList to see new episodes of the shows on your list, and replies and follows, here.")
                    if account.service == nil {
                        Button("Open Accounts") { router.push(Route.settings(.accounts)) }
                            .font(AppFont.labelLarge)
                            .foregroundStyle(palette.primary)
                    }
                } else {
                    kinds
                    if loading && account.notifications.isEmpty {
                        WaterFillLoader(size: 56).frame(maxWidth: .infinity).padding(.top, 60)
                    } else if shown.isEmpty {
                        Text("Nothing here yet.").font(AppFont.bodyMedium).foregroundStyle(palette.onSurfaceVariant).padding(.top, 20)
                    }
                    ForEach(shown) { item in row(item) }
                }
            }
            .padding(Metrics.pagePadding)
        }
        .refreshable { await account.loadNotifications(markRead: true) }
        .background(palette.background)
        .navigationTitle("Notifications")
        .task {
            loading = true
            await account.loadNotifications(markRead: true)
            loading = false
        }
    }

    private var shown: [AccountNotification] {
        account.notifications.filter { filter == nil || $0.kind == filter }
    }

    private var kinds: some View {
        HStack(spacing: 8) {
            FilterChip(label: "All", selected: filter == nil) { filter = nil }
            FilterChip(label: "Airing", selected: filter == .airing) { filter = .airing }
            FilterChip(label: "Media", selected: filter == .media) { filter = .media }
            FilterChip(label: "Social", selected: filter == .social) { filter = .social }
        }
    }

    private func row(_ item: AccountNotification) -> some View {
        Button {
            if let id = item.mediaID { router.push(Media(id: id, title: .init(romaji: item.title))) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(url: item.image) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { palette.containerHigh }
                }
                .frame(width: 48, height: item.kind == .social ? 48 : 68)
                .clipShape(RoundedRectangle(cornerRadius: item.kind == .social ? 24 : 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let badge = item.badge { PosterTag(text: badge) }
                        if item.unread { Circle().fill(palette.primary).frame(width: 7, height: 7) }
                    }
                    Text(item.title).font(AppFont.titleSmall).foregroundStyle(palette.onSurface).lineLimit(2)
                    if let detail = item.detail {
                        Text(detail).font(AppFont.bodySmall).foregroundStyle(palette.onSurfaceVariant).lineLimit(3)
                    } else if let episode = item.episode {
                        Text("Episode \(episode) aired").font(AppFont.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                    }
                    Text(item.createdAt.formatted(.relative(presentation: .named)))
                        .font(AppFont.labelSmall).foregroundStyle(palette.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(item.unread ? palette.containerHigh : palette.containerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(item.mediaID == nil)
    }
}
#endif
