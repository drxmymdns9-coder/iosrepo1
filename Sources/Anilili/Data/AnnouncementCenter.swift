#if canImport(UIKit)
import AnililiCore
import Observation
import SwiftUI
import UserNotifications

/// Project announcements (Android's `AnnouncementManager`, setting `announcements`): fetched at
/// launch and on return to the app at most every 15 minutes, trusted only once their signature
/// checks out, and shown once each. One found at launch opens straight away; one found later
/// waits as a notification rather than covering an episode, and opens when it's tapped.
@MainActor
@Observable
final class AnnouncementCenter {
    static let shared = AnnouncementCenter()
    static let key = "announcements"
    private static let seenKey = "announcement_seen_ids"
    private static let lastCheckKey = "ios_announcement_last_check"
    private static let lastKey = "ios_announcement_last"
    private static let checkInterval: TimeInterval = 15 * 60

    /// The announcement on screen.
    var showing: Announcement?
    @ObservationIgnored private var launched = false

    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    func check(force: Bool = false) {
        let defaults = UserDefaults.standard
        let atLaunch = !launched
        launched = true
        guard Self.enabled else { return }
        guard force || Date().timeIntervalSince1970 - defaults.double(forKey: Self.lastCheckKey) >= Self.checkInterval else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        Task {
            guard let announcement = await AnnouncementSource.fetch() else { return }
            guard announcement.applies(now: Int(Date().timeIntervalSince1970)) else {
                Log.info("announce", "\(announcement.id) isn't for this app (version bounds or expired)")
                return
            }
            var seen = defaults.stringArray(forKey: Self.seenKey) ?? []
            guard !seen.contains(announcement.id) else { return }
            seen = Array(([announcement.id] + seen).prefix(20))
            defaults.set(seen, forKey: Self.seenKey)
            if let data = try? JSONEncoder().encode(announcement) { defaults.set(data, forKey: Self.lastKey) }
            Log.info("announce", "new: \(announcement.id) \"\(announcement.title)\"\(announcement.urgent ? " (urgent)" : "")")
            if atLaunch { showing = announcement } else { await notify(announcement) }
        }
    }

    /// A tapped announcement notification.
    func open(id: String) {
        guard let data = UserDefaults.standard.data(forKey: Self.lastKey),
              let announcement = try? JSONDecoder().decode(Announcement.self, from: data), announcement.id == id else { return }
        showing = announcement
    }

    private func notify(_ announcement: Announcement) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else {
            // No notifications allowed: show it now instead of losing it.
            showing = announcement
            return
        }
        let content = UNMutableNotificationContent()
        content.title = announcement.title
        content.body = announcement.message
        content.sound = .default
        content.userInfo = ["announcementId": announcement.id]
        try? await center.add(UNNotificationRequest(identifier: "announcement:\(announcement.id)", content: content, trigger: nil))
    }
}

/// The message itself (Android's `AnnouncementHost`): the whole link printed, selectable, above
/// the button that opens it, so it's clear where it goes before it's followed.
struct AnnouncementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.palette) private var palette
    let announcement: Announcement

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: announcement.urgent ? "exclamationmark.triangle.fill" : "megaphone.fill")
                    .foregroundStyle(announcement.urgent ? palette.error : palette.primary)
                Text(announcement.title).font(AppFont.titleLarge).foregroundStyle(palette.onSurface)
            }
            Text(announcement.message)
                .font(AppFont.bodyLarge)
                .foregroundStyle(palette.onSurface)
                .textSelection(.enabled)
            if let link = announcement.url, let url = URL(string: link) {
                Text(link)
                    .font(AppFont.bodySmall.monospaced())
                    .foregroundStyle(palette.onSurfaceVariant)
                    .textSelection(.enabled)
                Button {
                    openURL(url)
                    dismiss()
                } label: {
                    Text(announcement.urlLabel ?? "Open \(url.host ?? "link")")
                        .font(AppFont.labelLarge.weight(.bold))
                        .foregroundStyle(palette.onPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(palette.primary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Button("Close") { dismiss() }
                .font(AppFont.labelLarge)
                .foregroundStyle(palette.onSurfaceVariant)
                .frame(maxWidth: .infinity)
            Text("Signed by the Anilili project; checked on this device.")
                .font(AppFont.labelSmall)
                .foregroundStyle(palette.onSurfaceVariant)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .background(palette.background)
        .presentationDetents([.medium, .large])
    }
}
#endif
