#if canImport(UIKit)
import SwiftUI
import UIKit

/// Images shipped in the app target's resources.
enum BrandImage {
    /// The "ANILILI" header wordmark: a white alpha mask, tinted with the accent.
    static let wordmark = UIImage(named: "Wordmark", in: .module, with: nil) ?? UIImage()
    /// The logo mark, white on transparent, for the loader to fill.
    static let silhouette = UIImage(named: "Silhouette", in: .module, with: nil) ?? UIImage()
}

/// The "ANILILI" wordmark drawn in the theme's accent: white in the default monochrome theme,
/// blood red or neon green when the viewer picks one (Android's `AnililiWordmark`).
struct Wordmark: View {
    @Environment(\.palette) private var palette
    var height: CGFloat = 22

    var body: some View {
        Image(uiImage: BrandImage.wordmark)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(palette.primary)
            .accessibilityLabel("Anilili")
    }
}

/// The app's loader: the logo filling with liquid, draining, and filling again. A port of the
/// Android app's `WaterFillLogoIndicator`: a 2.8 s pour, a short hold, a 1 s drain, a rest.
struct WaterFillLoader: View {
    @Environment(\.palette) private var palette
    var size: CGFloat = 72
    var color: Color?

    private static let rise = 2.8
    private static let hold = 0.45
    private static let drain = 1.0
    private static let rest = 0.25

    @State private var start = Date()

    var body: some View {
        let tint = color ?? palette.primary
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            Canvas { context, canvasSize in
                let rect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: canvasSize.width * 0.05, dy: canvasSize.height * 0.05)
                var mark = context.resolve(Image(uiImage: BrandImage.silhouette).renderingMode(.template))
                mark.shading = .color(tint.opacity(0.16))
                context.draw(mark, in: rect)

                let level = Self.level(elapsed)
                guard level > 0 else { return }
                context.clipToLayer { layer in
                    layer.draw(Image(uiImage: BrandImage.silhouette), in: rect)
                }
                let surfaceY = rect.maxY - rect.height * level
                let amplitude = rect.height * 0.025 * (level < 0.98 ? 1 : 0.3)
                let phase = elapsed * 2.4
                var water = Path()
                water.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                let steps = 24
                for step in 0...steps {
                    let x = rect.minX + rect.width * CGFloat(step) / CGFloat(steps)
                    let wave = sin(Double(step) / Double(steps) * .pi * 2 + phase)
                    water.addLine(to: CGPoint(x: x, y: surfaceY + amplitude * CGFloat(wave)))
                }
                water.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                water.closeSubpath()
                context.fill(water, with: .color(tint))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Loading")
    }

    /// How full the mark is, 0...1, at `elapsed` seconds into the loop.
    static func level(_ elapsed: TimeInterval) -> CGFloat {
        let cycle = rise + hold + drain + rest
        let t = elapsed.truncatingRemainder(dividingBy: cycle)
        switch t {
        case ..<rise: return CGFloat(easeOut(t / rise))
        case ..<(rise + hold): return 1
        case ..<(rise + hold + drain): return CGFloat(1 - easeInOut((t - rise - hold) / drain))
        default: return 0
        }
    }

    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    private static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
}

/// A full-page loading state: the water-fill mark with an optional line under it, centred.
struct LoadingState: View {
    @Environment(\.palette) private var palette
    var message: String?

    var body: some View {
        VStack(spacing: 18) {
            WaterFillLoader(size: 84)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
