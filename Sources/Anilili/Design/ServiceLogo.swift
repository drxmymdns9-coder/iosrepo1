#if canImport(UIKit)
import AnililiCore
import SwiftUI

/// AniList's and MyAnimeList's own square logos, drawn from the Android app's vector drawables
/// (`ic_brand_anilist.xml`, `ic_brand_mal.xml`, both from Wikimedia Commons, public domain and
/// trademarked). Used only to name the service: the sign-in options and the account.
struct ServiceLogo: View {
    let service: AccountService
    var size: CGFloat = 40

    var body: some View {
        let art = Self.art(service)
        Canvas { context, canvas in
            let scale = canvas.width / art.viewport
            for layer in art.layers {
                context.fill(layer.path.applying(CGAffineTransform(scaleX: scale, y: scale)), with: .color(layer.color))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
        .accessibilityHidden(true)
    }

    private struct Layer {
        let color: Color
        let path: Path
    }

    private struct Art {
        let viewport: CGFloat
        let layers: [Layer]
    }

    private static func art(_ service: AccountService) -> Art {
        service == .anilist ? anilist : mal
    }

    private static let anilist = Art(viewport: 512, layers: [
        Layer(color: Color(argb: 0xFF1E2630), path: path("M0 0h512v512H0")),
        Layer(color: Color(argb: 0xFF02A9FF), path: path("M321.92 323.27V136.6c0-10.698-5.887-16.602-16.558-16.602h-36.433c-10.672 0-16.561 5.904-16.561 16.602v88.651c0 2.497 23.996 14.089 24.623 16.541 18.282 71.61 3.972 128.92-13.359 131.6 28.337 1.405 31.455 15.064 10.348 5.731 3.229-38.209 15.828-38.134 52.049-1.406.31.317 7.427 15.282 7.87 15.282h85.545c10.672 0 16.558-5.9 16.558-16.6v-36.524c0-10.698-5.886-16.602-16.558-16.602z")),
        Layer(color: Color(argb: 0xFFFEFEFE), path: path("M170.68 120 74.999 393h74.338l16.192-47.222h80.96L262.315 393h73.968l-95.314-273zm11.776 165.28 23.183-75.629 25.393 75.629z")),
    ])

    private static let mal = Art(viewport: 256, layers: [
        Layer(color: Color(argb: 0xFF2E51A2), path: path("M0,0h256v256h-256z")),
        Layer(color: .white, path: path("m 30.638616,88.40918 v 68.70703 h 17.759766 v -41.91016 l 15.470703,19.77344 16.67825,-19.77344 v 41.91016 H 98.307101 V 88.40918 H 80.547335 L 63.869085,109.82324 48.398382,88.40918 Z")),
        Layer(color: .white, path: path("m 182.49799,88.40918 v 68.70703 h 39.07974 l 3.78365,-14.65739 H 200.25775 V 88.40918 Z")),
        Layer(color: .white, path: path("m 149.65186,88.40918 c -21.64279,0 -35.06651,10.210974 -39.36914,25.39258 -4.19953,14.81779 0.34128,34.3715 10.28711,53.78906 l 14.85742,-10.47461 c 0,0 -7.06411,-9.21728 -8.39453,-23.03516 h 21.98437 v 23.03516 h 19.73438 v -51.67969 h -19.73438 v 14.9668 H 130.8003 c 1.71696,-11.1972 8.295,-17.30859 15.46875,-17.30859 h 25.8164 l -5.12304,-14.68555 z")),
    ])

    private static func path(_ data: String) -> Path {
        var path = Path()
        func point(_ p: SVGPath.Point) -> CGPoint { CGPoint(x: p.x, y: p.y) }
        for segment in SVGPath.parse(data) {
            switch segment {
            case .move(let p): path.move(to: point(p))
            case .line(let p): path.addLine(to: point(p))
            case .cubic(let a, let b, let end): path.addCurve(to: point(end), control1: point(a), control2: point(b))
            case .quad(let a, let end): path.addQuadCurve(to: point(end), control: point(a))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

/// The signed-out card on My List (Android's `ProfileHero`): what connecting an account brings,
/// and one full-width row per way in. Android's third row, Link a TV, has no iOS counterpart.
struct SignInCard: View {
    @Environment(\.palette) private var palette
    var onSignIn: (AccountService) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your anime, in one place")
                .font(AppFont.titleLarge.weight(.black))
                .foregroundStyle(palette.onSurface)
            Text("Connect AniList or MyAnimeList to browse every list, score, and episode progress from Anilili.")
                .font(AppFont.bodyMedium)
                .foregroundStyle(palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
            VStack(spacing: 10) {
                option(.anilist, title: "Continue with AniList", subtitle: "Sync with anilist.co", emphasized: true)
                option(.mal, title: "Continue with MyAnimeList", subtitle: "Sync with myanimelist.net", emphasized: false)
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.outline, lineWidth: 1))
    }

    /// One way in: the service's logo, what it does, and a chevron; the whole row is the target.
    private func option(_ service: AccountService, title: String, subtitle: String, emphasized: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            onSignIn(service)
        } label: {
            HStack(spacing: 14) {
                ServiceLogo(service: service)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AppFont.titleSmall.weight(.bold)).foregroundStyle(palette.onSurface).lineLimit(1)
                    Text(subtitle).font(AppFont.bodySmall).foregroundStyle(palette.onSurfaceVariant).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(emphasized ? palette.onSurface.opacity(0.10) : .clear, in: shape)
            .overlay(shape.strokeBorder(palette.outline.opacity(emphasized ? 0.9 : 0.6), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}
#endif
