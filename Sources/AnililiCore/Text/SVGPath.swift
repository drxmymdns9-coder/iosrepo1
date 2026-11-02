import Foundation

/// SVG path data (`d`, or an Android vector's `pathData`) read into absolute segments, so a logo
/// ported from Android's drawables can be drawn as a shape without an image renderer.
///
/// Covers what those logos use: M L H V C S Q T Z, upper and lower case, implicit repeats, and
/// numbers run together the way minifiers write them (`.31.317`, `-5.887-16.602`). Arcs (A) are
/// not supported; a path containing one stops there.
public enum SVGPath {
    public enum Segment: Equatable, Sendable {
        case move(Point)
        case line(Point)
        case cubic(Point, Point, Point)
        case quad(Point, Point)
        case close
    }

    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    public static func parse(_ data: String) -> [Segment] {
        var scanner = Tokens(Array(data.utf8))
        var segments: [Segment] = []
        var current = Point(0, 0)
        var start = Point(0, 0)
        var lastControl: Point?
        var lastQuad: Point?
        var command: UInt8 = 0

        while true {
            if let letter = scanner.command() {
                command = letter
            } else if command == 0 || !scanner.hasNumber() {
                break
            }
            let relative = command >= 97
            func point(_ x: Double, _ y: Double) -> Point { relative ? Point(current.x + x, current.y + y) : Point(x, y) }
            var control: Point?
            var quad: Point?
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let x = scanner.number(), let y = scanner.number() else { return segments }
                current = point(x, y)
                start = current
                segments.append(.move(current))
                // Further pairs after a move are lines.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let x = scanner.number(), let y = scanner.number() else { return segments }
                current = point(x, y)
                segments.append(.line(current))
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return segments }
                current = Point(relative ? current.x + x : x, current.y)
                segments.append(.line(current))
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return segments }
                current = Point(current.x, relative ? current.y + y : y)
                segments.append(.line(current))
            case UInt8(ascii: "c"):
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return segments }
                let first = point(x1, y1), second = point(x2, y2), end = point(x, y)
                segments.append(.cubic(first, second, end))
                control = second
                current = end
            case UInt8(ascii: "s"):
                guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return segments }
                let first = lastControl.map { Point(2 * current.x - $0.x, 2 * current.y - $0.y) } ?? current
                let second = point(x2, y2), end = point(x, y)
                segments.append(.cubic(first, second, end))
                control = second
                current = end
            case UInt8(ascii: "q"):
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return segments }
                let handle = point(x1, y1), end = point(x, y)
                segments.append(.quad(handle, end))
                quad = handle
                current = end
            case UInt8(ascii: "t"):
                guard let x = scanner.number(), let y = scanner.number() else { return segments }
                let handle = lastQuad.map { Point(2 * current.x - $0.x, 2 * current.y - $0.y) } ?? current
                let end = point(x, y)
                segments.append(.quad(handle, end))
                quad = handle
                current = end
            case UInt8(ascii: "z"):
                segments.append(.close)
                current = start
                command = 0
            default:
                return segments
            }
            lastControl = control
            lastQuad = quad
        }
        return segments
    }

    /// Splits path data into command letters and numbers.
    private struct Tokens {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSeparators() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ",")].contains(bytes[index]) { index += 1 }
        }

        mutating func command() -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            guard (65...90).contains(byte) || (97...122).contains(byte), byte != UInt8(ascii: "e"), byte != UInt8(ascii: "E") else { return nil }
            index += 1
            return byte
        }

        mutating func hasNumber() -> Bool {
            skipSeparators()
            guard index < bytes.count else { return false }
            let byte = bytes[index]
            return (48...57).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
        }

        /// One number; a second "." or a sign starts the next one.
        mutating func number() -> Double? {
            guard hasNumber() else { return nil }
            let begin = index
            if bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var dot = false
            while index < bytes.count {
                let byte = bytes[index]
                if (48...57).contains(byte) {
                    index += 1
                } else if byte == UInt8(ascii: "."), !dot {
                    dot = true
                    index += 1
                } else if byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                    index += 1
                    if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
                } else {
                    break
                }
            }
            return Double(String(decoding: bytes[begin..<index], as: UTF8.self))
        }
    }
}
