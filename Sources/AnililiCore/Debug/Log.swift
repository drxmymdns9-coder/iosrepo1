import Foundation
#if canImport(os)
import os
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The app's debug log: every line goes to Apple's unified log (subsystem `com.anilili.ios`, so
/// `log show --predicate 'subsystem == "com.anilili.ios"'` and Console.app see it beside
/// AVFoundation's own lines), to stdout (`xcrun simctl launch --console-pty booted
/// com.anilili.ios`), and into an in-memory ring the app shows under Settings → App → Debug log,
/// where it can be copied and pasted.
///
/// Once the app calls `keep(in:)`, every line is also appended to a file, because a crash takes
/// the ring with it: the next launch reads that file back as `previousRun`, so a diagnostics
/// report sent after a crash still shows what led up to it (and the crash lines the app writes
/// into the same file as it dies).
///
/// Lines are short and greppable: `12:04:31.207 W miruro  mirror www.miruro.to failed: …`.
/// Stream URLs are logged in full on purpose; this log only leaves the device when it's copied.
public enum Log {
    public enum Level: String, Sendable, Comparable {
        case debug = "D", info = "I", warning = "W", error = "E"

        private var rank: Int { ["D": 0, "I": 1, "W": 2, "E": 3][rawValue] ?? 0 }
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
    }

    public struct Entry: Sendable, Identifiable {
        public let id: Int
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String

        public var line: String {
            "\(Log.timeFormatter.string(from: date)) \(level.rawValue) \(category.padding(toLength: 7, withPad: " ", startingAt: 0)) \(message)"
        }
    }

    public static func debug(_ category: String, _ message: @autoclosure () -> String) { write(.debug, category, message()) }
    public static func info(_ category: String, _ message: @autoclosure () -> String) { write(.info, category, message()) }
    public static func warning(_ category: String, _ message: @autoclosure () -> String) { write(.warning, category, message()) }
    public static func error(_ category: String, _ message: @autoclosure () -> String) { write(.error, category, message()) }

    /// The retained lines, oldest first.
    public static var entries: [Entry] { store.snapshot() }

    public static func clear() { store.clear() }

    /// Everything retained, as one paste-able block with `header` (device, app version) on top,
    /// after the previous launch's log when there is one.
    public static func export(header: String = "") -> String {
        var body = entries.map(\.line).joined(separator: "\n")
        if let previous = previousRun {
            body = "Previous run (the last time the app was open, up to the moment it stopped):\n"
                + previous + "\n\nThis run:\n" + body
        }
        return header.isEmpty ? body : header + "\n\n" + body
    }

    // MARK: - Kept on disk

    /// The file the log is appended to, for the crash handlers, which can only write to a
    /// descriptor as the app dies; -1 until `keep(in:)` has run.
    public nonisolated(unsafe) private(set) static var descriptor: Int32 = -1

    /// The tail of the previous launch's log, read back by `keep(in:)`; nil on a first launch.
    public static var previousRun: String? { store.previousRun }

    /// The previous launch's last lines kept for the report.
    static let previousRunLines = 2000
    /// Past this the file starts over, so a long session can't fill the disk; the lines just
    /// before a crash are what matter.
    static let fileLimit = 4 << 20

    /// Starts appending to `log.txt` in `directory`, after reading the previous launch's copy of
    /// it back as `previousRun`. Lines logged before this call are written first.
    public static func keep(in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("log.txt")
        let previous = (try? Data(contentsOf: file)).flatMap { tail(String(decoding: $0, as: UTF8.self), lines: previousRunLines) }
        let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o600)
        if fd >= 0 { descriptor = fd }
        store.keep(fd: fd, previousRun: previous)
    }

    /// The last `lines` non-empty lines of `text`, or nil when there are none.
    static func tail(_ text: String, lines: Int) -> String? {
        let all = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !all.isEmpty else { return nil }
        return all.suffix(lines).joined(separator: "\n")
    }

    /// `text` with sign-in secrets taken out, for a diagnostics report that leaves the device:
    /// tokens and codes in URLs, bearer headers and JSON token fields.
    public static func redact(_ text: String) -> String {
        let patterns = [
            #"\b((?:access_token|refresh_token|id_token|token|code|code_verifier|client_secret|password)=)[^&#\s"']+"#,
            #"((?:Bearer|bearer)\s+)[A-Za-z0-9._~+/=-]+"#,
            #"("(?:access_token|refresh_token|id_token|token|password)"\s*:\s*")[^"]*"#,
        ]
        var result = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1[redacted]")
        }
        return result
    }

    /// A one-line description of an error that keeps what `localizedDescription` drops: the
    /// domain, the code and the underlying error, which is where AVFoundation and URLSession put
    /// the actual cause.
    public static func describe(_ error: Error) -> String {
        if let error = error as? HTTPError { return error.message + (error.status.map { " [HTTP \($0)]" } ?? "") }
        let ns = error as NSError
        var text = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        if let reason = ns.localizedFailureReason { text += " reason: \(reason)" }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            text += " ← " + describe(underlying)
        }
        return text
    }

    /// Long URLs cut to something a log line can carry.
    public static func short(_ url: URL?, limit: Int = 140) -> String {
        guard let text = url?.absoluteString else { return "nil" }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    // MARK: - Storage

    static let capacity = 3000
    private static let store = Store()

    // DateFormatter is thread-safe for formatting; it just isn't marked Sendable.
    fileprivate nonisolated(unsafe) static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func write(_ level: Level, _ category: String, _ message: String) {
        let entry = store.append(level, category, message)
        print("[Anilili] \(entry.line)")
        #if canImport(os)
        // Public: this is the app's own diagnostic text, and redacted lines are useless in a bug
        // report. Stream URLs are in it on purpose (see the type comment).
        let logger = Logger(subsystem: "com.anilili.ios", category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        #endif
    }

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var ring: [Entry] = []
        private var nextID = 0
        private var fd: Int32 = -1
        private var written = 0
        private var previous: String?

        func append(_ level: Level, _ category: String, _ message: String) -> Entry {
            lock.lock()
            defer { lock.unlock() }
            let entry = Entry(id: nextID, date: Date(), level: level, category: category, message: message)
            nextID += 1
            ring.append(entry)
            if ring.count > Log.capacity { ring.removeFirst(ring.count - Log.capacity) }
            persist(entry)
            return entry
        }

        func keep(fd: Int32, previousRun: String?) {
            lock.lock()
            defer { lock.unlock() }
            if self.fd >= 0, self.fd != fd { close(self.fd) }
            self.fd = fd
            written = 0
            previous = previousRun
            ring.forEach(persist)
        }

        var previousRun: String? {
            lock.lock()
            defer { lock.unlock() }
            return previous
        }

        /// Appends the line to the file; the caller holds the lock.
        private func persist(_ entry: Entry) {
            guard fd >= 0 else { return }
            if written > Log.fileLimit {
                _ = ftruncate(fd, 0)
                written = 0
            }
            var bytes = Array((entry.line + "\n").utf8)
            written += bytes.count
            bytes.withUnsafeMutableBytes { writeToFile(fd, UnsafeRawBufferPointer($0)) }
        }

        func snapshot() -> [Entry] {
            lock.lock()
            defer { lock.unlock() }
            return ring
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            ring.removeAll()
        }
    }
}

/// `write(2)`, out here because `Log.write` hides it inside the type.
private func writeToFile(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) {
    _ = write(fd, bytes.baseAddress, bytes.count)
}
