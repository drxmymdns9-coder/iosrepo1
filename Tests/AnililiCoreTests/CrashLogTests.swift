import Foundation
import Testing
@testable import AnililiCore

struct CrashLogTests {
    @Test func crashStackFollowsTheAttributedThreadInnermostFirst() {
        let json = """
        {"callStackPerThread": true, "callStacks": [
          {"threadAttributed": false, "callStackRootFrames": [
            {"binaryName": "libsystem_kernel.dylib", "binaryUUID": "K", "offsetIntoBinaryTextSegment": 1, "address": 1}]},
          {"threadAttributed": true, "callStackRootFrames": [
            {"binaryName": "libswiftCore.dylib", "binaryUUID": "S", "offsetIntoBinaryTextSegment": 4096, "address": 2,
             "subFrames": [
              {"binaryName": "Anilili", "binaryUUID": "A", "offsetIntoBinaryTextSegment": 703710, "address": 3,
               "subFrames": [
                {"binaryName": "Anilili", "binaryUUID": "A", "offsetIntoBinaryTextSegment": 255, "address": 4}]}]}]}
        ]}
        """
        let lines = CrashStack.lines(fromJSON: Data(json.utf8))
        #expect(lines == [
            "libswiftCore.dylib +0x1000",
            "Anilili +0xabcde",
            "Anilili +0xff",
            "binaries: libswiftCore.dylib S, Anilili A",
        ])
    }

    @Test func crashStackOfNonsenseIsEmpty() {
        #expect(CrashStack.lines(fromJSON: Data("{}".utf8)).isEmpty)
        #expect(CrashStack.lines(fromJSON: Data("not json".utf8)).isEmpty)
    }

    @Test func tailKeepsTheLastLines() {
        #expect(Log.tail("a\nb\n\nc\n", lines: 2) == "b\nc")
        #expect(Log.tail("\n\n", lines: 5) == nil)
    }

    /// A relaunch reads the last launch's file back, including what a crash handler wrote
    /// straight to the descriptor, and the report carries it.
    @Test func theLogSurvivesARelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anilili-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        Log.keep(in: directory)
        #expect(Log.descriptor >= 0)
        Log.info("player", "open 21 ep 1100 sub")
        let crash = Array("E crash   fatal signal SIGSEGV\n".utf8)
        _ = crash.withUnsafeBytes { write(Log.descriptor, $0.baseAddress, $0.count) }

        Log.keep(in: directory)
        let previous = try #require(Log.previousRun)
        #expect(previous.contains("open 21 ep 1100 sub"))
        #expect(previous.hasSuffix("E crash   fatal signal SIGSEGV"))
        #expect(Log.export().hasPrefix("Previous run"))
    }
}
