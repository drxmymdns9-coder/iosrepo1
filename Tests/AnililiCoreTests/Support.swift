import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum Fixture {
    static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw FixtureMissing(name: name)
        }
        return url
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    /// The file's bytes as stored, for binary fixtures and bodies captured verbatim.
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    struct FixtureMissing: Error { var name: String }
}

/// What a faked network was asked, in order, for tests to check against.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var entries: [String] { lock.withLock { stored } }
    func append(_ entry: String) { lock.withLock { stored.append(entry) } }
}

extension HTTPURLResponse {
    /// A canned response for a faked network.
    static func canned(_ url: URL?, _ status: Int = 200, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url ?? URL(string: "https://example.invalid/")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }
}
