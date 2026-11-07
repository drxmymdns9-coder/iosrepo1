#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Shared state for the download Live Activity. The widget extension can import this file
/// unchanged when it is added to the Codemagic target graph.
@available(iOS 16.1, *)
public struct DownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var episode: Int
        public var progress: Double
        public var status: Status
        public var source: String

        public enum Status: String, Codable, Hashable {
            case queued
            case downloading
            case paused
            case completed
            case failed
        }

        public init(episode: Int, progress: Double, status: Status, source: String) {
            self.episode = episode
            self.progress = progress
            self.status = status
            self.source = source
        }
    }

    public var title: String
    public var mediaID: Int

    public init(title: String, mediaID: Int) {
        self.title = title
        self.mediaID = mediaID
    }
}
#endif
