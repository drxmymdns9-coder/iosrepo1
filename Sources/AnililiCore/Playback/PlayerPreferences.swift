import Foundation

/// The player's choices from Android's `SettingsStore`: the same stored values and defaults, so a
/// backup carries them between the two apps, and the rules that turn a choice into a track or a
/// rendition.

/// The quality an episode starts at (Android's `DefaultQuality`).
public enum DefaultQuality: String, CaseIterable, Identifiable, Sendable {
    case auto
    case highest
    case p1080 = "1080"
    case p720 = "720"
    case p480 = "480"
    case p360 = "360"

    public static let key = "default_quality"
    /// Android starts phones with room to spare on the highest rendition, and every iPhone the
    /// app runs on has room to spare.
    public static let fallback = DefaultQuality.highest

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .highest: return "Highest"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        case .p360: return "360p · Data Saver"
        }
    }

    public var maxHeight: Int? {
        switch self {
        case .auto, .highest: return nil
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        case .p360: return 360
        }
    }

    /// The height to cap the stream at among `heights`, or nil to leave adaptive selection alone.
    /// A cap no rendition fits under takes the lowest, so the episode still starts.
    public func pickHeight(_ heights: [Int]) -> Int? {
        switch self {
        case .auto: return nil
        case .highest: return heights.max()
        default:
            guard let target = maxHeight else { return nil }
            return heights.filter { $0 <= target }.max() ?? heights.min()
        }
    }

    public static func stored(_ value: String?) -> DefaultQuality {
        value.flatMap(DefaultQuality.init(rawValue:)) ?? fallback
    }
}

/// How far ahead the player buffers (Android's `PlaybackBufferSize`).
public enum PlaybackBufferSize: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case small
    case medium
    case large
    case veryLarge = "very_large"

    public static let key = "playback_buffer_size"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .veryLarge: return "Very large"
        }
    }

    public var detail: String {
        switch self {
        case .automatic: return "Follows the device"
        case .small: return "About 15 seconds"
        case .medium: return "About 40 seconds"
        case .large: return "About 90 seconds"
        case .veryLarge: return "Up to 4 minutes"
        }
    }

    /// AVPlayerItem's `preferredForwardBufferDuration`; 0 lets AVFoundation decide.
    public var seconds: Double {
        switch self {
        case .automatic: return 0
        case .small: return 15
        case .medium: return 40
        case .large: return 90
        case .veryLarge: return 240
        }
    }

    public static func stored(_ value: String?) -> PlaybackBufferSize {
        value.flatMap(PlaybackBufferSize.init(rawValue:)) ?? .automatic
    }
}

/// A language for an audio or subtitle track, stored as Android stores it: the three-letter code
/// media manifests are written in, with "" for Automatic.
public struct TrackLanguage: Hashable, Identifiable, Sendable {
    public let code: String
    public let label: String
    /// The two-letter form, which is how most servers name their subtitle files.
    public let shortCode: String

    public var id: String { code }
    public var isAutomatic: Bool { code.isEmpty }

    public static let automatic = TrackLanguage(code: "", label: "Automatic", shortCode: "")

    /// Android's `PreferredAudioLanguage`, in its order.
    public static let audio: [TrackLanguage] = [
        .automatic,
        .init(code: "jpn", label: "Japanese", shortCode: "ja"),
        .init(code: "eng", label: "English", shortCode: "en"),
        .init(code: "hin", label: "Hindi", shortCode: "hi"),
        .init(code: "tam", label: "Tamil", shortCode: "ta"),
        .init(code: "tel", label: "Telugu", shortCode: "te"),
        .init(code: "ben", label: "Bengali", shortCode: "bn"),
        .init(code: "mal", label: "Malayalam", shortCode: "ml"),
        .init(code: "kan", label: "Kannada", shortCode: "kn"),
        .init(code: "mar", label: "Marathi", shortCode: "mr"),
        .init(code: "kor", label: "Korean", shortCode: "ko"),
        .init(code: "zho", label: "Chinese", shortCode: "zh"),
        .init(code: "spa", label: "Spanish", shortCode: "es"),
        .init(code: "por", label: "Portuguese", shortCode: "pt"),
        .init(code: "ara", label: "Arabic", shortCode: "ar"),
        .init(code: "fra", label: "French", shortCode: "fr"),
        .init(code: "deu", label: "German", shortCode: "de"),
    ]

