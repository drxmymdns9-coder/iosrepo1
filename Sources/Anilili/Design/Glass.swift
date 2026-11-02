#if canImport(UIKit)
import SwiftUI

/// Frosted glass the way the Android app draws it: what's behind blurred and darkened enough that
/// white type keeps its contrast, under a hairline rim. On iOS 26 it is the system's Liquid Glass,
/// tinted the same way, which brings its own rim and light. Each `GlassSection` can be switched off
/// in Appearance; then the surface falls back to the painted glass Android uses below Android 12.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.palette) private var palette
    let section: GlassSection
    let shape: S
    var tint: Color?
    var fallbackOpacity: Double = 0.96
    var rim = true
    var interactive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        let live = AppearanceStore.shared.glassEnabled(section)
        if live, #available(iOS 26, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular.tint((tint ?? palette.panel2).opacity(0.45)).interactive(interactive), in: shape)
        } else {
            frosted(content, live: live)
        }
    }

    private func frosted(_ content: Content, live: Bool) -> some View {
        content
            .background {
                if live {
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.fill((tint ?? palette.panel2).opacity(0.62)))
                } else {
                    shape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: palette.line2.opacity(0.88), location: 0),
                                .init(color: palette.panel2.opacity(fallbackOpacity), location: 0.4),
                                .init(color: palette.containerLowest.opacity(0.98), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .overlay {
                if rim {
                    shape.strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: palette.text2.opacity(0.18), location: 0),
                                .init(color: palette.line2.opacity(0.45), location: 0.5),
                                .init(color: palette.line.opacity(0.35), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
            }
            .clipShape(shape)
    }
}

/// Smoked glass for small pills drawn over artwork (genre pills, hero tags, card buttons): a
/// lighter tint over the blur (Liquid Glass on iOS 26) when glass is on, a heavier black scrim when
/// it's off.
struct SmokedGlass<S: Shape>: ViewModifier {
    let section: GlassSection
    let shape: S
    var liveTint: Double = 0.30
    var paintedTint: Double = 0.52

    @ViewBuilder
    func body(content: Content) -> some View {
        let live = AppearanceStore.shared.glassEnabled(section)
        if live, #available(iOS 26, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular.tint(Color.black.opacity(liveTint)), in: shape)
        } else {
            smoked(content, live: live)
        }
    }

    private func smoked(_ content: Content, live: Bool) -> some View {
        content
            .background {
                if live {
                    shape.fill(.ultraThinMaterial).overlay(shape.fill(Color.black.opacity(liveTint)))
                } else {
                    shape.fill(Color.black.opacity(paintedTint))
                }
            }
            .clipShape(shape)
    }
}

extension View {
    /// `interactive`: on iOS 26 the glass answers touches (for glass that is itself a button).
    func glassSurface<S: InsettableShape>(_ section: GlassSection, in shape: S, tint: Color? = nil, rim: Bool = true, interactive: Bool = false) -> some View {
        modifier(GlassSurface(section: section, shape: shape, tint: tint, rim: rim, interactive: interactive))
    }

    func smokedGlass<S: Shape>(_ section: GlassSection, in shape: S, liveTint: Double = 0.30, paintedTint: Double = 0.52) -> some View {
        modifier(SmokedGlass(section: section, shape: shape, liveTint: liveTint, paintedTint: paintedTint))
    }
}
#endif
