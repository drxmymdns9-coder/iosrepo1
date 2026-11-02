#if canImport(UIKit)
import SwiftUI
import UIKit

/// The Android app's type scale (`MiruroTypography`) plus the Material 3 defaults it leaves alone,
/// in points for the system font. Scales with Dynamic Type from these sizes.
enum AppFont {
    static let displaySmall = Font.system(size: 36, weight: .black)
    static let headlineMedium = Font.system(size: 28, weight: .black)
    static let headlineLarge = Font.system(size: 32, weight: .bold)
    static let titleLarge = Font.system(size: 22, weight: .bold)
    static let titleMedium = Font.system(size: 16, weight: .semibold)
    static let titleSmall = Font.system(size: 14, weight: .semibold)
    static let bodyLarge = Font.system(size: 16)
    static let bodyMedium = Font.system(size: 14)
    static let bodySmall = Font.system(size: 12)
    static let labelLarge = Font.system(size: 13, weight: .semibold)
    static let labelMedium = Font.system(size: 12, weight: .medium)
    static let labelSmall = Font.system(size: 11, weight: .medium)
}

/// Phone layout metrics from the Android app's `AppDeviceProfile`.
enum Metrics {
    static let pagePadding: CGFloat = 16
    static let gridSpacing: CGFloat = 9
    static let railSpacing: CGFloat = 10
    /// Android's `AppDeviceProfile.posterColumns`: three on a phone, more as an iPad's window
    /// widens (4 from 600 points, 6 from 840, 7 from 1000), so a grid's posters stay poster-sized.
    @MainActor static var posterColumns: Int {
        switch screenWidth {
        case 1_000...: return 7
        case 840...: return 6
        case 600...: return 4
        default: return 3
        }
    }

    /// The window's width: an iPad's turns with it, and can be a Split View or Slide Over window.
    @MainActor static var screenWidth: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first(where: \.isKeyWindow)?.bounds.width ?? scene?.screen.bounds.width ?? 390
    }

    /// Android's `phoneRailPosterWidth`: three posters and a third of the next peeking in,
    /// between 108 and 150 wide, and never wider than Home allows (`available / 2.2`).
    static func railPosterWidth(screenWidth: CGFloat) -> CGFloat {
        let available = screenWidth - 2 * pagePadding - 3 * railSpacing
        let poster = min(max(available / 3.35, 108), 150)
        return min(poster, (screenWidth - 2 * pagePadding) / 2.2)
    }
}
#endif
