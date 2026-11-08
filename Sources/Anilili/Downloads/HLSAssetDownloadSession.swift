#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// System-managed HLS downloads. Unlike a TaskGroup of TS requests, AVAssetDownloadURLSession
/// keeps the asset transfer alive when the app is suspended or relaunched by iOS.
final class HLSAssetDownloadSession: NSObject, AVAssetDownloadDelegate, @unchecked Sendable {
    static let shared = HLSAssetDownloadSession()
    static let identifier = "com.anilili.ios.hls-assets"

    private struct Pending: Codable {
        var taskID: Int
        var destination: String
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var waiters: [String: [(Result<URL, Error>) -> Void]] = [:]
    private var backgroundCompletion: (() -> Void)?

    private lazy var session: AVAssetDownloadURLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        return AVAssetDownloadURLSession(configuration: configuration,
                                         assetDownloadDelegate: self,
                                         delegateQueue: nil)
    }()

    private var indexURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("hls-background-tasks.json")
    }

    private override init() {
        super.init()
        restore()
        _ = session
    }

    func download(assetURL: URL, headers: [String: String], title: String, to destination: URL) async throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let key = destination.path
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiters[key, default: []].append { result in continuation.resume(with: result) }
            if pending.values.contains(where: { $0.destination == key }) {
                lock.unlock()
                return
            }
            var options: [String: Any] = [:]
            if !headers.isEmpty { options[AVURLAssetHTTPHeaderFieldsKey] = headers }
            let asset = AVURLAsset(url: assetURL, options: options)
            guard let task = session.makeAssetDownloadTask(asset: asset,
                                                           assetTitle: title,
                                                           assetArtworkData: nil,
                                                           options: nil) else {
                let callbacks = waiters.removeValue(forKey: key) ?? []
                lock.unlock()
                callbacks.forEach { $0(.failure(HLSAssetError.cannotCreateTask)) }
                return
            }
            pending[task.taskIdentifier] = Pending(taskID: task.taskIdentifier, destination: key)
            persistLocked()
            task.resume()
            lock.unlock()
        }
    }

    func handleEvents(for identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.identifier else { completionHandler(); return }
        _ = session
        lock.lock()
        backgroundCompletion = completionHandler
        lock.unlock()
        session.getAllTasks { _ in }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = backgroundCompletion
        backgroundCompletion = nil
        lock.unlock()
        completion?()
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock()
        guard let item = pending.removeValue(forKey: assetDownloadTask.taskIdentifier) else { lock.unlock(); return }
        let destination = URL(fileURLWithPath: item.destination)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            persistLocked()
            let callbacks = waiters.removeValue(forKey: item.destination) ?? []
            lock.unlock()
            callbacks.forEach { $0(.success(destination)) }
            wakeDownloadStore()
        } catch {
            persistLocked()
            let callbacks = waiters.removeValue(forKey: item.destination) ?? []
            lock.unlock()
            callbacks.forEach { $0(.failure(error)) }
            wakeDownloadStore()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        guard let item = pending.removeValue(forKey: task.taskIdentifier) else { lock.unlock(); return }
        persistLocked()
        let callbacks = waiters.removeValue(forKey: item.destination) ?? []
        lock.unlock()
        callbacks.forEach { $0(.failure(error)) }
        wakeDownloadStore()
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        // The system owns the transfer. Progress is intentionally not used to keep the app alive.
    }

    private func wakeDownloadStore() {
        Task { @MainActor in _ = DownloadStore.shared }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: indexURL),
              let values = try? JSONDecoder().decode([Int: Pending].self, from: data) else { return }
        pending = values
    }

    private func persistLocked() {
        let folder = indexURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(pending).write(to: indexURL, options: .atomic)
    }
}

enum HLSAssetError: LocalizedError {
    case cannotCreateTask
    var errorDescription: String? { "iOS could not create a background HLS download task." }
}
#endif
