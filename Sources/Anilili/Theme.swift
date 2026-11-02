#if canImport(UIKit)
import SwiftUI

/// Shorthands for the live app theme, for views that don't take part in show-coloured pages.
/// New code reads `@Environment(\.palette)` instead, which a show page can re-seed.
@MainActor
enum Theme {
    static var palette: Palette { AppearanceStore.shared.palette }
    static var accent: Color { palette.primary }
    static var background: Color { palette.background }
    static var panel: Color { palette.containerHigh.opacity(0.7) }
    static var secondaryText: Color { palette.onSurfaceVariant }
}

extension Color {
    /// AniList's `coverImage.color`, e.g. `#e4a15d`.
    init?(hex: String?) {
        guard var hex, hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
#endif
