#if canImport(UIKit)
import AnililiCore
import Foundation
import Observation

/// Where downloads live: Application Support/Downloads, one folder per episode, kept out of
/// iCloud backups (they can be fetched again).
enum DownloadPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    static var index: URL { root.appendingPathComponent("index.json") }
}

/// Saved episodes (Android's downloads): two at a time, HLS saved segment by segment with its
/// playlist rewritten to local files, MP4 as one file; failover across servers like the player.
@MainActor
@Observable
final class DownloadStore {
    static let shared = DownloadStore()

    /// Android's `download_quality`: "best", "1080", "720", "480", "360".
    static let qualityKey = "download_quality"

    private(set) var records: [DownloadRecord] = []
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastProgress: [String: Double] = [:]
    /// Saved HLS copies whose segments were checked this session (`offlineSource`).
    @ObservationIgnored private var checked: Set<String> = []

    private init() {
        if let data = try? Data(contentsOf: DownloadPaths.index),
           let saved = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            // Whatever was mid-way when the app last stopped starts again (finished files are kept).
            records = saved.map { record in
                var record = record
                if case .downloading = record.state { record.state = .queued }
                return record
            }
        }
        Log.info("downloads", "\(records.filter(\.isDone).count) saved, \(records.filter(\.state.isActive).count) to resume")
        pump()
    }

    var series: [DownloadQueue.Series] { DownloadQueue.series(records) }
    var totalBytes: Int64 { records.reduce(0) { $0 + $1.bytes } }

    func record(mediaID: Int, episode: Int, audio: AudioTrack) -> DownloadRecord? {
        records.first { $0.id == DownloadRecord.id(mediaID: mediaID, episode: episode, audio: audio) }
    }

    /// Any saved audio for the episode, the asked-for one first.
    func saved(mediaID: Int, episode: Int, prefer audio: AudioTrack) -> DownloadRecord? {
        let done = records.filter { $0.media.id == mediaID && $0.episode == episode && $0.isDone }
        return done.first { $0.audio == audio } ?? done.first
    }

    // MARK: - Queueing

    /// `source` is a server the viewer picked (its `VideoSource.label`); without one the queue
    /// tries every server in the order the player would.
    func enqueue(_ media: Media, episode: Int, audio: AudioTrack, title: String? = nil, thumbnail: URL? = nil, from source: String? = nil) {
        if let existing = record(mediaID: media.id, episode: episode, audio: audio) {
            switch existing.state {
            case .failed, .paused:
                if let source { update(existing.id) { $0.preferredSource = source } }
                retry(existing.id)
            default: break
            }
            return
        }
        var record = DownloadRecord(media: media, episode: episode, audio: audio, episodeTitle: title, thumbnail: thumbnail)
        record.preferredSource = source
        records.append(record)
        Log.info("downloads", "queued \(media.id) ep \(episode) \(audio.rawValue)" + (source.map { " from \($0)" } ?? ""))
        save()
        pump()
    }

    /// Also how a paused episode resumes: HLS picks up from the segments already saved.
    func retry(_ id: String) {
        update(id) { $0.state = .queued }
        save()
        pump()
    }

    /// Stops a queued or saving episode but keeps what it has fetched (`retry` resumes it). The
    /// task stays in `running` until it has unwound, so a quick resume can't start a second
    /// writer in the same folder; its exit pumps the queue. An MP4 starts over on resume.
    func pause(_ id: String) {
        guard let state = records.first(where: { $0.id == id })?.state, state.isActive else { return }
        running[id]?.cancel()
        update(id) { $0.state = .paused }
        lastProgress[id] = nil
        Log.info("downloads", "paused \(id)")
        save()
        pump()
    }

    func remove(_ id: String) {
        running[id]?.cancel()
        running[id] = nil
        records.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: DownloadPaths.root.appendingPathComponent(id, isDirectory: true))
        Log.info("downloads", "removed \(id)")
        save()
        pump()
    }

    func removeAll(mediaID: Int? = nil) {
        for record in records where mediaID == nil || record.media.id == mediaID { remove(record.id) }
    }

    /// What the player plays for a saved episode: the local server's playlist, or the MP4 file.
    func offlineSource(for record: DownloadRecord) async -> VideoSource? {
        guard record.isDone, let entry = record.entryFile, let kind = record.kind else { return nil }
        let path = "\(record.folder)/\(entry)"
        guard FileManager.default.fileExists(atPath: DownloadPaths.root.appendingPathComponent(path).path) else {
            Log.warning("downloads", "\(record.id) is marked saved but its files are gone")
            update(record.id) { $0.state = .failed("The saved files are missing.") }
            save()
            return nil
        }
        switch kind {
        case .mp4:
            return VideoSource(url: DownloadPaths.root.appendingPathComponent(path), provider: "Downloaded", server: record.source ?? "This device", kind: .mp4)
        case .hls:
            if !checked.contains(record.id) {
                let folder = DownloadPaths.root.appendingPathComponent(record.folder, isDirectory: true)
                let damaged = await Task.detached { HLSDownload.damagedSegments(in: folder) }.value
                guard damaged.isEmpty else {
                    repair(record, damaged: damaged, in: folder)
                    return nil
                }
                checked.insert(record.id)
            }
            guard let url = try? await LocalMediaServer.shared.url(for: path) else { return nil }
            return VideoSource(url: url, provider: "Downloaded", server: record.source ?? "This device", kind: .hls)
        }
    }

    /// A saved copy with segments that won't play goes back in the queue, and only those are
    /// fetched again if the same server still has the episode; the player streams it meanwhile.
    private func repair(_ record: DownloadRecord, damaged: [String], in folder: URL) {
        Log.warning("downloads", "\(record.id): \(damaged.count) saved segment\(damaged.count == 1 ? "" : "s") won't play (\(damaged.prefix(3).joined(separator: ", "))); fetching again")
        for name in damaged { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        // Copies saved before the stamp existed get one, so the files that are fine are kept.
        let index = folder.appendingPathComponent("index.m3u8")
        if let source = record.source, !FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.stampFile).path),
           let playlist = try? String(contentsOf: index, encoding: .utf8) {
            let files = HLSDownload.plan(playlist, base: index).files.count
            try? Data(stamp(source: source, files: files).utf8).write(to: folder.appendingPathComponent(Self.stampFile))
        }
        retry(record.id)
    }

    // MARK: - Working

    private func pump() {
        for record in DownloadQueue.next(records, running: Set(running.keys)) {
            let id = record.id
            update(id) { $0.state = .downloading(0) }
            running[id] = Task { [weak self] in
                await self?.run(record)
                self?.running[id] = nil
                self?.pump()
            }
        }
    }

    private func run(_ record: DownloadRecord) async {
        let id = record.id
        let folder = DownloadPaths.root.appendingPathComponent(record.folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let found = try await SourceHub.shared.sources(for: record.media, episode: record.episode, audio: record.audio)
            let sources = DownloadQueue.attempts(found, preferring: record.preferredSource)
            guard !sources.isEmpty else { throw HTTPError("No server has a hard-subbed copy to save.") }
            var lastError: Error?
            for source in sources {
                guard !Task.isCancelled else { return }
                do {
                    Log.info("downloads", "\(id): saving from \(source.label)")
                    let result: (bytes: Int64, duration: Double?)
                    switch source.kind {
                    case .hls: result = try await saveHLS(source, to: folder, id: id)
                    case .mp4: result = try await saveMP4(source, to: folder, id: id)
                    case .embed: continue
                    }
                    // Paused as the last file landed: it stays paused, and resuming finds every file.
                    guard !Task.isCancelled else { return }
                    update(id) {
                        $0.state = .done
                        $0.kind = source.kind == .hls ? .hls : .mp4
                        $0.source = source.label
                        $0.bytes = result.bytes
                        $0.duration = result.duration
                    }
                    save()
                    Log.info("downloads", "\(id): saved \(DownloadQueue.size(result.bytes)) from \(source.label)")
                    return
                } catch {
                    if Task.isCancelled { return }
                    lastError = error
                    Log.warning("downloads", "\(id): \(source.label) failed: \(Log.describe(error))")
                }
            }
            throw lastError ?? HTTPError("Every server failed.")
        } catch {
            guard !Task.isCancelled, records.contains(where: { $0.id == id }) else { return }
            Log.error("downloads", "\(id) failed: \(Log.describe(error))")
            update(id) { $0.state = .failed(error.localizedDescription) }
            save()
        }
    }

    private var maxHeight: Int? { UserDefaults.standard.string(forKey: Self.qualityKey).flatMap(Int.init) }

    private func headers(_ source: VideoSource) -> [String: String] {
        var all = source.headers
        all["User-Agent"] = all["User-Agent"] ?? HTTP.safariUserAgent
        return all
    }

    private func saveHLS(_ source: VideoSource, to folder: URL, id: String) async throws -> (bytes: Int64, duration: Double?) {
        let headers = headers(source)
        let top = try await HTTP.text(source.url, headers: headers)
        var playlistURL = source.url
        var media = top
        if let variant = HLSDownload.variant(in: top, base: source.url, maxHeight: maxHeight) {
            playlistURL = variant
            media = try await HTTP.text(variant, headers: headers)
        }
        let plan = HLSDownload.plan(media, base: playlistURL)
        guard !plan.files.isEmpty else { throw HTTPError("The playlist lists no segments.") }
        // Files left from an earlier attempt are kept only if they came from this server's same
        // playlist: another server's segments would be spliced into this one's under the same names.
        let stampURL = folder.appendingPathComponent(Self.stampFile)
        let expected = stamp(source: source.label, files: plan.files.count)
        if (try? String(contentsOf: stampURL, encoding: .utf8)) != expected {
            let leftovers = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            if !leftovers.isEmpty { Log.info("downloads", "\(id): starting afresh, \(leftovers.count) files were from another attempt") }
            for file in leftovers { try? FileManager.default.removeItem(at: file) }
            try Data(expected.utf8).write(to: stampURL, options: .atomic)
        }
        Log.info("downloads", "\(id): \(plan.files.count) files, \(Int(plan.duration / 60)) min, from \(Log.short(playlistURL))")

        let total = plan.files.count
        var done = 0
        var bytes: Int64 = 0
        // Four files at a time.
        try await withThrowingTaskGroup(of: Int64.self) { group in
            var pending = plan.files.makeIterator()
            for _ in 0..<4 {
                guard let file = pending.next() else { break }
                group.addTask { try await Self.fetch(file, into: folder, headers: headers) }
            }
            while let size = try await group.next() {
                try Task.checkCancellation()
                done += 1
                bytes += size
                await self.progress(id, Double(done) / Double(total))
                if let file = pending.next() {
                    group.addTask { try await Self.fetch(file, into: folder, headers: headers) }
                }
            }
        }
        try Data(plan.playlist.utf8).write(to: folder.appendingPathComponent("index.m3u8"), options: .atomic)
        return (bytes, plan.duration > 0 ? plan.duration : nil)
    }

    /// Which server and playlist a folder's files came from (`saveHLS`).
    private static let stampFile = "source.txt"

    private func stamp(source: String, files: Int) -> String {
        "\(source)\n\(files)\n\(maxHeight.map(String.init) ?? "best")"
    }

    /// One file of an HLS episode, a segment without its disguise; kept if it's already there from
    /// an earlier attempt. A segment that isn't media (an error page or a placeholder answered
    /// with 200) is asked for again, and fails this server if it never comes right.
    nonisolated private static func fetch(_ planned: HLSDownload.File, into folder: URL, headers: [String: String]) async throws -> Int64 {
        let url = planned.remote
        let file = folder.appendingPathComponent(planned.local)
        if let existing = try? Data(contentsOf: file, options: .mappedIfSafe), !existing.isEmpty,
           !planned.isSegment || HLSDownload.isMedia([UInt8](existing.prefix(HLSDownload.mediaCheckLength)), size: existing.count, encrypted: planned.encrypted) {
            return Int64(existing.count)
        }
        var attempt = 0
        while true {
            do {
                let (data, response) = try await HTTP.data(url, headers: headers)
                guard (200..<300).contains(response.statusCode), !data.isEmpty else {
                    throw HTTPError(status: response.statusCode, "HTTP \(response.statusCode) for \(url.lastPathComponent)")
                }
                let saved = planned.isSegment ? HLSDownload.unwrap(data) : data
                if planned.isSegment, !HLSDownload.isMedia([UInt8](saved.prefix(HLSDownload.mediaCheckLength)), size: saved.count, encrypted: planned.encrypted) {
                    let type = response.value(forHTTPHeaderField: "Content-Type") ?? "no type"
                    throw HTTPError("\(planned.local) came back as \(saved.count) bytes of \(type), not video")
                }
                try saved.write(to: file, options: .atomic)
                return Int64(saved.count)
            } catch {
                attempt += 1
                if attempt >= 3 || Task.isCancelled { throw error }
                try await Task.sleep(for: .seconds(2 * attempt))
            }
        }
    }

    private func saveMP4(_ source: VideoSource, to folder: URL, id: String) async throws -> (bytes: Int64, duration: Double?) {
        var request = URLRequest(url: source.url)
        for (name, value) in headers(source) { request.setValue(value, forHTTPHeaderField: name) }
        let reporter = DownloadProgress { [weak self] fraction in
            Task { @MainActor in self?.progress(id, fraction) }
        }
        let (temporary, response) = try await Self.session.download(for: request, delegate: reporter)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HTTPError(status: (response as? HTTPURLResponse)?.statusCode, "The server refused the file.")
        }
        let target = folder.appendingPathComponent("episode.mp4")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int64 ?? 0
        return (size, nil)
    }

    /// Long transfers: a whole episode can take minutes.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 3600
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    // MARK: - State

    private func progress(_ id: String, _ fraction: Double) {
        // A redraw per percent is plenty.
        guard fraction - (lastProgress[id] ?? -1) >= 0.01 || fraction >= 1 else { return }
        // A report still on its way after a pause must not mark the episode saving again.
        guard case .downloading? = records.first(where: { $0.id == id })?.state else { return }
        lastProgress[id] = fraction
        update(id) { $0.state = .downloading(fraction) }
    }

    private func update(_ id: String, _ change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
    }

    private func save() {
        do {
            try JSONEncoder().encode(records).write(to: DownloadPaths.index, options: .atomic)
        } catch {
            Log.error("downloads", "couldn't save the index: \(Log.describe(error))")
        }
    }
}

/// Reports a download task's progress (the async `download(for:)` has no progress of its own).
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(_ report: @escaping (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            report(progress.fractionCompleted)
        }
    }
}
#endif
