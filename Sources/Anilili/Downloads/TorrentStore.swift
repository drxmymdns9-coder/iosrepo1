#if canImport(UIKit)
import AnililiCore
import Foundation
import Observation
import SwiftTorrent

/// User-provided torrents only: downloads into the app sandbox and exposes completed video files
/// to the existing AVPlayer-based watch screen. No index or third-party torrent site is queried.
@MainActor
@Observable
final class TorrentStore {
    static let shared = TorrentStore()

    struct Job: Identifiable, Hashable {
        let id: UUID
        var name: String
        var source: String
        var state: State
        var videoURL: URL?
        var progress: Double = 0
        var downloadRate: Double = 0
        var peers: Int = 0
        var downloaded: Int64 = 0
        var total: Int64 = 0

        enum State: Hashable {
            case waiting
            case downloading
            case finished
            case failed(String)
        }
    }

    private(set) var jobs: [Job] = []
    @ObservationIgnored private var session: Session?

    private var root: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Torrents", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private init() {}

    func addMagnet(_ magnet: String) {
        let value = magnet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("magnet:") else { return }
        start(value, magnet: value)
    }

    func addTorrentFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let destination = root.appendingPathComponent(url.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            start(destination.lastPathComponent, torrent: destination)
        } catch {
            jobs.append(Job(id: UUID(), name: url.lastPathComponent, source: "File", state: .failed(error.localizedDescription), videoURL: nil))
        }
    }

    private func start(_ label: String, magnet: String? = nil, torrent: URL? = nil) {
        let id = UUID()
        jobs.append(Job(id: id, name: label, source: magnet == nil ? "Torrent file" : "Magnet link", state: .waiting, videoURL: nil))
        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.makeSession()
                self.update(id) { $0.state = .downloading }
                let params: AddTorrentParams
                if let magnet {
                    params = try AddTorrentParams.fromMagnet(magnet, savePath: self.root.path)
                } else if let torrent {
                    params = try AddTorrentParams.fromFile(torrent.path, savePath: self.root.path)
                } else {
                    throw NSError(domain: "AnililiTorrent", code: 1, userInfo: [NSLocalizedDescriptionKey: "No torrent source was supplied."])
                }
                let handle = try await session.addTorrent(params)
                try await handle.start()
                let info = try await handle.waitForMetadata(timeout: 120)
                let monitor = Task { [weak self] in
                    while !Task.isCancelled {
                        let status = await handle.status()
                        self?.update(id) { job in
                            job.progress = status.progress
                            job.downloadRate = status.downloadRate
                            job.peers = status.numPeers
                            job.downloaded = status.totalDownloaded
                            job.total = status.totalSize
                        }
                        if status.progress >= 1 { break }
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                try await handle.waitForCompletion(timeout: 24 * 60 * 60)
                monitor.cancel()
                let video = info.files
                    .filter { Self.videoExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
                    .max { $0.length < $1.length }
                guard let video else { throw NSError(domain: "AnililiTorrent", code: 2, userInfo: [NSLocalizedDescriptionKey: "The torrent has no supported video file."]) }
                let url = self.root.appendingPathComponent(video.path)
                guard FileManager.default.fileExists(atPath: url.path) else { throw NSError(domain: "AnililiTorrent", code: 3, userInfo: [NSLocalizedDescriptionKey: "The downloaded video file was not found."]) }
                self.update(id) { job in
                    job.state = .finished
                    job.name = info.name
                    job.videoURL = url
                }
            } catch {
                self.update(id) { $0.state = .failed(error.localizedDescription) }
            }
        }
    }

    private func makeSession() async throws -> Session {
        if let session { return session }
        let created = Session(settings: SessionSettings(listenPort: 0, dhtEnabled: true, savePath: root.path))
        session = created
        try await created.startDHT()
        return created
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "ts", "mkv", "webm", "avi"]
}
#endif
