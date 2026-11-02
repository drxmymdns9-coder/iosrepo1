import Foundation

/// Which layout the app draws (Android's `FormFactorPreference`, under its `form_factor_preference`
/// key and stored values, so a backup means the same choice on either device).
///
/// On Android, Automatic follows what the device reports and TV is the escape for a set-top box
/// that calls itself a tablet. On iOS the television layout is the iPad's: the couch layout's top
/// navigation, full-bleed spotlight and wide cards suit a screen that size better than the
/// phone's tab bar and portrait rails, so Automatic gives it to an iPad and Phone or tablet is the
/// way back.
public enum FormFactorPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case television
    case handheld

    public static let key = "form_factor_preference"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: "Automatic"
        case .television: "TV"
        case .handheld: "Phone or tablet"
        }
    }

    public static func stored(_ value: String?) -> FormFactorPreference {
        value.flatMap(FormFactorPreference.init(rawValue:)) ?? .automatic
    }

    /// Whether the television layout draws. Only ever on an iPad, and only in a window wide enough
    /// for its top navigation: Slide Over and the narrow side of Split View get the phone's layout
    /// whatever was chosen, as an iPhone always does (it stays portrait outside the player).
    public func usesTelevision(isPad: Bool, wideWindow: Bool) -> Bool {
        guard isPad, wideWindow else { return false }
        return self != .handheld
    }
}
