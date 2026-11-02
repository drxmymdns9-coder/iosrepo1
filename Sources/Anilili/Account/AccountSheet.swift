#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// The signed-in account, opened from My List's account pill (Android's `AccountSheet`): the
/// banner and picture, the three headline totals, then Overview, Stats and Activity, and the
/// account's own controls at the foot of every tab.
struct AccountSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", stats = "Stats", activity = "Activity"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.palette) private var palette
    @Environment(LibraryStore.self) private var library
    @State private var tab: Tab = .overview
    @State private var resuming: PlayRequest?
    @State private var confirmingLogout = false

    private var account: AccountStore { .shared }

    var body: some View {
        let insights = AccountInsights(profile: account.profile, library: account.library)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                HeadlineStats(insights: insights)
                HStack(spacing: 8) {
                    ForEach(Tab.allCases) { entry in
                        TabPill(label: entry.rawValue, selected: entry == tab) { withAnimation(.snappy) { tab = entry } }
                    }
                }
                switch tab {
                case .overview: overview(insights)
                case .stats: stats(insights)
                case .activity: activity(insights)
                }
                actions
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(palette.background)
        .presentationDragIndicator(.visible)
        .fullScreenCover(item: $resuming) { WatchView(request: $0) }
        .confirmationDialog("Log out of \(account.service?.label ?? "your account")?", isPresented: $confirmingLogout, titleVisibility: .visible) {
            Button("Log out", role: .destructive) {
                account.signOut()
                dismiss()
            }
        } message: {
            Text("Signing out keeps your watchlist and history on this device. Titles seeded from the account leave Continue Watching.")
        }
        .onChange(of: account.service) { _, service in if service == nil { dismiss() } }
    }

    // MARK: - Header

    /// Banner, a large round picture overlapping it, the name, the service, and the account's own
    /// page. With no banner (every MyAnimeList account) the cover of what was watched last stands in.
    private var header: some View {
        let banner = account.profile?.banner
            ?? account.continueWatching(library.history).first?.media.bannerImage.flatMap(URL.init(string:))
            ?? account.continueWatching(library.history).first?.media.coverImage?.best
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        Color.clear
                            .overlay {
                                RemoteImage(url: banner) { phase in
                                    if let image = phase.image { image.resizable().scaledToFill() } else { palette.onSurface.opacity(0.06) }
                                }
                            }
                            .overlay(LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        HStack(spacing: 4) {
                            bannerButton("arrow.clockwise", "Sync now") { Task { await account.refresh(force: true) } }
                            bannerButton("xmark", "Close") { dismiss() }
                        }
                        .padding(4)
                    }
                    .frame(height: 104)
                    Color.clear.frame(height: 28)
                }
                AccountAvatar(url: account.profile?.avatar)
                    .frame(width: 76, height: 76)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(palette.background, lineWidth: 3))
                    .padding(.leading, 12)
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.profile?.name ?? "Your account")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(palette.onSurface)
                        .lineLimit(1)
                    if let service = account.service {
                        HStack(spacing: 6) {
                            ServiceLogo(service: service, size: 16)
                            Text("\(service.label) connected").font(AppFont.labelMedium).foregroundStyle(palette.onSurfaceVariant)
                        }
                    }
                }
                Spacer(minLength: 8)
                if let service = account.service, let name = account.profile?.name, let url = AccountInsights.profileURL(service, name: name) {
                    Button {
                        openURL(url)
                    } label: {
                        HStack(spacing: 6) {
                            Text("View profile").font(AppFont.labelLarge)
                            Image(systemName: "arrow.up.right.square").font(.system(size: 14))
                        }
                        .foregroundStyle(palette.onSurface)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay(Capsule().strokeBorder(palette.onSurface.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func bannerButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Tabs

    @ViewBuilder
    private func overview(_ insights: AccountInsights) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Your anime", action: ("View all", { tab = .stats }))
            StackedStatusBar(insights: insights)
            HStack {
                ForEach(Array([ListStatusSlice.watching, .completed, .planning].enumerated()), id: \.offset) { index, slice in
                    HStack(spacing: 6) {
                        Circle().fill(Color(argb: slice.argb)).frame(width: 8, height: 8)
                        (Text("\(insights.count(slice))").bold().foregroundColor(palette.onSurface)
                            + Text(" \(slice.label)").foregroundColor(palette.onSurfaceVariant))
                            .font(AppFont.bodyMedium)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : index == 1 ? .center : .trailing)
                }
            }
        }
        let cards = Array(account.continueWatching(library.history).prefix(2))
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "Continue watching")
                HStack(alignment: .top, spacing: 12) {
                    ForEach(cards, id: \.media.id) { show in
                        ContinueCard(show: show, tracked: account.library.entries.first { $0.media.id == show.media.id }) {
                            resuming = PlayRequest(media: show.media, episode: show.resumeEpisode, audio: PlaybackSettings.preferredAudio, listing: .empty)
                        }
                    }
                    if cards.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
        if !insights.recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "Recent activity", action: ("View all", { tab = .activity }))
                ForEach(insights.recent.prefix(3), id: \.media.id) { ActivityRow(entry: $0) }
            }
        }
    }

    @ViewBuilder
    private func stats(_ insights: AccountInsights) -> some View {
        let local = WatchActivityStore.shared.days
        ActivityHeatmap(days: WatchActivity.merged(local, account.activityHistory), fromAccount: account.service == .anilist)
        HighlightTiles(insights: insights)
        StatusBreakdown(insights: insights)
        if !insights.formats.isEmpty {
            HorizontalBars(title: "Formats", subtitle: "What your list is made of", items: insights.formats)
        }
        if !insights.topGenres.isEmpty {
            let onlyPlanning = insights.total - insights.count(.planning) == 0
            HorizontalBars(title: "Top genres",
                           subtitle: onlyPlanning ? "Across the titles you plan to watch" : "Across the titles you have started",
                           items: insights.topGenres)
        }
        if !insights.studios.isEmpty {
            HorizontalBars(title: "Top studios", subtitle: "Who made what you have started", items: insights.studios)
        }
        if !insights.releaseYears.isEmpty {
            ColumnChart(title: "Release years", subtitle: "When the titles on your list came out", items: insights.releaseYears)
        }
        if !insights.scoreSpread.isEmpty {
            ColumnChart(title: "Your scores", subtitle: "How you rate what you have scored", items: insights.scoreSpread)
        } else {
            SectionTitle(title: "Your scores", subtitle: "Score a few titles and your spread shows up here")
        }
    }

    @ViewBuilder
    private func activity(_ insights: AccountInsights) -> some View {
        if insights.recent.isEmpty {
            Text("Nothing on your list has changed yet.").font(AppFont.bodyMedium).foregroundStyle(palette.onSurfaceVariant)
        } else {
            VStack(spacing: 10) {
                ForEach(insights.recent.prefix(20), id: \.media.id) { ActivityRow(entry: $0) }
            }
        }
    }

    /// The account's own controls as rows, so signing out is easy to find.
    private var actions: some View {
        let name = account.service?.label ?? "your account"
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Account", subtitle: account.service.map { "Signed in with \($0.label)" } ?? "Your account")
            ActionTile(symbol: "arrow.clockwise", title: "Sync now", subtitle: "Pull your lists from \(name) again", busy: account.refreshing) {
                Task { await account.refresh(force: true) }
            }
            ActionTile(symbol: "rectangle.portrait.and.arrow.right", title: "Log out", subtitle: "Sign this device out of \(name)", danger: true) {
                confirmingLogout = true
            }
        }
    }
}

