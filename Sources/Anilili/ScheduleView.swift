#if canImport(UIKit)
import AnililiCore
import Observation
import SwiftUI
import UserNotifications

/// Episode reminders from the schedule's bell: a local notification ten minutes before an episode
/// airs, "Episode N airs soon", as the Android app's `ReminderManager` sends it.
@MainActor
@Observable
final class ReminderStore {
    static let shared = ReminderStore()

    /// `mediaId:episode:airingAt`, Android's reminder id.
    private(set) var scheduled: Set<String>
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let key = "schedule_reminders"
    static let lead: TimeInterval = 10 * 60

    private init() {
        let now = Int(Date().timeIntervalSince1970)
        // Reminders for episodes that have aired are spent; drop them on launch.
        let stored = defaults.stringArray(forKey: Self.key) ?? []
        scheduled = Set(stored.filter { id in (Int(id.split(separator: ":").last ?? "") ?? 0) > now })
    }

    static func id(_ slot: AniListClient.AiringSlot) -> String { "\(slot.media.id):\(slot.episode):\(slot.airingAt)" }

    func isScheduled(_ slot: AniListClient.AiringSlot) -> Bool { scheduled.contains(Self.id(slot)) }

    func toggle(_ slot: AniListClient.AiringSlot) async {
        let id = Self.id(slot)
        let center = UNUserNotificationCenter.current()
        if scheduled.contains(id) {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            scheduled.remove(id)
            save()
            Log.info("reminder", "removed \(id)")
            return
        }
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else {
                Log.warning("reminder", "notifications not allowed")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = slot.media.title.preferred
            content.body = "Episode \(slot.episode) airs soon"
            content.sound = .default
            content.userInfo = ["anilistId": slot.media.id, "episode": slot.episode]
            content.threadIdentifier = "release-\(slot.media.id)"
            let fire = max(slot.date.addingTimeInterval(-Self.lead), Date().addingTimeInterval(1))
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSinceNow), repeats: false)
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            scheduled.insert(id)
            save()
            Log.info("reminder", "set \(id) for \(fire)")
        } catch {
            Log.error("reminder", "couldn't schedule \(id): \(Log.describe(error))")
        }
    }

    private func save() {
        defaults.set(Array(scheduled), forKey: Self.key)
    }
}

/// The airing schedule, after the Android app's: a strip of days around today, or the whole month
/// as a calendar, and the chosen day's episodes along a timeline of air times.
struct ScheduleView: View {
    @Environment(\.palette) private var palette
    @AppStorage("schedule_calendar_view") private var calendarView = false
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @State private var month = Calendar.current.startOfDay(for: Date())
    @State private var slots: [AniListClient.AiringSlot] = []
    @State private var counts: [Date: Int] = [:]
    @State private var loading = true
    @State private var error: String?

