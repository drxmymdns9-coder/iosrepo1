import Foundation

/// The crashed thread of a MetricKit crash diagnostic (`MXCallStackTree.jsonRepresentation()`),
/// as lines a log can carry: one `binary +0xoffset` per frame, innermost first, then the build
/// UUID of each binary so the offsets can be symbolicated against that build.
public enum CrashStack {
    public static let frameLimit = 40

    public static func lines(fromJSON data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]], !stacks.isEmpty else { return [] }
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks[0]
        // Each root frame is the innermost frame of a chain whose callers follow in `subFrames`.
        var frames: [[String: Any]] = []
        var pending = (stack["callStackRootFrames"] as? [[String: Any]]) ?? []
        while let frame = pending.first, frames.count < frameLimit {
            frames.append(frame)
            pending = (frame["subFrames"] as? [[String: Any]]) ?? Array(pending.dropFirst())
        }
        var binaries: [(name: String, uuid: String)] = []
        var lines = frames.map { frame -> String in
            let name = frame["binaryName"] as? String ?? "?"
            let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
            if let uuid = frame["binaryUUID"] as? String, !binaries.contains(where: { $0.name == name }) {
                binaries.append((name, uuid))
            }
            return "\(name) +0x\(String(offset, radix: 16))"
        }
        if !binaries.isEmpty {
            lines.append("binaries: " + binaries.map { "\($0.name) \($0.uuid)" }.joined(separator: ", "))
        }
        return lines
    }
}