// MARK: - Pieces

/// The account's picture, or the app's drawn character when it has none (MyAnimeList hands back
/// no picture for an account that never set one).
struct AccountAvatar: View {
    @Environment(\.palette) private var palette
    let url: URL?

    var body: some View {
        Color.clear
            .overlay {
                RemoteImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(uiImage: BrandImage.silhouette).renderingMode(.template).resizable().scaledToFit().padding(12).foregroundStyle(palette.onSurfaceVariant)
                    }
                }
            }
            .background(palette.surfaceVariant)
    }
}

/// Anime, watch time and mean score, three across with hairlines between.
private struct HeadlineStats: View {
    @Environment(\.palette) private var palette
    let insights: AccountInsights

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                stat(AccountInsights.grouped(insights.titles), "Anime")
                divider
                stat(AccountInsights.statWatchTime(insights.minutesWatched), "Watch time")
                divider
                stat(insights.meanScore.map { String(format: "%.1f", $0) } ?? "—", insights.meanScore == nil ? "No scores yet" : "Mean score")
            }
            .frame(height: 52)
            palette.line.frame(height: 1)
        }
    }

    private var divider: some View { palette.line.frame(width: 1, height: 36) }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(AppFont.titleLarge.weight(.black)).foregroundStyle(palette.onSurface).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(AppFont.labelMedium).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TabPill: View {
    @Environment(\.palette) private var palette
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(AppFont.labelLarge.weight(selected ? .bold : .medium))
                .foregroundStyle(selected ? palette.onPrimary : palette.onSurface)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? palette.primary : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? .clear : palette.onSurface.opacity(0.3), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SectionHeading: View {
    @Environment(\.palette) private var palette
    let title: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack {
            Text(title).font(AppFont.titleLarge.weight(.black)).foregroundStyle(palette.onSurface)
            Spacer()
            if let action {
                Button(action.0, action: action.1)
                    .font(AppFont.labelLarge.weight(.bold))
                    .foregroundStyle(palette.primary)
                    .buttonStyle(.plain)
            }
        }
    }
}

