#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// Searches the viewer typed, newest first (Android's `SearchHistoryStore`).
enum SearchHistory {
    private static let key = "search_history"
    static let limit = 12

    static var entries: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func add(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return }
        var list = entries.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }

    static func remove(_ query: String) {
        UserDefaults.standard.set(entries.filter { $0 != query }, forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// The Search tab, after the Android app's Browse: a search field with a filter button, category
/// chips, the filters in force as removable chips, and the catalogue in three columns, paging as it
/// scrolls.
struct BrowseView: View {
    @Environment(AppRouter.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(\.palette) private var palette
    @AppStorage(Setting.searchAsYouType) private var searchAsYouType = true
    @State private var filters = DiscoverFilters()
    @State private var typed = ""
    @State private var results: [Media] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var showingFilters = false
    @State private var generation = 0
    @State private var studioIDs: [Int: Set<Int>] = [:]
    @State private var history: [String] = SearchHistory.entries
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                PageTitle(title: "Browse", subtitle: "Find your next obsession") {
                    if !filters.isDefault || !filters.query.isEmpty {
                        Button("Reset") { reset() }
                            .font(AppFont.titleSmall)
                            .foregroundStyle(palette.primary)
                            .padding(.top, 12)
                    }
                }
                searchRow.padding(.top, 14)
                if searchFocused && typed.isEmpty && !history.isEmpty {
                    recentSearches.padding(.top, 10)
                }
                if !activeChips.isEmpty {
                    activeFilterRow.padding(.top, 12)
                }
                categories.padding(.top, 14)
                Divider().overlay(palette.line).padding(.top, 14)
                resultsHeader.padding(.top, 14)
                grid
            }
            .padding(.bottom, 24)
        }
        .tucksChrome()
        .statusBarShade()
        .scrollDismissesKeyboard(.immediately)
        .background(palette.background)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingFilters) {
            FilterSheet(filters: $filters)
        }
        .task(id: filters) {
            // Typing re-runs this; the pause before searching is the debounce.
            if !filters.query.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            await reload()
        }
        .onChange(of: typed) { _, text in
            if searchAsYouType { filters.query = text }
        }
        .onAppear(perform: applyRoutedFilters)
        .onChange(of: router.browseFilters) { _, _ in applyRoutedFilters() }
    }

    // MARK: - Header

    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.onSurfaceVariant)
                TextField("Search anime…", text: $typed)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        filters.query = typed
                        SearchHistory.add(typed)
                        history = SearchHistory.entries
                    }
                    .foregroundStyle(palette.onSurface)
                if !typed.isEmpty {
                    Button {
                        typed = ""
                        filters.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(palette.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(palette.containerLow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))

            Button {
                showingFilters = true
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(palette.onPrimary)
                    .frame(width: 60, height: 56)
                    .background(palette.primary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if filters.activeCount > 0 {
                            Text("\(filters.activeCount)")
                                .font(AppFont.labelSmall.weight(.bold))
                                .foregroundStyle(palette.onError)
                                .padding(.horizontal, 5)
                                .background(palette.error, in: Capsule())
                                .offset(x: 4, y: -4)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Filters")
        }
        .padding(.horizontal, Metrics.pagePadding)
    }

    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent searches").font(AppFont.labelLarge).foregroundStyle(palette.onSurfaceVariant)
                Spacer()
                Button("Clear") {
                    SearchHistory.clear()
                    history = []
                }
                .font(AppFont.labelLarge)
                .foregroundStyle(palette.primary)
            }
            .padding(.bottom, 4)
            ForEach(history, id: \.self) { query in
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(palette.onSurfaceVariant)
                    Text(query).font(AppFont.bodyMedium).foregroundStyle(palette.onSurface)
                    Spacer()
                    Button {
                        SearchHistory.remove(query)
                        history = SearchHistory.entries
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(query) from recent searches")
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
                .onTapGesture {
                    typed = query
                    filters.query = query
                    searchFocused = false
                }
            }
        }
        .padding(.horizontal, Metrics.pagePadding + 4)
    }

    /// One filter in force, removable with a tap (Android's `ActiveFilterChip`).
    private struct ActiveChip: Identifiable {
        let id: String
        let label: String
        let remove: () -> Void
    }

    private var activeChips: [ActiveChip] {
        var chips: [ActiveChip] = []
        for genre in filters.genres.sorted() { chips.append(ActiveChip(id: "g-\(genre)", label: genre) { filters.genres.remove(genre) }) }
        for tag in filters.tags.sorted() { chips.append(ActiveChip(id: "t-\(tag)", label: tag) { filters.tags.remove(tag) }) }
        for genre in filters.excludedGenres.sorted() {
            chips.append(ActiveChip(id: "ng-\(genre)", label: "Not \(genre)") { filters.excludedGenres.remove(genre) })
        }
        for tag in filters.excludedTags.sorted() {
            chips.append(ActiveChip(id: "nt-\(tag)", label: "Not \(tag)") { filters.excludedTags.remove(tag) })
        }
        if let name = filters.studioName {
            chips.append(ActiveChip(id: "studio", label: name) {
                filters.studioID = nil
                filters.studioName = nil
            })
        }
        if filters.hideWatched != .off {
            chips.append(ActiveChip(id: "watched", label: filters.hideWatched == .completed ? "Not completed" : "Not watched") {
                filters.hideWatched = .off
            })
        }
        if filters.dubbedOnly { chips.append(ActiveChip(id: "dub", label: "Dubbed") { filters.dubbedOnly = false }) }
        return chips
    }

    private var activeFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(activeChips) { chip in
                    Button(action: chip.remove) {
                        HStack(spacing: 6) {
                            Text(chip.label).font(AppFont.labelLarge)
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(palette.onSecondaryContainer)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(palette.secondaryContainer, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
        }
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Categories")
                .font(AppFont.titleSmall)
                .foregroundStyle(palette.onSurface)
                .padding(.horizontal, Metrics.pagePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    let now = AniListClient.season(containing: Date())
                    FilterChip(label: "Season", systemImage: "sun.max", selected: filters.season == now.season && filters.year == now.year) {
                        if filters.season == now.season && filters.year == now.year {
                            filters.season = nil
                            filters.year = nil
                        } else {
                            filters.season = now.season
                            filters.year = now.year
                            filters.yearFrom = nil
                            filters.yearTo = nil
                        }
                    }
                    FilterChip(label: "Movies", selected: filters.format == "MOVIE") {
                        filters.format = filters.format == "MOVIE" ? nil : "MOVIE"
                    }
                    ForEach(HomeView.genres, id: \.self) { genre in
                        TriStateChip(
                            label: genre,
                            included: filters.genres.contains(genre),
                            excluded: filters.excludedGenres.contains(genre)
                        ) { filters.cycleGenre(genre) }
                    }
                }
                .padding(.horizontal, Metrics.pagePadding)
            }
        }
    }

    private var resultsHeader: some View {
        HStack {
            Text(headerTitle)
                .font(AppFont.titleMedium)
                .foregroundStyle(palette.onSurface)
            Spacer()
            Menu {
                Picker("Sort", selection: $filters.sort) {
                    ForEach(DiscoverFilters.sorts) { Text($0.label).tag($0.value) }
                }
            } label: {
                Text(DiscoverFilters.sorts.first { $0.value == filters.sort }?.label ?? "Sort")
                    .font(AppFont.labelLarge)
                    .foregroundStyle(palette.onSurfaceVariant)
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
    }

    private var headerTitle: String {
        if let studio = filters.studioName, filters.query.isEmpty { return "Anime by \(studio)" }
        if filters.query.isEmpty && filters.isDefault { return "Discover anime" }
        return total > 0 ? "\(total.formatted()) results" : "Results"
    }

    @ViewBuilder
    private var grid: some View {
        if let error, results.isEmpty {
            ErrorState(message: error) { await reload() }
        } else if results.isEmpty && loading {
            WaterFillLoader(size: 64).frame(maxWidth: .infinity).padding(.top, 60)
        } else if results.isEmpty {
            Text(filters.query.isEmpty ? "Nothing matches these filters." : "Nothing found. AniList matches whole words, so try finishing the word.")
                .font(AppFont.bodyMedium)
                .foregroundStyle(palette.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(40)
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: Metrics.gridSpacing, alignment: .top), count: Metrics.posterColumns)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(results) { media in
                    NavigationLink(value: media) { AnimeCard(media: media) }
                        .buttonStyle(.plain)
                        .onAppear {
                            if media.id == results.last?.id { Task { await loadMore() } }
                        }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, 12)
            if loading {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
    }

    // MARK: - Loading

    private func reload() async {
        generation += 1
        results = []
        page = 0
        hasMore = true
        total = 0
        error = nil
        await loadMore()
    }

    private func loadMore() async {
        guard hasMore, !loading else { return }
        let ask = generation
        loading = true
        defer { loading = false }
        let dubbed = filters.dubbedOnly ? DubIndexStore.shared.ids : []
        let excluded = library.history.watchedIDs(filters.hideWatched)
        do {
            var studio: Set<Int>?
            if let id = filters.studioID {
                if studioIDs[id] == nil { studioIDs[id] = try await AniListClient.shared.studioMediaIDs(id) }
                studio = studioIDs[id]
            }
            let next = try await AniListClient.shared.discover(
                filters, page: page + 1, hideAdult: ContentSettings.hideAdult,
                dubbedIDs: dubbed, studioIDs: studio, excludedIDs: excluded
            )
            guard ask == generation else { return }
            var seen = Set(results.map(\.id))
            results += next.items.filter { seen.insert($0.id).inserted }
            page = next.page
            hasMore = next.hasNextPage
            if next.total > 0 { total = next.total }
            Log.info("browse", "page \(next.page): \(next.items.count) of \(next.total), filters \(filters.activeCount), query \"\(filters.query)\"")
            // AniList matches whole words, so a half-typed search comes back thin; the local title
            // list fills it in with titles containing the text.
            if next.page == 1, !filters.query.isEmpty, next.items.count < 10 {
                await mergeLocal(ask: ask, dubbed: dubbed, excluded: excluded, seen: seen)
            }
        } catch {
            guard ask == generation, !Task.isCancelled else { return }
            Log.error("browse", "page \(page + 1) failed: \(Log.describe(error))")
            if page == 0, !filters.query.isEmpty {
                await mergeLocal(ask: ask, dubbed: dubbed, excluded: excluded, seen: [])
                if !results.isEmpty {
                    hasMore = false
                    return
                }
            }
            self.error = error.localizedDescription
        }
    }

    private func mergeLocal(ask: Int, dubbed: Set<Int>, excluded: Set<Int>, seen: Set<Int>) async {
        let local = await LocalCatalog.shared.search(filters, hideAdult: ContentSettings.hideAdult, dubbedIDs: dubbed, excludedIDs: excluded)
        guard ask == generation else { return }
        var seen = seen
        let extra = local.filter { seen.insert($0.id).inserted }
        if !extra.isEmpty {
            results += extra
            Log.info("browse", "local catalogue added \(extra.count) for \"\(filters.query)\"")
        }
    }

    private func reset() {
        typed = ""
        filters = DiscoverFilters()
    }

    private func applyRoutedFilters() {
        guard let routed = router.browseFilters else { return }
        router.browseFilters = nil
        typed = routed.query
        filters = routed
    }
}

/// An outlined chip that fills with the accent when selected (Android's category chips).
struct FilterChip: View {
    @Environment(\.palette) private var palette
    let label: String
    var systemImage: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                }
                Text(label).font(AppFont.labelLarge)
            }
            .foregroundStyle(selected ? palette.onPrimary : palette.onSurface)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(selected ? palette.primary : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? .clear : palette.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A genre or tag chip in its three states: off, included (filled), excluded (struck, in the
/// error colour). Tapping moves it along that cycle.
struct TriStateChip: View {
    @Environment(\.palette) private var palette
    let label: String
    let included: Bool
    let excluded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if included { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                if excluded { Image(systemName: "minus").font(.system(size: 11, weight: .bold)) }
                Text(label).font(AppFont.labelLarge).strikethrough(excluded)
            }
            .foregroundStyle(included ? palette.onPrimary : excluded ? palette.error : palette.onSurface)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(included ? palette.primary : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(included ? .clear : excluded ? palette.error : palette.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityValue(included ? "Included" : excluded ? "Excluded" : "Off")
    }
}

/// Wraps its children onto as many lines as they need, for chip groups.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Browse's filters on five pages, as the Android app's filter sheet: General, Release, Genres,
/// Tags and Studio, each tab counting the filters it holds.
private struct FilterSheet: View {
    enum Page: String, CaseIterable, Identifiable {
        case general = "General", release = "Release", genres = "Genres", tags = "Tags", studio = "Studio"
        var id: String { rawValue }

        func count(_ filters: DiscoverFilters) -> Int {
            switch self {
            case .general:
                var count = (filters.format == nil ? 0 : 1) + (filters.status == nil ? 0 : 1) + (filters.minimumScore == nil ? 0 : 1)
                if filters.episodesMin != nil || filters.episodesMax != nil { count += 1 }
                if filters.dubbedOnly { count += 1 }
                if filters.hideWatched != .off { count += 1 }
                return count
            case .release:
                var count = (filters.season == nil ? 0 : 1) + (filters.source == nil ? 0 : 1) + (filters.country == nil ? 0 : 1)
                if filters.year != nil || filters.yearFrom != nil || filters.yearTo != nil { count += 1 }
                return count
            case .genres: return filters.genres.count + filters.excludedGenres.count
            case .tags: return filters.tags.count + filters.excludedTags.count
            case .studio: return filters.studioID == nil ? 0 : 1
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Binding var filters: DiscoverFilters
    @State private var draft = DiscoverFilters()
    @State private var page: Page = .general
    @State private var allGenres: [String] = HomeView.genres
    @State private var allTags: [MediaTagInfo] = []
    @State private var tagSearch = ""
    @State private var studioSearch = ""
    @State private var studioResults: [StudioInfo] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Page.allCases) { tab in
                            let count = tab.count(draft)
                            FilterChip(label: count > 0 ? "\(tab.rawValue) \(count)" : tab.rawValue, selected: page == tab) { page = tab }
                        }
                    }
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 10)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch page {
                        case .general: generalPage
                        case .release: releasePage
                        case .genres: genresPage
                        case .tags: tagsPage
                        case .studio: studioPage
                        }
                    }
                    .padding(Metrics.pagePadding)
                }
            }
            .background(palette.background)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        let query = draft.query
                        draft = DiscoverFilters()
                        draft.query = query
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        filters = draft
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
        .tint(palette.primary)
        .onAppear { draft = filters }
        .task {
            if let genres = try? await AniListClient.shared.genres() {
                allGenres = genres.filter { $0 != "Hentai" || !ContentSettings.hideAdult }
            }
            if let tags = try? await AniListClient.shared.tags() {
                allTags = tags.filter { $0.isAdult != true || !ContentSettings.hideAdult }
            }
        }
        .task(id: studioSearch) {
            let text = studioSearch.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else {
                studioResults = []
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            studioResults = (try? await AniListClient.shared.studios(matching: text)) ?? []
        }
    }

    // MARK: Pages

    @ViewBuilder
    private var generalPage: some View {
        group("Sort") {
            ForEach(DiscoverFilters.sorts) { choice in
                FilterChip(label: choice.label, selected: draft.sort == choice.value) { draft.sort = choice.value }
            }
        }
        group("Format") { single(DiscoverFilters.formats, \.format) }
        group("Status") { single(DiscoverFilters.statuses, \.status) }
        group("Episodes") {
            ForEach(DiscoverFilters.episodeBuckets) { bucket in
                FilterChip(label: bucket.label, selected: draft.episodesMin == bucket.from && draft.episodesMax == bucket.to) {
                    let on = draft.episodesMin == bucket.from && draft.episodesMax == bucket.to
                    draft.episodesMin = on ? nil : bucket.from
                    draft.episodesMax = on ? nil : bucket.to
                }
            }
        }
        group("Score") {
            ForEach(DiscoverFilters.ratings, id: \.self) { rating in
                FilterChip(label: "\(rating)%+", selected: draft.minimumScore == rating) {
                    draft.minimumScore = draft.minimumScore == rating ? nil : rating
                }
            }
        }
        group("Audio") {
            FilterChip(label: "Dubbed only", selected: draft.dubbedOnly) { draft.dubbedOnly.toggle() }
        }
        group("Watched") {
            ForEach(WatchedFilter.allCases) { choice in
                FilterChip(label: choice.label, selected: draft.hideWatched == choice) { draft.hideWatched = choice }
            }
        }
    }

    @ViewBuilder
    private var releasePage: some View {
        group("Season") { single(DiscoverFilters.seasons, \.season) }
        group("Year") {
            let current = Calendar.current.component(.year, from: Date())
            ForEach((current - 6...current + 1).reversed(), id: \.self) { year in
                FilterChip(label: String(year), selected: draft.year == year) {
                    draft.year = draft.year == year ? nil : year
                    draft.yearFrom = nil
                    draft.yearTo = nil
                }
            }
        }
        group("Decade") {
            ForEach(DiscoverFilters.decades()) { decade in
                FilterChip(label: decade.label, selected: draft.yearFrom == decade.from && draft.yearTo == decade.to) {
                    let on = draft.yearFrom == decade.from && draft.yearTo == decade.to
                    draft.yearFrom = on ? nil : decade.from
                    draft.yearTo = on ? nil : decade.to
                    draft.year = nil
                }
            }
        }
        group("Country") { single(DiscoverFilters.countries, \.country) }
        group("Source") { single(DiscoverFilters.sources, \.source) }
    }

    @ViewBuilder
    private var genresPage: some View {
        group("Genres") {
            ForEach(allGenres, id: \.self) { genre in
                TriStateChip(label: genre, included: draft.genres.contains(genre), excluded: draft.excludedGenres.contains(genre)) {
                    draft.cycleGenre(genre)
                }
            }
        }
        hint("Tap once to include, again to exclude.")
    }

    private var visibleTags: [MediaTagInfo] {
        let chosen = allTags.filter { draft.tags.contains($0.name) || draft.excludedTags.contains($0.name) }
        let text = tagSearch.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return chosen }
        let matches = allTags.filter { tag in tag.name.localizedCaseInsensitiveContains(text) && !chosen.contains(tag) }
        return chosen + Array(matches.prefix(40))
    }

    @ViewBuilder
    private var tagsPage: some View {
        searchField("Search all \(allTags.count) AniList tags", text: $tagSearch)
        if visibleTags.isEmpty {
            hint(tagSearch.isEmpty ? "Type to find a tag, then tap it to include or exclude it." : "No tag matches \u{201C}\(tagSearch)\u{201D}.")
        } else {
            FlowLayout(spacing: 8) {
                ForEach(visibleTags) { tag in
                    TriStateChip(label: tag.name, included: draft.tags.contains(tag.name), excluded: draft.excludedTags.contains(tag.name)) {
                        draft.cycleTag(tag.name)
                    }
                }
            }
            hint("Tap once to include, again to exclude.")
        }
    }

    @ViewBuilder
    private var studioPage: some View {
        if let name = draft.studioName {
            group("Studio") {
                TriStateChip(label: name, included: true, excluded: false) {
                    draft.studioID = nil
                    draft.studioName = nil
                }
            }
        }
        searchField("Search studios", text: $studioSearch)
        ForEach(studioResults) { result in
            Button {
                draft.studioID = result.id
                draft.studioName = result.name
                studioSearch = ""
            } label: {
                SettingsRowShell(title: result.name) {
                    if draft.studioID == result.id { Image(systemName: "checkmark").foregroundStyle(palette.primary) }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Building blocks

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(AppFont.titleSmall).foregroundStyle(palette.onSurface)
            FlowLayout(spacing: 8) { content() }
        }
    }

    private func single(_ choices: [CatalogChoice], _ key: WritableKeyPath<DiscoverFilters, String?>) -> some View {
        ForEach(choices) { choice in
            FilterChip(label: choice.label, selected: draft[keyPath: key] == choice.value) {
                draft[keyPath: key] = draft[keyPath: key] == choice.value ? nil : choice.value
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(AppFont.bodySmall).foregroundStyle(palette.onSurfaceVariant)
    }

    private func searchField(_ prompt: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.onSurfaceVariant)
            TextField(prompt, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(palette.containerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
    }
}
#endif
