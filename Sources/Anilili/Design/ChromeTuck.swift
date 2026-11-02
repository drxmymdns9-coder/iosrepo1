#if canImport(UIKit)
import SwiftUI

/// Android's chrome behaviour: the tab bar (and Home's header) tuck away while the page
/// scrolls down and come back on the way up, unless Appearance → Keep the bars on screen is on.
///
/// A scroll view opts in with `.tucksChrome()`; the scroll view reports how far its content has
/// moved, and each change becomes a direction.
private struct TucksChrome: ViewModifier {
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content
            // Distance scrolled from the top: 0 at rest, positive going down, negative while
            // pulling to refresh.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { last, scrolled in
                let delta = scrolled - last
                guard !AppearanceStore.shared.staticChrome else {
                    if router.chromeHidden { router.chromeHidden = false }
                    return
                }
                // Near the top the bars always show; elsewhere a few points of travel decide.
                if scrolled < 40 {
                    if router.chromeHidden { withAnimation(.easeOut(duration: 0.2)) { router.chromeHidden = false } }
                } else if delta > 6, !router.chromeHidden {
                    withAnimation(.easeOut(duration: 0.2)) { router.chromeHidden = true }
                } else if delta < -6, router.chromeHidden {
                    withAnimation(.easeOut(duration: 0.2)) { router.chromeHidden = false }
                }
            }
    }
}

extension View {
    func tucksChrome() -> some View { modifier(TucksChrome()) }
}
#endif