private struct SectionTitle: View {
    @Environment(\.palette) private var palette
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(AppFont.titleSmall.weight(.bold)).foregroundStyle(palette.onSurface)
            Text(subtitle).font(AppFont.labelSmall).foregroundStyle(palette.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One bar, each status its share of the width with a 2pt gap between.
private struct StackedStatusBar: View {
    @Environment(\.palette) private var palette
    let insights: AccountInsights

    var body: some View {
        GeometryReader { proxy in
            let shown = insights.statusCounts.filter { $0.count > 0 }
            let total = Double(max(1, insights.total))
            let gaps = CGFloat(max(0, shown.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(shown, id: \.slice) { item in
                    Color(argb: item.slice.argb).frame(width: max(0, (proxy.size.width - gaps) * CGFloat(Double(item.count) / total)))
                }
            }
        }
        .frame(height: 12)
        .background(palette.onSurface.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Every status, its count and its share, in text, so nothing is carried by colour alone.
private struct StatusBreakdown: View {
    @Environment(\.palette) private var palette
    let insights: AccountInsights

    var body: some View {
        let total = insights.total
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Your list", subtitle: "\(total) titles by status")
            StackedStatusBar(insights: insights)
            VStack(spacing: 6) {
                ForEach(insights.statusCounts, id: \.slice) { item in
                    HStack(spacing: 0) {
                        Circle().fill(Color(argb: item.slice.argb)).frame(width: 10, height: 10)
                        Text(item.slice.label).font(AppFont.bodyMedium).foregroundStyle(palette.onSurface).padding(.leading, 10)
                        Spacer()
                        Text("\(item.count)").font(AppFont.bodyMedium.weight(.bold)).foregroundStyle(palette.onSurface)
                        Text(total > 0 ? "\(Int((Double(item.count) * 100 / Double(total)).rounded()))%" : "—")
                            .font(AppFont.bodySmall)
                            .foregroundStyle(palette.onSurfaceVariant)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }
}

private let barColor = Color(argb: 0xFF3987E5)

/// Horizontal bars against a common track, longest first.
private struct HorizontalBars: View {
    @Environment(\.palette) private var palette
    let title: String
    let subtitle: String
    let items: [(label: String, count: Int)]

    var body: some View {
        let peak = max(1, items.map(\.count).max() ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: title, subtitle: subtitle)
            ForEach(items, id: \.label) { item in
                HStack(spacing: 0) {
                    Text(item.label).font(AppFont.bodyMedium).foregroundStyle(palette.onSurface).lineLimit(1).frame(width: 104, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            palette.onSurface.opacity(0.08)
                            barColor.frame(width: proxy.size.width * CGFloat(item.count) / CGFloat(peak))
                        }
                    }
                    .frame(height: 8)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text("\(item.count)").font(AppFont.bodySmall.weight(.bold)).foregroundStyle(palette.onSurface).frame(width: 36, alignment: .trailing)
                }
            }
        }
    }
}

/// Counts along an ordered axis as columns on a shared baseline; only the tallest carries its number.
private struct ColumnChart: View {
    @Environment(\.palette) private var palette
    let title: String
    let subtitle: String
    let items: [(label: String, count: Int)]

    var body: some View {
        let peakValue = max(1, items.map(\.count).max() ?? 1)
        let peak = items.firstIndex { $0.count == peakValue }
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: title, subtitle: subtitle)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    VStack(spacing: 2) {
                        if index == peak {
                            Text("\(item.count)").font(AppFont.labelSmall.weight(.bold)).foregroundStyle(palette.onSurface)
                        }
                        UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                            .fill(item.count == 0 ? palette.onSurface.opacity(0.12) : barColor)
                            .frame(height: item.count == 0 ? 2 : max(4, 96 * CGFloat(item.count) / CGFloat(peakValue)))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 120, alignment: .bottom)
            HStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item.label).font(AppFont.labelSmall).foregroundStyle(palette.onSurfaceVariant).lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// Days watched, episodes, completion rate and what's left, two by two.
private struct HighlightTiles: View {
    @Environment(\.palette) private var palette
    let insights: AccountInsights

    var body: some View {
        let wholeDay = insights.minutesWatched >= 1440
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                tile(wholeDay ? String(format: "%.1f", Double(insights.minutesWatched) / 1440) : AccountInsights.watchTimeLabel(insights.minutesWatched),
                     wholeDay ? "Days watched" : "Watch time")
                tile(AccountInsights.grouped(insights.episodes), "Episodes")
            }
            HStack(spacing: 10) {
                tile(insights.completionRate.map { "\($0)%" } ?? "—", "Completion rate")
                tile(AccountInsights.grouped(insights.episodesToGo), "Episodes to go")
            }
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .black)).foregroundStyle(palette.onSurface).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(AppFont.labelMedium).foregroundStyle(palette.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
    }
}

/// Twenty weeks of activity, a column per week and a row per weekday, GitHub-style: brighter is
/// busier, relative to the busiest day shown, with the streak and active days in words.
private struct ActivityHeatmap: View {
    @Environment(\.palette) private var palette
    let days: [Int: Int]
    let fromAccount: Bool

    private let heat = Color(argb: 0xFFF0BD5C)
    private let alphas: [Double] = [0, 0.3, 0.5, 0.75, 1]
    private let weeks = WatchActivity.heatmapWeeks

    var body: some View {
        let today = WatchActivity.day(Date())
        let weekStart = today - WatchActivity.weekday(today)
        let first = weekStart - (weeks - 1) * 7
        let window = (0..<(weeks * 7)).map { first + $0 }
        let peak = max(1, window.map { days[$0] ?? 0 }.max() ?? 1)
        let active = window.filter { $0 <= today && (days[$0] ?? 0) > 0 }.count
        let streak = WatchActivity.streak(days, today: today)
        let empty = palette.onSurface.opacity(0.07)
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Your activity",
                         subtitle: fromAccount ? "Last \(weeks) weeks · AniList activity and episodes watched here" : "Last \(weeks) weeks · episodes finished on this device")
            HStack(spacing: 0) {
                Color.clear.frame(width: 32, height: 1)
                HStack(spacing: 2) {
                    ForEach(0..<weeks, id: \.self) { week in
                        let monday = first + week * 7
                        Text(week == 0 || month(monday) != month(monday - 7) ? monthName(monday) : "")
                            .font(AppFont.labelSmall)
                            .foregroundStyle(palette.onSurfaceVariant)
                            .fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            VStack(spacing: 2) {
                ForEach(0..<7, id: \.self) { weekday in
                    HStack(spacing: 0) {
                        Text(["Mon", "", "Wed", "", "Fri", "", "Sun"][weekday])
                            .font(AppFont.labelSmall)
                            .foregroundStyle(palette.onSurfaceVariant)
                            .frame(width: 32, alignment: .leading)
                        HStack(spacing: 2) {
                            ForEach(0..<weeks, id: \.self) { week in
                                let day = first + week * 7 + weekday
                                let level = WatchActivity.level(days[day] ?? 0, max: peak)
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(day > today ? Color.clear : level == 0 ? empty : heat.opacity(alphas[level]))
                                    .aspectRatio(1, contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "flame.fill").font(.system(size: 15)).foregroundStyle(streak > 0 ? heat : palette.text3)
                Text(streak == 0 ? "No streak yet" : streak == 1 ? "1-day streak" : "\(streak)-day streak")
                    .font(AppFont.labelLarge.weight(.bold))
                    .foregroundStyle(streak > 0 ? heat : palette.onSurfaceVariant)
                Spacer()
                Text("Less").font(AppFont.labelSmall).foregroundStyle(palette.onSurfaceVariant)
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(level == 0 ? empty : heat.opacity(alphas[level]))
                            .frame(width: 10, height: 10)
                    }
                }
                Text("More").font(AppFont.labelSmall).foregroundStyle(palette.onSurfaceVariant)
            }
            Text(active == 0 && !fromAccount ? "Watch an episode here to start your activity history."
                 : "\(active) active \(active == 1 ? "day" : "days") in the last \(weeks) weeks")
                .font(AppFont.bodySmall)
                .foregroundStyle(palette.onSurfaceVariant)
        }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ day: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(day) * 86_400) }
    private func month(_ day: Int) -> Int { Self.utc.component(.month, from: date(day)) }
    private func monthName(_ day: Int) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = Self.utc.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: date(day)).uppercased()
    }
}

/// A Continue Watching title as a poster card: score, play, which episode, and how far through.
private struct ContinueCard: View {
    @Environment(\.palette) private var palette
    let show: WatchHistory.Show
    let tracked: ListEntry?
    let onResume: () -> Void

    var body: some View {
        let total = show.media.episodes.flatMap { $0 > 0 ? $0 : nil }
        let episode = show.lastEpisode
        let within = show.episodes[episode]?.fraction ?? 0
        let fraction = total.map { min(1, max(0, (Double(episode - 1) + within) / Double($0))) } ?? within
        Button(action: onResume) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .aspectRatio(0.72, contentMode: .fit)
                    .overlay { CoverImage(media: show.media) }
                    .overlay(alignment: .topTrailing) {
                        if let score = show.media.averageScore, score > 0 { RatingBadge(score: score).padding(8) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.black.opacity(0.6), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                            .padding(8)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(show.media.title.preferred)
                    .font(AppFont.titleSmall.weight(.bold))
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(1)
                    .padding(.top, 8)
                Text(total.map { "Episode \(episode) of \($0)" } ?? "Episode \(episode)")
                    .font(AppFont.bodySmall)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            palette.onSurface.opacity(0.12)
                            palette.primary.frame(width: proxy.size.width * fraction)
                        }
                    }
                    .frame(height: 4)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    Text("\(Int((fraction * 100).rounded()))%").font(AppFont.labelSmall).foregroundStyle(palette.onSurfaceVariant)
                }
                .padding(.top, 6)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Resume \(show.media.title.preferred)")
    }
}

/// One change to the list, read off the entry: what happened, when, and the cover.
private struct ActivityRow: View {
    @Environment(\.palette) private var palette
    let entry: ListEntry

    var body: some View {
        let title = entry.media.title.preferred
        let (symbol, headline): (String, String) = {
            switch entry.status {
            case .completed: return ("checkmark", "Completed \(title)")
            case .current: return ("play.fill", entry.progress > 0 ? "Watched episode \(entry.progress) of \(title)" : "Started \(title)")
            case .repeating: return ("arrow.counterclockwise", "Rewatching \(title)")
            case .paused: return ("pause.fill", "Paused \(title)")
            case .dropped: return ("minus.circle", "Dropped \(title)")
            case .planning: return ("bookmark.fill", "Planned \(title)")
            }
        }()
        var detail = entry.updatedAt.formatted(.relative(presentation: .named))
        if entry.score > 0 {
            let score = entry.score.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(entry.score)) : String(format: "%.1f", entry.score)
            detail += " · Rated \(score)/10"
        }
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.primary)
                .frame(width: 40, height: 40)
                .background(palette.onSurface.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(AppFont.bodyMedium.weight(.semibold)).foregroundStyle(palette.onSurface).lineLimit(2)
                Text(detail).font(AppFont.bodySmall).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
            }
            Spacer(minLength: 0)
            CoverImage(media: entry.media)
                .frame(width: 44, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// A full-width account control: icon, what it does, and a red one for signing out.
private struct ActionTile: View {
    @Environment(\.palette) private var palette
    let symbol: String
    let title: String
    let subtitle: String
    var busy = false
    var danger = false
    let action: () -> Void

    var body: some View {
        let ink = danger ? palette.error : palette.onSurface
        Button(action: action) {
            HStack(spacing: 14) {
                if busy {
                    ProgressView().controlSize(.small).frame(width: 22)
                } else {
                    Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(ink).frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(AppFont.titleSmall.weight(.bold)).foregroundStyle(ink)
                    Text(subtitle).font(AppFont.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(palette.onSurface.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}
#endif
