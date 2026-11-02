import Foundation

/// The Android player's rules for skips and the next episode (`OutroWindowPolicy`,
/// `NextEpisodeCard`, `AutoSkipCountdown`), kept as pure functions so both apps decide alike.
public enum PlaybackPolicy {
    /// An outro has to reach this far into the file to count as the credits. AniSkip files some
    /// episodes with an "ed" in the fifth minute; believed, it ended episodes early.
    public static let outroCreditsTailFraction = 0.75
    /// The tail of a file in which the next episode is offered.
    public static let nextEpisodeTail: Double = 30
    /// The last stretch in which it's offered even over credits that haven't finished.
    public static let nextEpisodeFinal: Double = 5
    public static let nextEpisodeCountdown = 8
    public static let autoSkipCountdown = 3
    /// "Skip Intro" shows by itself for this long (played) once the playhead enters the opening,
    /// then only with the controls: a window can start at 0:00 and last ninety seconds, which kept
    /// the button over the picture for the whole opening. Android's `TIMED_SKIP_POPUP_MS`.
    public static let skipPopupSeconds: Double = 10
    /// The fixed skip for shows without timings, and its default length (Android's 85 s).
    public static let manualSkipSeconds = 85

    public enum NextTrigger: Equatable { case none, ending, afterCredits }

    /// Whether an outro window describes the credits of the file being played.
    public static func outroIsCredits(_ outro: SkipTimes.Window?, duration: Double) -> Bool {
        guard let outro, outro.start >= 0, outro.end > outro.start, duration > 0 else { return false }
        return outro.end >= duration * outroCreditsTailFraction
    }

    /// Only ever the end of the file: the tail window, held back while credits that reach the end
    /// are still rolling (unless only the final seconds are left).
    public static func nextTrigger(position: Double, duration: Double, outro: SkipTimes.Window?) -> NextTrigger {
        guard duration > 0, position >= 0 else { return .none }
        let remaining = duration - position
        guard (0...nextEpisodeTail).contains(remaining) else { return .none }
        guard outroIsCredits(outro, duration: duration), let outro else { return .ending }
        let creditsRolling = position < outro.end && remaining > nextEpisodeFinal
        return creditsRolling ? .none : .afterCredits
    }
}