    /// Android's strip: from two days back, nine days long.
    private static let stripFirst = -2
    private static let stripLength = 9

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if calendarView {
                    MonthCalendar(month: $month, selected: $selected, counts: counts)
                } else {
                    dayStrip
                }
                Text(selected.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(AppFont.labelLarge)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                content
            }
            .padding(.bottom, 24)
        }
        .background(palette.background)
        .navigationTitle("Schedule")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    calendarView.toggle()
                } label: {
                    Image(systemName: calendarView ? "list.bullet" : "calendar")
                }
                .accessibilityLabel(calendarView ? "Show the days around today" : "Show the whole month")
            }
        }
        .refreshable { await load(force: true) }
        .task(id: selected) { await load(force: false) }
        .task(id: calendarView ? monthKey : "strip") { if calendarView { await loadCounts() } }
        .onChange(of: calendarView) { _, on in
            if !on {
                // Back on the strip, the selection has to be a day the strip shows.
                let today = Calendar.current.startOfDay(for: Date())
                let first = Calendar.current.date(byAdding: .day, value: Self.stripFirst, to: today) ?? today
                let last = Calendar.current.date(byAdding: .day, value: Self.stripFirst + Self.stripLength - 1, to: today) ?? today
                selected = min(max(selected, first), last)
            } else {
                month = selected
            }
        }
    }

    private var monthKey: String {
        let parts = Calendar.current.dateComponents([.year, .month], from: month)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)"
    }

    private var dayStrip: some View {
        let today = Calendar.current.startOfDay(for: Date())
        return ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<Self.stripLength, id: \.self) { index in
                        let offset = Self.stripFirst + index
                        let date = Calendar.current.date(byAdding: .day, value: offset, to: today) ?? today
                        let active = Calendar.current.isDate(date, inSameDayAs: selected)
                        Button {
                            selected = date
                        } label: {
                            VStack(spacing: 2) {
                                Text(offset == 0 ? "Today" : offset == 1 ? "Tomorrow" : offset == -1 ? "Yesterday" : date.formatted(.dateTime.weekday(.abbreviated)))
                                    .font(AppFont.labelLarge)
                                    .foregroundStyle(active ? palette.onPrimary : palette.onSurface)
                                    .lineLimit(1)
                                Text(date.formatted(.dateTime.month(.abbreviated).day()))
                                    .font(AppFont.labelSmall)
                                    .foregroundStyle(active ? palette.onPrimary.opacity(0.72) : palette.onSurfaceVariant)
                            }
                            .frame(width: 88, height: 68)
                            .background(active ? palette.primary : palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(active ? palette.primary : palette.outline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.vertical, 6)
            }
            .onAppear { reader.scrollTo(-Self.stripFirst, anchor: .center) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && slots.isEmpty {
            WaterFillLoader(size: 64).frame(maxWidth: .infinity).frame(height: 220)
        } else if let error, slots.isEmpty {
            ErrorState(message: error) { await load(force: true) }
        } else if slots.isEmpty {
            Text("Nothing scheduled")
                .foregroundStyle(palette.onSurfaceVariant)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
        } else {
            let groups = Dictionary(grouping: slots, by: \.airingAt).sorted { $0.key < $1.key }
            ForEach(groups, id: \.key) { group in
                TimeSlot(airingAt: group.key, entries: group.value)
            }
        }
    }

    private func load(force: Bool) async {
        loading = true
        defer { loading = false }
        do {
            slots = try await ScheduleService.shared.day(selected, hideAdult: ContentSettings.hideAdult, force: force)
            error = nil
        } catch {
            Log.error("schedule", "\(selected) failed: \(Log.describe(error))")
            slots = []
            self.error = error.localizedDescription
        }
    }

    private func loadCounts() async {
        counts = await ScheduleService.shared.counts(ScheduleService.monthGrid(containing: month), hideAdult: ContentSettings.hideAdult)
    }
}

/// One air time on the day's timeline: the time beside a dot on a vertical line, then its cards.
private struct TimeSlot: View {
    @Environment(\.palette) private var palette
    let airingAt: Int
    let entries: [AniListClient.AiringSlot]

    var body: some View {
        let date = Date(timeIntervalSince1970: TimeInterval(airingAt))
        let upcoming = date > Date()
        VStack(alignment: .leading, spacing: 0) {
            Text(AirTime.format(date))
                .font(AppFont.titleMedium.weight(.bold))
                .foregroundStyle(palette.onSurface)
                .padding(.leading, Metrics.pagePadding + 28)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(entries) { slot in
                ScheduleCard(slot: slot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            ZStack(alignment: .top) {
                Rectangle().fill(palette.outline).frame(width: 1).frame(maxHeight: .infinity)
                Circle().fill(upcoming ? palette.primary : palette.onSurfaceVariant)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().fill(palette.background).frame(width: 4, height: 4))
                    .padding(.top, 15)
            }
            .frame(width: 10)
            .padding(.leading, Metrics.pagePadding + 3)
        }
    }
}

private struct ScheduleCard: View {
    @Environment(\.palette) private var palette
    let slot: AniListClient.AiringSlot

    var body: some View {
        let upcoming = slot.date > Date()
        let reminded = ReminderStore.shared.isScheduled(slot)
        NavigationLink(value: slot.media) {
            HStack(spacing: 12) {
                CoverImage(media: slot.media)
                    .frame(width: 62, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(slot.media.title.preferred)
                        .font(AppFont.titleMedium)
                        .foregroundStyle(palette.onSurface)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("Episode \(slot.episode)")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(palette.onSurfaceVariant)
                    HStack(spacing: 6) {
                        if let format = slot.media.format { tag(format.replacingOccurrences(of: "_", with: " ")) }
                        if let year = slot.media.seasonYear { tag(String(year)) }
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(AirTime.format(slot.date))
                        .font(AppFont.titleMedium.weight(.bold))
                        .foregroundStyle(palette.onSurface)
                    Text(upcoming ? "UPCOMING" : "AIRED")
                        .font(AppFont.labelSmall)
                        .foregroundStyle(upcoming ? palette.primary : palette.onSurfaceVariant)
                    if upcoming {
                        Button {
                            Task { await ReminderStore.shared.toggle(slot) }
                        } label: {
                            Image(systemName: reminded ? "bell.fill" : "bell")
                                .font(.system(size: 16))
                                .foregroundStyle(reminded ? palette.primary : palette.onSurfaceVariant)
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(reminded ? "Remove reminder" : "Remind me")
                    }
                }
            }
            .padding(10)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.outline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.leading, Metrics.pagePadding + 28)
        .padding(.trailing, Metrics.pagePadding)
        .padding(.top, 5)
        .padding(.bottom, 7)
    }

    private func tag(_ label: String) -> some View {
        Text(label)
            .font(AppFont.labelSmall)
            .foregroundStyle(palette.onSurfaceVariant)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The month grid (Android's `MonthCalendar`): a header that steps months, weekday initials, and a
/// cell per day with that day's episode count.
private struct MonthCalendar: View {
    @Environment(\.palette) private var palette
    @Binding var month: Date
    @Binding var selected: Date
    let counts: [Date: Int]

    var body: some View {
        let calendar = Calendar.current
        let days = ScheduleService.monthGrid(containing: month)
        let today = calendar.startOfDay(for: Date())
        let shownMonth = calendar.component(.month, from: month)
        VStack(spacing: 2) {
            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("Previous month")
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(AppFont.titleMedium.weight(.bold))
                    .foregroundStyle(palette.onSurface)
                Spacer()
                Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .accessibilityLabel("Next month")
            }
            .foregroundStyle(palette.onSurface)
            .padding(.horizontal, 4)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    let symbols = calendar.shortWeekdaySymbols
                    Text(symbols[(index + calendar.firstWeekday - 1) % 7])
                        .font(AppFont.labelSmall)
                        .foregroundStyle(palette.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { day in
                    let isSelected = calendar.isDate(day, inSameDayAs: selected)
                    let isToday = calendar.isDate(day, inSameDayAs: today)
                    let inMonth = calendar.component(.month, from: day) == shownMonth
                    let count = counts[calendar.startOfDay(for: day)] ?? 0
                    Button {
                        selected = day
                    } label: {
                        VStack(spacing: 1) {
                            Text("\(calendar.component(.day, from: day))")
                                .font(AppFont.labelLarge.weight(isToday || isSelected ? .bold : .regular))
                                .foregroundStyle(isSelected ? palette.onPrimary : isToday ? palette.primary : palette.onSurface)
                            if count > 0 {
                                Text("\(count)")
                                    .font(AppFont.labelSmall)
                                    .foregroundStyle(isSelected ? palette.onPrimary : palette.onSurfaceVariant)
                            }
                        }
                        .opacity(inMonth ? 1 : 0.45)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(isSelected ? palette.primary : palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected || isToday ? palette.primary : palette.outline.opacity(0.5), lineWidth: 1))
                        .padding(2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.outline, lineWidth: 1))
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 8)
    }

    private func step(_ months: Int) {
        if let next = Calendar.current.date(byAdding: .month, value: months, to: month) { month = next }
    }
}

/// Air times in the viewer's clock format (Appearance → Time format).
enum AirTime {
    @MainActor static func format(_ date: Date) -> String {
        format(date, twentyFourHour: AppearanceStore.shared.uses24Hour())
    }

    /// For closures SwiftUI may run off the main actor (a `TimelineView`'s content).
    static func format(_ date: Date, twentyFourHour: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = twentyFourHour ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }
}
#endif
