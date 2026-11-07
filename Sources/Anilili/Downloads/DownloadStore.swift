#if canImport(UIKit)
import AVFoundation
import AnililiCore
import Foundation
import Observation
import UIKit

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

    private struct SaveResult {
        var bytes: Int64
        var duration: Double?
        var kind: DownloadRecord.Kind
        var subtitleFile: String?
    }

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
            // A completed copy may have come from a different server. Tapping that server's
            // download button is an explicit choice, so replace the old copy instead of silently
            // returning from the one-record-per-audio guard below.
            if let source, existing.isDone, existing.source != source {
                remove(existing.id)
            } else {
                switch existing.state {
                case .failed, .paused:
                    if let source { update(existing.id) { $0.preferredSource = source } }
                    retry(existing.id)
                default: break
                }
                return
            }
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
        let subtitle: [SubtitleTrack] = record.subtitleFile.flatMap { name in
            let subtitleURL = DownloadPaths.root.appendingPathComponent(record.folder).appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: subtitleURL.path)
                ? [SubtitleTrack(url: subtitleURL, label: "Downloaded subtitle", language: "ar")] : []
        } ?? []
        switch kind {
        case .mp4:
            return VideoSource(url: DownloadPaths.root.appendingPathComponent(path), provider: "Downloaded", server: record.source ?? "This device", kind: .mp4, subtitles: subtitle, softSub: !subtitle.isEmpty)
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
            return VideoSource(url: url, provider: "Downloaded", server: record.source ?? "This device", kind: .hls, subtitles: subtitle, softSub: !subtitle.isEmpty)
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
        if #available(iOS 16.1, *) {
            DownloadActivityManager.shared.start(id: id, mediaID: record.media.id,
                                                  title: record.episodeTitle ?? record.media.title.preferred,
                                                  episode: record.episode)
        }
        // This gives iOS a finite background execution window when the user locks the phone or
        // switches apps. It is intentionally paired with persisted queue state: if iOS expires
        // the window, the next launch resumes the queued/partial episode safely.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Download \(id)") {}
        defer {
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        let folder = DownloadPaths.root.appendingPathComponent(record.folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let found = try await SourceHub.shared.sources(for: record.media, episode: record.episode, audio: record.audio)
            let sources = DownloadQueue.attempts(found, preferring: record.preferredSource)
            guard !sources.isEmpty else { throw HTTPError("No downloadable video source was found.") }
            var lastError: Error?
            for source in sources {
                guard !Task.isCancelled else { return }
                do {
                    Log.info("downloads", "\(id): saving from \(source.label)")
                    let result: SaveResult
                    switch source.kind {
                    case .hls: result = try await saveHLS(source, to: folder, id: id)
                    case .mp4: result = try await saveMP4(source, to: folder, id: id)
                    case .embed: continue
                    }
                    // Paused as the last file landed: it stays paused, and resuming finds every file.
                    guard !Task.isCancelled else { return }
                    update(id) {
                        $0.state = .done
                        $0.kind = result.kind
                        $0.source = source.label
                        $0.bytes = result.bytes
                        $0.duration = result.duration
                        $0.subtitleFile = result.subtitleFile
                    }
                    save()
                    Log.info("downloads", "\(id): saved \(DownloadQueue.size(result.bytes)) from \(source.label)")
                    if #available(iOS 16.1, *) {
                        DownloadActivityManager.shared.finish(id: id, episode: record.episode, source: source.label)
                    }
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
            if #available(iOS 16.1, *) {
                DownloadActivityManager.shared.finish(id: id, episode: record.episode,
                                                      source: record.source ?? "", failed: true)
            }
        }
    }

    private var maxHeight: Int? { UserDefaults.standard.string(forKey: Self.qualityKey).flatMap(Int.init) }

    private func headers(_ source: VideoSource) -> [String: String] {
        var all = source.headers
        all["User-Agent"] = all["User-Agent"] ?? HTTP.safariUserAgent
        return all
    }

    private func saveHLS(_ source: VideoSource, to folder: URL, id: String) async throws -> SaveResult {
        let headers = headers(source)
        let top = try await HTTP.text(source.url, headers: headers)
        var playlistURL = source.url
        var media = top
        if let variant = HLSDownload.variant(in: top, base: source.url, maxHeight: maxHeight) {
            playlistURL = variant
            media = try await HTTP.text(variant, headers: headers)
        }
        let videoPlan = HLSDownload.plan(media, base: playlistURL)
        guard !videoPlan.files.isEmpty else { throw HTTPError("The playlist lists no segments.") }

        // Some providers put audio in a separate HLS rendition. Previously we saved only the
        // selected video playlist, leaving AVPlayer with a dangling AUDIO group and producing a
        // perfectly playable but silent offline file. Materialize the audio rendition beside the
        // video playlist and save a small local master playlist that joins both tracks.
        let audio = playlistURL == source.url ? externalAudio(in: top, base: source.url) : nil
        var audioPlan: HLSDownload.Plan?
        var indexPlaylist = videoPlan.playlist
        if let audio {
            let audioText = try await HTTP.text(audio.url, headers: headers)
            let planned = HLSDownload.plan(audioText, base: audio.url, prefix: "a")
            guard !planned.files.isEmpty else { throw HTTPError("The audio playlist lists no segments.") }
            audioPlan = planned
            let audioLine = audio.line.replacingOccurrences(of: "URI=\"\(audio.url.absoluteString)\"", with: "URI=\"audio.m3u8\"")
                .replacingOccurrences(of: "URI=\"\(audio.rawURI)\"", with: "URI=\"audio.m3u8\"")
            let streamInfo = selectedStreamInfo(in: top, variant: playlistURL, base: source.url) ?? "#EXT-X-STREAM-INF:BANDWIDTH=1"
            indexPlaylist = "#EXTM3U\n\(audioLine)\n\(streamInfo)\nvideo.m3u8\n"
        }
        let plans = [videoPlan] + (audioPlan.map { [$0] } ?? [])
        let plannedFiles = plans.flatMap(\.files)
        // Files left from an earlier attempt are kept only if they came from this server's same
        // playlist: another server's segments would be spliced into this one's under the same names.
        let stampURL = folder.appendingPathComponent(Self.stampFile)
        let expected = stamp(source: source.label, files: plannedFiles.count)
        if (try? String(contentsOf: stampURL, encoding: .utf8)) != expected {
            let leftovers = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            if !leftovers.isEmpty { Log.info("downloads", "\(id): starting afresh, \(leftovers.count) files were from another attempt") }
            for file in leftovers { try? FileManager.default.removeItem(at: file) }
            try Data(expected.utf8).write(to: stampURL, options: .atomic)
        }
        Log.info("downloads", "\(id): \(plannedFiles.count) files, \(Int(videoPlan.duration / 60)) min, from \(Log.short(playlistURL))")

        let total = plannedFiles.count
        var done = 0
        var bytes: Int64 = 0
        // Four files at a time.
        try await withThrowingTaskGroup(of: Int64.self) { group in
            var pending = plannedFiles.makeIterator()
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
        if audioPlan != nil {
            try Data(videoPlan.playlist.utf8).write(to: folder.appendingPathComponent("video.m3u8"), options: .atomic)
            try Data(audioPlan!.playlist.utf8).write(to: folder.appendingPathComponent("audio.m3u8"), options: .atomic)
        }
        try Data(indexPlaylist.utf8).write(to: folder.appendingPathComponent("index.m3u8"), options: .atomic)
        let subtitleFile = try? await saveSubtitle(source, to: folder)
        if let converted = try? await convertHLS(folder: folder, id: id), converted {
            return SaveResult(bytes: fileSize(folder.appendingPathComponent("episode.mp4")), duration: videoPlan.duration > 0 ? videoPlan.duration : nil, kind: .mp4, subtitleFile: subtitleFile)
        }
        return SaveResult(bytes: bytes + (subtitleFile.map { fileSize(folder.appendingPathComponent($0)) } ?? 0), duration: videoPlan.duration > 0 ? videoPlan.duration : nil, kind: .hls, subtitleFile: subtitleFile)
    }

    private struct ExternalAudio {
        var url: URL
        var rawURI: String
        var line: String
    }

    private func externalAudio(in master: String, base: URL) -> ExternalAudio? {
        for raw in master.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.hasPrefix("#EXT-X-MEDIA:"), line.range(of: "TYPE=AUDIO", options: .caseInsensitive) != nil,
                  let range = line.range(of: #"URI="([^"]+)""#, options: .regularExpression) else { continue }
            let value = String(line[range]).replacingOccurrences(of: "URI=\"", with: "").dropLast()
            guard let url = URL(string: String(value), relativeTo: base)?.absoluteURL else { continue }
            return ExternalAudio(url: url, rawURI: String(value), line: line)
        }
        return nil
    }

    private func selectedStreamInfo(in master: String, variant: URL, base: URL) -> String? {
        var pending: String?
        for raw in master.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") { pending = line }
            else if let info = pending, !line.isEmpty, !line.hasPrefix("#") {
                if URL(string: line, relativeTo: base)?.absoluteURL == variant { return info }
                pending = nil
            }
        }
        return pending
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

    private func saveMP4(_ source: VideoSource, to folder: URL, id: String) async throws -> SaveResult {
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
        let subtitleFile = try? await saveSubtitle(source, to: folder)
        return SaveResult(bytes: size + (subtitleFile.map { fileSize(folder.appendingPathComponent($0)) } ?? 0), duration: nil, kind: .mp4, subtitleFile: subtitleFile)
    }

    /// Selects Arabic first, then English, and saves one sidecar subtitle for a soft-sub source.
    private func saveSubtitle(_ source: VideoSource, to folder: URL) async throws -> String? {
        guard source.softSub, let track = source.subtitles.first(where: {
            $0.language.lowercased().hasPrefix("ar") || $0.label.localizedCaseInsensitiveContains("arab") || $0.label.contains("عرب")
        }) ?? source.subtitles.first(where: { $0.language.lowercased().hasPrefix("en") }) ?? source.subtitles.first else { return nil }
        let data = try await HTTP.data(track.url, headers: headers(source)).0
        guard !data.isEmpty else { return nil }
        let ext = track.url.pathExtension.lowercased()
        let name = "subtitle.\(ext == "vtt" || ext == "ass" || ext == "ssa" ? ext : "srt")"
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        return name
    }

    /// Converts the completed local HLS playlist to one MP4. HLS remains the fallback if the
    /// system exporter cannot handle a particular encrypted or fragmented playlist.
    private func convertHLS(folder: URL, id: String) async throws -> Bool {
        let playlist = try await LocalMediaServer.shared.url(for: "\(folder.lastPathComponent)/index.m3u8")
        let asset = AVURLAsset(url: playlist)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return false }
        let output = folder.appendingPathComponent("episode.mp4")
        try? FileManager.default.removeItem(at: output)
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed: continuation.resume()
                case .failed, .cancelled: continuation.resume(throwing: exporter.error ?? HTTPError("HLS to MP4 conversion failed"))
                default: continuation.resume(throwing: HTTPError("HLS export did not complete"))
                }
            }
        }
        let size = fileSize(output)
        guard size > 0 else { return false }
        let keep = Set(["episode.mp4", "subtitle.srt", "subtitle.vtt", "subtitle.ass", "subtitle.ssa"])
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        Log.info("downloads", "\(id): converted HLS to one MP4 (\(DownloadQueue.size(size)))")
        return true
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
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
        if #available(iOS 16.1, *) {
            let record = records.first(where: { $0.id == id })
            DownloadActivityManager.shared.update(id: id, episode: record?.episode ?? 0,
                                                  progress: fraction, status: .downloading,
                                                  source: record?.source ?? "")
        }
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
