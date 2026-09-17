import XCTest
@testable import CheNtucoolCore

/// Scripted transport: returns canned responses in order and records calls.
final class FakeTransport: CanvasTransport, @unchecked Sendable {
    let name: String
    private var queue: [CanvasResponse]
    private(set) var calls: [(method: String, path: String)] = []
    private let lock = NSLock()

    init(name: String, responses: [CanvasResponse]) {
        self.name = name
        self.queue = responses
    }

    func send(method: String, path: String, query: [String: String], jsonBody: Data?) async throws -> CanvasResponse {
        lock.lock(); defer { lock.unlock() }
        calls.append((method, path))
        precondition(!queue.isEmpty, "\(name): unexpected call \(method) \(path)")
        return queue.removeFirst()
    }
}

final class AutoTransportTests: XCTestCase {
    private func ok(_ body: String = "{}") -> CanvasResponse { CanvasResponse(status: 200, body: Data(body.utf8), link: nil) }
    private let unauthorized = CanvasResponse(status: 401, body: Data(#"{"errors":[{"message":"Invalid access token."}]}"#.utf8), link: nil)

    func testMissingTokenGoesStraightToSafari() async throws {
        let safari = FakeTransport(name: "safari", responses: [ok("[1]")])
        var logged: [String] = []
        let auto = AutoTransport(
            tokenProvider: { nil },
            tokenTransportFactory: { _ in XCTFail("token transport must not be built"); return safari },
            safariFactory: { safari },
            log: { logged.append($0) }
        )
        let r = try await auto.send(method: "GET", path: "courses", query: [:], jsonBody: nil)
        XCTAssertEqual(r.body, Data("[1]".utf8))
        XCTAssertEqual(safari.calls.count, 1)
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("NTU COOL 手動 token 約一小時失效"), logged[0])
    }

    func testTokenThatWorksStaysOnToken() async throws {
        let token = FakeTransport(name: "token", responses: [ok("a"), ok("b")])
        var safariBuilt = false
        let auto = AutoTransport(
            tokenProvider: { "tok" },
            tokenTransportFactory: { t in XCTAssertEqual(t, "tok"); return token },
            safariFactory: { safariBuilt = true; return FakeTransport(name: "safari", responses: []) },
            log: { _ in }
        )
        _ = try await auto.send(method: "GET", path: "a", query: [:], jsonBody: nil)
        _ = try await auto.send(method: "GET", path: "b", query: [:], jsonBody: nil)
        XCTAssertEqual(token.calls.map(\.path), ["a", "b"])
        XCTAssertFalse(safariBuilt)
    }

    func testTokenRejectedOnceSwitchesToSafariAndResends() async throws {
        let token = FakeTransport(name: "token", responses: [unauthorized])
        let safari = FakeTransport(name: "safari", responses: [ok("from-safari"), ok("next")])
        var logged: [String] = []
        let auto = AutoTransport(
            tokenProvider: { "stale" },
            tokenTransportFactory: { _ in token },
            safariFactory: { safari },
            log: { logged.append($0) }
        )
        let first = try await auto.send(method: "POST", path: "courses/1/modules", query: [:], jsonBody: Data("{}".utf8))
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(first.body, Data("from-safari".utf8))
        // The rejected request was replayed on Safari with the same verb/path.
        XCTAssertEqual(safari.calls.first?.method, "POST")
        XCTAssertEqual(safari.calls.first?.path, "courses/1/modules")

        // Afterwards the token transport is never consulted again.
        let second = try await auto.send(method: "GET", path: "users/self", query: [:], jsonBody: nil)
        XCTAssertEqual(second.body, Data("next".utf8))
        XCTAssertEqual(token.calls.count, 1)
        XCTAssertEqual(safari.calls.count, 2)
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("401"))
    }

    func testTokenProviderThrowingIsTreatedAsMissing() async throws {
        struct KeychainDown: Error {}
        let safari = FakeTransport(name: "safari", responses: [ok()])
        var logged: [String] = []
        let auto = AutoTransport(
            tokenProvider: { throw KeychainDown() },
            tokenTransportFactory: { _ in XCTFail("no token"); return safari },
            safariFactory: { safari },
            log: { logged.append($0) }
        )
        _ = try await auto.send(method: "GET", path: "courses", query: [:], jsonBody: nil)
        XCTAssertEqual(safari.calls.count, 1)
        XCTAssertTrue(logged.joined().contains("KeychainDown"))
    }

    func testOtherHTTPErrorsOnTokenDoNotSwitch() async throws {
        let token = FakeTransport(name: "token", responses: [CanvasResponse(status: 404, body: Data(), link: nil)])
        let auto = AutoTransport(
            tokenProvider: { "tok" },
            tokenTransportFactory: { _ in token },
            safariFactory: { XCTFail("must not switch on 404"); return token },
            log: { _ in }
        )
        let r = try await auto.send(method: "GET", path: "nope", query: [:], jsonBody: nil)
        XCTAssertEqual(r.status, 404)
    }
}
