import Foundation

/// gzip (RFC 1952) around DEFLATE (RFC 1951), decoded in Swift.
///
/// Miruro's catalog bodies arrive masked and gzipped as `application/octet-stream`, so URLSession
/// never sees a `Content-Encoding` it could undo itself. Apple's Compression framework would do on
/// iOS, but it doesn't exist on Linux, where the Core tests run; this is small enough to own.
///
/// It decodes bit by bit (after zlib's `puff`), which is plenty for API bodies of tens of KB.
public enum Gzip {
    public enum Failure: Error, Equatable {
        case notGzip
        case corrupt(String)
    }

    public static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        // 10-byte header, at least a 2-byte empty block, 8-byte trailer.
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw Failure.notGzip
        }
        let flags = bytes[3]
        var position = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard position + 2 <= bytes.count else { throw Failure.corrupt("header") }
            position += 2 + (Int(bytes[position]) | Int(bytes[position + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT: zero-terminated
            while position < bytes.count, bytes[position] != 0 { position += 1 }
            position += 1
        }
        if flags & 0x02 != 0 { position += 2 }  // FHCRC
        guard position < bytes.count else { throw Failure.corrupt("header") }

        var inflater = Inflater(input: bytes, position: position)
        return Data(try inflater.run())
    }
}

private struct Huffman {
    /// Codes of each bit length, 0...15.
    var counts = [Int](repeating: 0, count: 16)
    /// Symbols ordered by code.
    var symbols: [Int]

    init(lengths: [Int]) {
        for length in lengths { counts[length] += 1 }
        counts[0] = 0
        var offsets = [Int](repeating: 0, count: 16)
        for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
        symbols = [Int](repeating: 0, count: lengths.count)
        for (symbol, length) in lengths.enumerated() where length != 0 {
            symbols[offsets[length]] = symbol
            offsets[length] += 1
        }
    }
}

private struct Inflater {
    let input: [UInt8]
    var position: Int
    var bitBuffer: UInt32 = 0
    var bitCount = 0
    var output: [UInt8] = []

    init(input: [UInt8], position: Int) {
        self.input = input
        self.position = position
        output.reserveCapacity(input.count * 4)
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    static let fixedLiterals = Huffman(lengths:
        [Int](repeating: 8, count: 144) + [Int](repeating: 9, count: 112) + [Int](repeating: 7, count: 24) + [Int](repeating: 8, count: 8))
    static let fixedDistances = Huffman(lengths: [Int](repeating: 5, count: 30))

    mutating func run() throws -> [UInt8] {
        var last = 0
        repeat {
            last = try bits(1)
            switch try bits(2) {
            case 0: try stored()
            case 1: try inflate(Self.fixedLiterals, Self.fixedDistances)
            case 2:
                let (literals, distances) = try dynamicTables()
                try inflate(literals, distances)
            default: throw Gzip.Failure.corrupt("block type")
            }
        } while last == 0
        return output
    }

    mutating func bits(_ count: Int) throws -> Int {
        while bitCount < count {
            guard position < input.count else { throw Gzip.Failure.corrupt("unexpected end") }
            bitBuffer |= UInt32(input[position]) << UInt32(bitCount)
            position += 1
            bitCount += 8
        }
        let value = Int(bitBuffer & ((1 << UInt32(count)) - 1))
        bitBuffer >>= UInt32(count)
        bitCount -= count
        return value
    }

    mutating func stored() throws {
        // Whatever is left in the buffer is the rest of the current byte.
        bitBuffer = 0
        bitCount = 0
        guard position + 4 <= input.count else { throw Gzip.Failure.corrupt("stored header") }
        let length = Int(input[position]) | Int(input[position + 1]) << 8
        let complement = Int(input[position + 2]) | Int(input[position + 3]) << 8
        guard length == ~complement & 0xFFFF else { throw Gzip.Failure.corrupt("stored length") }
        position += 4
        guard position + length <= input.count else { throw Gzip.Failure.corrupt("stored data") }
        output.append(contentsOf: input[position..<(position + length)])
        position += length
    }

    mutating func decode(_ table: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for length in 1...15 {
            code |= try bits(1)
            let count = table.counts[length]
            if code - count < first { return table.symbols[index + (code - first)] }
            index += count
            first = (first + count) << 1
            code <<= 1
        }
        throw Gzip.Failure.corrupt("bad code")
    }

    mutating func inflate(_ literals: Huffman, _ distances: Huffman) throws {
        while true {
            let symbol = try decode(literals)
            if symbol < 256 {
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let lengthCode = symbol - 257
                guard lengthCode < 29 else { throw Gzip.Failure.corrupt("length code") }
                let length = try Self.lengthBase[lengthCode] + bits(Self.lengthExtra[lengthCode])
                let distanceCode = try decode(distances)
                guard distanceCode < 30 else { throw Gzip.Failure.corrupt("distance code") }
                let distance = try Self.distanceBase[distanceCode] + bits(Self.distanceExtra[distanceCode])
                guard distance <= output.count else { throw Gzip.Failure.corrupt("distance too far") }
                let start = output.count - distance
                for offset in 0..<length { output.append(output[start + offset]) }
            }
        }
    }

    mutating func dynamicTables() throws -> (Huffman, Huffman) {
        let literalCount = try bits(5) + 257
        let distanceCount = try bits(5) + 1
        let codeCount = try bits(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else { throw Gzip.Failure.corrupt("table sizes") }

        var codeLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeCount { codeLengths[Self.codeLengthOrder[index]] = try bits(3) }
        let codeTable = Huffman(lengths: codeLengths)

        var lengths: [Int] = []
        lengths.reserveCapacity(literalCount + distanceCount)
        while lengths.count < literalCount + distanceCount {
            let symbol = try decode(codeTable)
            if symbol < 16 {
                lengths.append(symbol)
                continue
            }
            var repeated = 0
            let times: Int
            switch symbol {
            case 16:
                guard let previous = lengths.last else { throw Gzip.Failure.corrupt("repeat with no length") }
                repeated = previous
                times = try 3 + bits(2)
            case 17: times = try 3 + bits(3)
            default: times = try 11 + bits(7)
            }
            guard lengths.count + times <= literalCount + distanceCount else { throw Gzip.Failure.corrupt("repeat overflow") }
            lengths.append(contentsOf: repeatElement(repeated, count: times))
        }
        guard lengths[256] != 0 else { throw Gzip.Failure.corrupt("no end-of-block code") }
        return (Huffman(lengths: Array(lengths[0..<literalCount])), Huffman(lengths: Array(lengths[literalCount...])))
    }
}
