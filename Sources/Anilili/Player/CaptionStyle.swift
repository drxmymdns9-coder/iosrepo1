#if canImport(UIKit)
import SwiftUI

/// Android's `CaptionStyle`, under its keys and defaults, so a backup carries it across.
enum CaptionKey {
    static let backgroundOpacity = "caption_background_opacity"   // 60
    static let backgroundColor = "caption_background_color"       // black
    static let textScale = "caption_text_scale"                   // 100
    static let textOpacity = "caption_text_opacity"               // 100
    static let bold = "caption_bold_text"                         // true
    static let margin = "caption_bottom_margin"                   // 12
    static let position = "caption_position"                      // bottom
    static let textColor = "caption_text_color"                   // white
    static let edge = "caption_edge_style"                        // none
    static let font = "caption_font"                              // sans
    static let horizontalAnchor = "caption_horizontal_anchor"     // 50: 0 left edge, 100 right

    static let all = [backgroundOpacity, backgroundColor, textScale, textOpacity, bold, margin, position, textColor, edge,
                      font, horizontalAnchor]
}

enum CaptionOptions {
    static let textColors: [(value: String, label: String, color: Color)] = [
        ("white", "White", Color(argb: 0xFFFFFFFF)), ("yellow", "Yellow", Color(argb: 0xFFFFEB3B)), ("cyan", "Cyan", Color(argb: 0xFF4DD0E1)),
        ("green", "Green", Color(argb: 0xFF81C784)), ("magenta", "Magenta", Color(argb: 0xFFFF80AB)),
    ]
    static let backgroundColors: [(value: String, label: String, color: Color)] = [
        ("black", "Black", Color(argb: 0xFF000000)), ("gray", "Gray", Color(argb: 0xFF4A4A4A)),
        ("navy", "Navy", Color(argb: 0xFF102A43)), ("white", "White", Color(argb: 0xFFFFFFFF)),
    ]
    static let edges: [(value: String, label: String)] = [("none", "None"), ("outline", "Outline"), ("shadow", "Shadow")]
    static let positions: [(value: String, label: String)] = [("bottom", "Bottom"), ("top", "Top")]
    /// Android's `CaptionFont`, drawn with the nearest iOS design.
    static let fonts: [(value: String, label: String)] = [
        ("sans", "Sans"), ("serif", "Serif"), ("mono", "Mono"), ("condensed", "Narrow"), ("casual", "Casual"), ("cursive", "Script"),
    ]

    static func font(_ value: String, size: CGFloat, bold: Bool) -> Font {
        let weight: Font.Weight = bold ? .semibold : .regular
        switch value {
        case "serif": return .system(size: size, weight: weight, design: .serif)
        case "mono": return .system(size: size, weight: weight, design: .monospaced)
        case "condensed": return .system(size: size, weight: weight).width(.condensed)
        case "casual": return .system(size: size, weight: weight, design: .rounded)
        case "cursive": return .custom("Snell Roundhand", size: size * 1.15).weight(weight)
        default: return .system(size: size, weight: weight)
        }
    }

    static func textColor(_ value: String) -> Color { textColors.first { $0.value == value }?.color ?? .white }
    static func backgroundColor(_ value: String) -> Color { backgroundColors.first { $0.value == value }?.color ?? .black }
}

/// One caption drawn in the viewer's style; used by the player and the settings preview.
struct CaptionText: View {
    @AppStorage(CaptionKey.backgroundOpacity) private var backgroundOpacity = 60
    @AppStorage(CaptionKey.backgroundColor) private var backgroundColor = "black"
    @AppStorage(CaptionKey.textScale) private var scale = 100
    @AppStorage(CaptionKey.textOpacity) private var textOpacity = 100
    @AppStorage(CaptionKey.bold) private var bold = true
    @AppStorage(CaptionKey.textColor) private var textColor = "white"
    @AppStorage(CaptionKey.edge) private var edge = "none"
    @AppStorage(CaptionKey.font) private var font = "sans"
    let text: String
    var baseSize: CGFloat = 16

    var body: some View {
        let label = Text(text)
            .font(CaptionOptions.font(font, size: baseSize * CGFloat(scale) / 100, bold: bold))
            .foregroundStyle(CaptionOptions.textColor(textColor).opacity(Double(textOpacity) / 100))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(CaptionOptions.backgroundColor(backgroundColor).opacity(Double(backgroundOpacity) / 100), in: RoundedRectangle(cornerRadius: 6))
        switch edge {
        case "outline":
            label.shadow(color: .black, radius: 0, x: 1, y: 1).shadow(color: .black, radius: 0, x: -1, y: -1)
                .shadow(color: .black, radius: 0, x: 1, y: -1).shadow(color: .black, radius: 0, x: -1, y: 1)
        case "shadow":
            label.shadow(color: .black.opacity(0.9), radius: 3, x: 2, y: 2)
        default:
            label
        }
    }
}
#endif
