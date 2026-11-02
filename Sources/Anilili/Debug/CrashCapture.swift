#if canImport(UIKit)
import AnililiCore
import Darwin
import Foundation
import MetricKit

/// Makes a crash show up in the next diagnostics report. The log is kept on disk (`Log.keep`), and
/// as the app dies three things are written into that same file, which the next launch reads back
/// as the previous run:
///
/// - an uncaught Objective-C exception: its name, reason and stack (AVFoundation and UIKit throw
///   these, e.g. for a KVO or player-item misuse);
/// - Swift's own "Fatal error: …" line with its file and line, by sending stderr to the file;
/// - for a fatal signal (a Swift trap, a bad access), the signal and a raw backtrace.
///
/// MetricKit then hands over Apple's own record of the crash on the next launch, which also
/// covers what none of the above sees; `CrashDiagnostics` logs it.
enum CrashCapture {
    static func install() {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        Log.keep(in: directory)
        guard Log.descriptor >= 0 else {
            Log.warning("crash", "log file unavailable; a crash won't be in the next report")
            return
        }
        // Swift's runtime writes the reason for a trap to stderr just before it dies.
        dup2(Log.descriptor, STDERR_FILENO)
        NSSetUncaughtExceptionHandler { exception in
            Log.error("crash", "uncaught \(exception.name.rawValue): \(exception.reason ?? "no reason")\n"
                + exception.callStackSymbols.joined(separator: "\n"))
        }
        for signal in fatalSignals { Darwin.signal(signal, onFatalSignal) }
        CrashDiagnostics.shared.start()
        if Log.previousRun != nil { Log.info("crash", "previous run's log kept for the diagnostics report") }
    }

    static let fatalSignals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]
}

/// Runs as the app dies, so it only writes to the open descriptor: no allocation, no locks.
private func onFatalSignal(_ signal: Int32) {
    let fd = Log.descriptor
    let name: StaticString = switch signal {
    case SIGABRT: "\nE crash   fatal signal SIGABRT (abort)\n"
    case SIGBUS: "\nE crash   fatal signal SIGBUS (bad memory access)\n"
    case SIGFPE: "\nE crash   fatal signal SIGFPE (arithmetic)\n"
    case SIGILL: "\nE crash   fatal signal SIGILL (illegal instruction)\n"
    case SIGSEGV: "\nE crash   fatal signal SIGSEGV (bad memory access)\n"
    case SIGTRAP: "\nE crash   fatal signal SIGTRAP (Swift runtime trap)\n"
    default: "\nE crash   fatal signal\n"
    }
    _ = write(fd, name.utf8Start, name.utf8CodeUnitCount)
    withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 64) { frames in
        let count = backtrace(frames.baseAddress, 64)
        backtrace_symbols_fd(frames.baseAddress, count, fd)
    }
    // Let the system's crash report happen as it would have.
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

/// MetricKit's crash diagnostics, logged when they arrive (on the launch after the crash).
final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashDiagnostics()

    /// A crash's report arrives through `didReceive` on a launch after it, once subscribed.
    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                log(crash, ended: payload.timeStampEnd)
            }
        }
    }

    private func log(_ crash: MXCrashDiagnostic, ended: Date) {
        let meta = crash.metaData
        var parts = ["app \(meta.applicationBuildVersion)", "OS \(meta.osVersion)"]
        if let type = crash.exceptionType { parts.append("exception type \(type)") }
        if let code = crash.exceptionCode { parts.append("code \(code)") }
        if let signal = crash.signal { parts.append("signal \(signal)") }
        if let reason = crash.terminationReason { parts.append("termination: \(reason)") }
        if let message = crash.exceptionReason?.composedMessage { parts.append("reason: \(message)") }
        let stack = CrashStack.lines(fromJSON: crash.callStackTree.jsonRepresentation())
        Log.error("crash", "Apple's crash report (by \(ended.formatted(date: .abbreviated, time: .shortened))): "
            + parts.joined(separator: ", ")
            + (stack.isEmpty ? "" : "\n" + stack.joined(separator: "\n")))
    }
}
#endif