    /// Android's `PreferredSubtitleLanguage`, in its order.
    public static let subtitles: [TrackLanguage] = [
        .automatic,
        .init(code: "eng", label: "English", shortCode: "en"),
        .init(code: "jpn", label: "Japanese", shortCode: "ja"),
        .init(code: "spa", label: "Spanish", shortCode: "es"),
        .init(code: "por", label: "Portuguese", shortCode: "pt"),
        .init(code: "ara", label: "Arabic", shortCode: "ar"),
        .init(code: "fra", label: "French", shortCode: "fr"),
        .init(code: "deu", label: "German", shortCode: "de"),
        .init(code: "ita", label: "Italian", shortCode: "it"),
        .init(code: "tur", label: "Turkish", shortCode: "tr"),
        .init(code: "rus", label: "Russian", shortCode: "ru"),
        .init(code: "pol", label: "Polish", shortCode: "pl"),
        .init(code: "ind", label: "Indonesian", shortCode: "id"),
        .init(code: "hin", label: "Hindi", shortCode: "hi"),
        .init(code: "zho", label: "Chinese", shortCode: "zh"),
        .init(code: "kor", label: "Korean", shortCode: "ko"),
    ]

    public static let audioKey = "preferred_audio_language"
    public static let secondaryAudioKey = "secondary_audio_language"
    public static let subtitleKey = "preferred_subtitle_language"
    public static let secondarySubtitleKey = "secondary_subtitle_language"

    /// The stored value as one of `list`. Earlier iOS builds stored two-letter subtitle codes
    /// ("en") under Android's key; those read as the same language. Anything else is Automatic.
    public static func stored(_ value: String?, in list: [TrackLanguage]) -> TrackLanguage {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return .automatic }
        return list.first { $0.code == value || $0.shortCode == value } ?? .automatic
    }

    /// Whether a track tagged `tag` (a two- or three-letter code, a locale such as "en-US", or a
    /// label such as "English") is in this language.
    public func matches(_ tag: String?) -> Bool {
        guard !isAutomatic, let tag = tag?.trimmingCharacters(in: .whitespaces).lowercased(), !tag.isEmpty else { return false }
        if tag == label.lowercased() || tag.hasPrefix(label.lowercased() + " ") || tag.hasPrefix(label.lowercased() + "(") { return true }
        let base = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? tag
        // ISO 639-2/B spellings some manifests use for the same languages.
        let bibliographic: [String: String] = ["fre": "fra", "ger": "deu", "chi": "zho"]
        let normalised = bibliographic[base] ?? base
        return normalised == code || normalised == shortCode
    }

    /// The first of `candidates` in the first of `preferences` that any candidate is in; nil when
    /// none is (the caller keeps its own pick).
    public static func pick<T>(_ candidates: [T], preferences: [TrackLanguage], tag: (T) -> String?) -> T? {
        for preference in preferences where !preference.isAutomatic {
            if let match = candidates.first(where: { preference.matches(tag($0)) }) { return match }
        }
        return nil
    }
}

/// The player's skip button and "Watched at" bounds (Android's `SKIP_BUTTON_*` and
/// `WATCHED_THRESHOLD_*`).
public enum PlayerLimits {
    public static let skipButtonKey = "skip_button_seconds"
    public static let skipButtonDefault = 85
    public static let skipButtonRange = 5...180
    public static let skipButtonPresets = [30, 60, 85, 90, 120]

    public static let watchedThresholdKey = "watched_threshold_percent"
    public static let watchedThresholdDefault = 80
    public static let watchedThresholdRange = 50...95
    public static let watchedThresholdPresets = [70, 80, 90]

    public static let defaultSpeedKey = "default_playback_speed"
    public static let holdSpeedKey = "hold_playback_speed"
    /// Android's `PlaybackSpeeds`.
    public static let speeds: [Double] = [0.25, 0.5, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 3.5, 4]
    public static let speedRange = 0.25...4.0

    public static func skipSeconds(_ stored: Int?) -> Int {
        clamp(stored ?? skipButtonDefault, skipButtonRange)
    }

    public static func watchedPercent(_ stored: Int?) -> Int {
        clamp(stored ?? watchedThresholdDefault, watchedThresholdRange)
    }

    public static func speed(_ stored: Double?, default fallback: Double) -> Double {
        guard let stored, stored.isFinite else { return fallback }
        return min(max(stored, speedRange.lowerBound), speedRange.upperBound)
    }

    /// "1x", "1.25x", the way Android writes a speed.
    public static func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))x" : "\(String(format: "%g", speed))x"
    }

    static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
