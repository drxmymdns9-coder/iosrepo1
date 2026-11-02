#if canImport(UIKit)
import AnililiCore
import UIKit

/// The home-screen icon in the theme's accent (Android's `AppIcon`, setting
/// `app_icon_matches_theme`). Each accent preset is an alternate icon declared in Info.plist and
/// drawn by `scripts/generate_icon_variants.py`; Custom has no fixed colour to ship and keeps the
/// default art, which is also what turning the setting off goes back to.
///
/// Android switches only while the app is in the background, so a launcher redraw never happens
/// under the viewer's thumb. iOS allows the switch only while the app is in front, and says so
/// with an alert of its own, so here it happens when the accent or the setting changes.
@MainActor
enum AppIconSync {
    static let key = "app_icon_matches_theme"

    static var matchesTheme: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// The alternate icon for the accent, or nil for the default art.
    static func iconName(accent: ThemeAccent, matchTheme: Bool) -> String? {
        guard matchTheme, accent != .custom else { return nil }
        return accent.rawValue
    }

    static func sync() {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.applicationState == .active else { return }
        let wanted = iconName(accent: AppearanceStore.shared.spec.accent, matchTheme: matchesTheme)
        guard app.alternateIconName != wanted else { return }
        app.setAlternateIconName(wanted) { error in
            if let error {
                Log.warning("theme", "app icon switch to \(wanted ?? "default") failed: \(Log.describe(error))")
            } else {
                Log.info("theme", "app icon → \(wanted ?? "default")")
            }
        }
    }
}
#endif
