#if canImport(UIKit)
import Foundation

enum VideoEngineChoice: String, CaseIterable, Identifiable {
    case automatic
    case avPlayer = "avplayer"
    case vlc
    case ask

    var id: String { rawValue }

    var label: String {
        if MenuLanguage.usesArabic {
            switch self {
            case .automatic: return "تلقائي"
            case .avPlayer: return "AVPlayer دائمًا"
            case .vlc: return "VLC دائمًا"
            case .ask: return "السؤال في كل مرة"
            }
        }
        switch self {
        case .automatic: return "Automatic"
        case .avPlayer: return "Always AVPlayer"
        case .vlc: return "Always VLC"
        case .ask: return "Ask every time"
        }
    }

    var detail: String {
        if MenuLanguage.usesArabic {
            switch self {
            case .automatic: return "يختار VLC لملفات MKV وAVPlayer لبقية المصادر"
            case .avPlayer: return "يفرض مشغل Apple حتى لو كان الملف MKV"
            case .vlc: return "يفرض VLC لدعم MKV والترجمات المضمنة وASS"
            case .ask: return "اختر المشغل قبل بدء كل حلقة"
            }
        }
        switch self {
        case .automatic: return "VLC for MKV, AVPlayer for other sources"
        case .avPlayer: return "Always use Apple's player"
        case .vlc: return "Always use VLC for MKV and embedded subtitles"
        case .ask: return "Choose a player before each episode"
        }
    }

    static var current: VideoEngineChoice {
        VideoEngineChoice(rawValue: UserDefaults.standard.string(forKey: Setting.videoEngine) ?? "") ?? .ask
    }
}
#endif
