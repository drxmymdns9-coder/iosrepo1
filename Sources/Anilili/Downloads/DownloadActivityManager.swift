#if canImport(ActivityKit)
import ActivityKit
import Foundation

@available(iOS 16.1, *)
@MainActor
final class DownloadActivityManager {
    static let shared = DownloadActivityManager()
    private var activities: [String: Activity<DownloadActivityAttributes>] = [:]

    func start(id: String, mediaID: Int, title: String, episode: Int, source: String = "") {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = DownloadActivityAttributes.ContentState(
            episode: episode, progress: 0, status: .queued, source: source
        )
        do {
            let activity = try Activity.request(
                attributes: DownloadActivityAttributes(title: title, mediaID: mediaID),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            activities[id] = activity
        } catch {
            print("[Anilili] live download activity unavailable: \(error)")
        }
    }

    func update(id: String, episode: Int, progress: Double, status: DownloadActivityAttributes.ContentState.Status, source: String) {
        guard let activity = activities[id] else { return }
        let state = DownloadActivityAttributes.ContentState(
            episode: episode, progress: progress, status: status, source: source
        )
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func finish(id: String, episode: Int, source: String, failed: Bool = false) {
        guard let activity = activities.removeValue(forKey: id) else { return }
        let state = DownloadActivityAttributes.ContentState(
            episode: episode, progress: failed ? 0 : 1,
            status: failed ? .failed : .completed, source: source
        )
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: failed ? .immediate : .default)
        }
    }
}
#endif
