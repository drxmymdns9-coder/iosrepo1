#if canImport(UIKit)
import Foundation

/// URLSession background transfer helper. Completed files are moved directly into the episode
/// folder, so DownloadStore can resume/finalize them after iOS relaunches the app.
final class BackgroundDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloadSession()
    static let identifier = "com.anilili.ios.downloads.transfer"

    private struct Pending: Codable {
        var taskID: Int
        var destination: String
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var waiters: [String: [(Result<Int64, Error>) -> Void]] = [:]
    private var backgroundCompletion: (() -> Void)?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private var indexURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("background-tasks.json")
    }

    private override init() {
        super.init()
        restore()
        _ = session
    }

    func download(_ request: URLRequest, to destination: URL) async throws -> Int64 {
        if let existing = try? Data(contentsOf: destination), !existing.isEmpty {
            return Int64(existing.count)
        }
        let key = destination.path
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiters[key, default: []].append { result in continuation.resume(with: result) }
            if pending.values.contains(where: { $0.destination == key }) {
                lock.unlock()
                return
            }
            let task = session.downloadTask(with: request)
            pending[task.taskIdentifier] = Pending(taskID: task.taskIdentifier, destination: key)
            persistLocked()
            task.resume()
            lock.unlock()
        }
    }

    func handleEvents(for identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.identifier else { completionHandler(); return }
        // Instantiating the singleton reconnects the delegate to the system-owned session.
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

    func cancel(destination: URL) {
        lock.lock()
        let matches = pending.values.filter { $0.destination == destination.path }
        for item in matches { session.getAllTasks { tasks in tasks.first(where: { $0.taskIdentifier == item.taskID })?.cancel() } }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock()
        guard let item = pending[downloadTask.taskIdentifier] else { lock.unlock(); return }
        let destination = URL(fileURLWithPath: item.destination)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64 ?? 0
            pending.removeValue(forKey: downloadTask.taskIdentifier)
            let callbacks = waiters.removeValue(forKey: item.destination) ?? []
            persistLocked()
            lock.unlock()
            callbacks.forEach { $0(.success(size)) }
            wakeDownloadStore()
        } catch {
            pending.removeValue(forKey: downloadTask.taskIdentifier)
            let callbacks = waiters.removeValue(forKey: item.destination) ?? []
            persistLocked()
            lock.unlock()
            callbacks.forEach { $0(.failure(error)) }
            wakeDownloadStore()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        guard let item = pending.removeValue(forKey: task.taskIdentifier) else { lock.unlock(); return }
        let callbacks = waiters.removeValue(forKey: item.destination) ?? []
        persistLocked()
        lock.unlock()
        callbacks.forEach { $0(.failure(error)) }
        wakeDownloadStore()
    }

    /// URLSession can relaunch the app only to deliver a transfer event. Recreate the queue so
    /// it notices completed TS files and performs playlist writing/MP4 conversion.
    private func wakeDownloadStore() {
        Task { @MainActor in
            _ = DownloadStore.shared
        }
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
#endif
