#if canImport(UIKit)
import SwiftUI

/// The app's top-level destinations, in the Android bar's order.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home, search, downloads, library, settings
    /// A tab of its own only in the TV layout's top navigation, as on Android TV; the phone opens
    /// the schedule from Home's header.
    case schedule

    var id: String { rawValue }

    /// The phone's tab bar.
    static let phone: [AppTab] = [.home, .search, .downloads, .library, .settings]
    /// The TV layout's top navigation, in Android TV's order; Settings sits with the icons.
    static let television: [AppTab] = [.home, .search, .schedule, .library, .downloads]

    /// Settings → App → Menu language relabels these, as on Android.
    var label: String {
        let spanish = MenuLanguage.usesSpanish
        switch self {
        case .home: return spanish ? "Inicio" : "Home"
        case .search: return spanish ? "Buscar" : "Search"
        case .downloads: return spanish ? "Descargas" : "Downloads"
        case .library: return spanish ? "Mi lista" : "My List"
        case .settings: return spanish ? "Ajustes" : "Settings"
        case .schedule: return spanish ? "Horario" : "Schedule"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .downloads: return "arrow.down.to.line"
        case .library: return "rectangle.stack.fill"
        case .settings: return "gearshape.fill"
        case .schedule: return "calendar"
        }
    }
}

/// For pages that hide the navigation bar: the page colour behind the status bar, fading out just
/// below it, so scrolled content passes under the clock instead of running into it. (iOS 26's
/// scroll edge effect does this only beneath a bar.)
private struct StatusBarShade: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            GeometryReader { proxy in
                let top = proxy.safeAreaInsets.top
                VStack(spacing: 0) {
                    palette.background.frame(height: max(0, top - 8))
                    LinearGradient(colors: [palette.background, palette.background.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                }
                .offset(y: -top)
            }
            .allowsHitTesting(false)
        }
    }
}

extension View {
    func statusBarShade() -> some View { modifier(StatusBarShade()) }
}

/// A round action floating above the tab bar in glass (Android's `FloatingNavDisc`), so it reads
/// as part of the same chrome.
struct FloatingNavDisc: View {
    @Environment(\.palette) private var palette
    let systemImage: String
    let label: String
    let action: () -> Void

    static let size: CGFloat = 52

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(palette.onSurface)
                .frame(width: Self.size, height: Self.size)
                .glassSurface(.navigation, in: Circle(), interactive: true)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A screen's big title, as Android's pages open: "Browse", "My List", "Settings".
struct PageTitle<Trailing: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(palette.onSurface)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(palette.onSurfaceVariant)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 8)
    }
}

extension PageTitle where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
#endif
