#if canImport(UIKit)
import AnililiCore
import SwiftUI
import UserNotifications

/// Warns before the sideloaded signature runs out (see `SigningProfile`): a banner on Home from
/// two days out, and a notification the morning before it expires (day 6 of a free Apple ID's 7).
/// Each launch reschedules it, so a re-signed install moves the reminder to its new date.
@MainActor
enum SigningReminder {
    static let key = "ios_signing_reminder"
    static let dismissedKey = "ios_signing_banner_dismissed"
    private static let id = "signing:expiry"

    /// Read once: the profile can't change while the app runs.
    static let profile: SigningProfile? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return SigningProfile(mobileprovision: data)
    }()

    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// What a closed banner is remembered by: this signature and the whole days it had left, so it
    /// comes back when another day goes.
    static func stage(_ profile: SigningProfile, now: Date) -> String {
        "\(Int(profile.expires.timeIntervalSince1970)):\(Int(max(0, profile.expires.timeIntervalSince(now)) / 86_400))"
    }

    static func schedule() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard enabled, let profile else { return }
        guard let when = SigningExpiry.reminderDate(profile, now: Date()) else { return }
        do {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else { return }
            } else if settings.authorizationStatus == .denied {
                Log.info("signing", "notifications are off for Anilili in iOS Settings")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Anilili expires tomorrow"
            content.body = "Refresh it in SideStore or Sideloadly before \(profile.expires.formatted(date: .omitted, time: .shortened)) tomorrow, or it won't open until it's signed again."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, when.timeIntervalSinceNow), repeats: false)
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            Log.info("signing", "signature expires \(profile.expires.formatted(.iso8601)); reminder at \(when.formatted(.iso8601))")
        } catch {
            Log.error("signing", "couldn't schedule the expiry reminder: \(Log.describe(error))")
        }
    }
}

/// Home's warning from two days before the signature expires, until it's closed for the day.
struct SigningBanner: View {
    @Environment(\.palette) private var palette
    @AppStorage(SigningReminder.dismissedKey) private var dismissed = ""

    var body: some View {
        if let profile = SigningReminder.profile {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let now = context.date
                if SigningExpiry.shouldWarn(profile, now: now), dismissed != SigningReminder.stage(profile, now: now) {
                    banner(profile, now: now)
                }
            }
        }
    }

    private func banner(_ profile: SigningProfile, now: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(SigningExpiry.remaining(profile, now: now))
                    .font(AppFont.labelLarge.weight(.bold))
                    .foregroundStyle(palette.onSurface)
                Text("Refresh in SideStore or Sideloadly before \(profile.expires.formatted(date: .abbreviated, time: .shortened)), or Anilili won't open until it's signed again.")
                    .font(AppFont.bodySmall)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                dismissed = SigningReminder.stage(profile, now: now)
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.onSurfaceVariant)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide until tomorrow")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, Metrics.pagePadding)
    }
}
#endif
