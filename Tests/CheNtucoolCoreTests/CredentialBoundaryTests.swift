import XCTest
@testable import CheNtucoolCore

/// The bearer token must only ever travel to the configured API origin over
/// https. Absolute URLs reach the transports from two places — callers, and
/// Canvas's own `Link: rel="next"` header — and neither is trusted to name
/// the host.
final class CredentialBoundaryTests: XCTestCase {
    private let base = URL(string: "https://cool.ntu.edu.tw/api/v1")!

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testForeignHostAbsoluteURLIsRefusedBeforeAnyRequest() async {
        var sent = false
        StubURLProtocol.handler = { _ in sent = true; return (200, [:], Data()) }
        let t = TokenTransport(token: "secret", baseURL: base, session: stubbedSession())
        do {
            _ = try await t.send(method: "GET", path: "https://evil.example/api/v1/courses", query: [:], jsonBody: nil)
            XCTFail("expected foreignURL")
        } catch let error as CanvasTransportError {
            XCTAssertEqual(error, .foreignURL("https://evil.example/api/v1/courses"))
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertFalse(sent, "the token must not leave the process")
    }

    func testPlainHTTPOnTheRightHostIsAlsoRefused() async {
        StubURLProtocol.handler = { _ in (200, [:], Data()) }
        let t = TokenTransport(token: "secret", baseURL: base, session: stubbedSession())
        do {
            _ = try await t.send(method: "GET", path: "http://cool.ntu.edu.tw/api/v1/courses", query: [:], jsonBody: nil)
            XCTFail("expected foreignURL")
        } catch let error as CanvasTransportError {
            XCTAssertEqual(error, .foreignURL("http://cool.ntu.edu.tw/api/v1/courses"))
        } catch { XCTFail("wrong error \(error)") }
    }

    func testLookalikeHostIsRefused() {
        XCTAssertThrowsError(try CanvasURL.checkedResolve(path: "https://cool.ntu.edu.tw.evil.example/api/v1/x", query: [:], base: base))
        XCTAssertThrowsError(try CanvasURL.checkedResolve(path: "https://cool.ntu.edu.tw:8443/api/v1/x", query: [:], base: base))
        XCTAssertThrowsError(try CanvasURL.checkedResolve(path: "https://user@evil.example/api/v1/x", query: [:], base: base))
    }

    func testSameOriginAbsoluteURLStillWorks() throws {
        let next = "https://cool.ntu.edu.tw/api/v1/courses/1/modules?page=2&per_page=100"
        XCTAssertEqual(try CanvasURL.checkedResolve(path: next, query: [:], base: base).absoluteString, next)
    }

    func testSafariSameOriginPathRefusesForeignAbsoluteURL() {
        XCTAssertThrowsError(try CanvasURL.checkedSameOriginPath(path: "https://evil.example/api/v1/x", query: [:], host: "cool.ntu.edu.tw"))
        XCTAssertEqual(
            try CanvasURL.checkedSameOriginPath(path: "https://cool.ntu.edu.tw/api/v1/x?page=2", query: [:], host: "cool.ntu.edu.tw"),
            "/api/v1/x?page=2"
        )
    }
}

/// Only a *credential* rejection may move the ladder to Safari. Canvas also
/// answers 401 for "user not authorized to perform that action" — a
/// permission refusal — and replaying that under whatever account a Safari
/// tab happens to hold would run the request as someone else.
final class AutoTransportIdentityTests: XCTestCase {
    private func ok(_ body: String = "{}") -> CanvasResponse { CanvasResponse(status: 200, body: Data(body.utf8), link: nil) }
    private let permissionDenied = CanvasResponse(
        status: 401,
        body: Data(#"{"status":"unauthorized","errors":[{"message":"user not authorized to perform that action"}]}"#.utf8),
        link: nil
    )
    private let invalidToken = CanvasResponse(status: 401, body: Data(#"{"errors":[{"message":"Invalid access token."}]}"#.utf8), link: nil)

    func testPermissionDenied401DoesNotSwitch() async throws {
        let token = FakeTransport(name: "token", responses: [permissionDenied])
        let auto = AutoTransport(
            tokenProvider: { "tok" },
            tokenTransportFactory: { _ in token },
            safariFactory: { XCTFail("must not switch on a permission 401"); return token },
            log: { _ in }
        )
        let r = try await auto.send(method: "PUT", path: "courses/1/quizzes/2", query: [:], jsonBody: Data("{}".utf8))
        XCTAssertEqual(r.status, 401)
        XCTAssertEqual(auto.activeRung, "token")
    }

    func testSafariIdentityMismatchRefusesAndNeverSendsTheRequest() async {
        let safari = FakeTransport(name: "safari", responses: [ok(#"{"id":999,"name":"Someone Else"}"#)])
        let auto = AutoTransport(
            tokenProvider: { nil },
            safariFactory: { safari },
            expectedUserID: 42,
            log: { _ in }
        )
        do {
            _ = try await auto.send(method: "POST", path: "courses/1/discussion_topics", query: [:], jsonBody: Data("{}".utf8))
            XCTFail("expected identityMismatch")
        } catch let error as CanvasTransportError {
            XCTAssertEqual(error, .identityMismatch(expected: 42, actual: 999, name: "Someone Else"))
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertEqual(safari.calls.map(\.path), ["users/self"], "only the identity probe may run")
        // Stays refused: a second call does not retry into the wrong account.
        do {
            _ = try await auto.send(method: "GET", path: "courses", query: [:], jsonBody: nil)
            XCTFail("expected identityMismatch again")
        } catch {}
        XCTAssertEqual(safari.calls.count, 1)
    }

    func testSafariIdentityIsLoggedOnceAndMatchingIDProceeds() async throws {
        let safari = FakeTransport(name: "safari", responses: [ok(#"{"id":42,"name":"鄭澈"}"#), ok("[1]"), ok("[2]")])
        var logged: [String] = []
        let auto = AutoTransport(
            tokenProvider: { nil },
            safariFactory: { safari },
            expectedUserID: 42,
            log: { logged.append($0) }
        )
        _ = try await auto.send(method: "GET", path: "courses", query: [:], jsonBody: nil)
        _ = try await auto.send(method: "GET", path: "courses", query: [:], jsonBody: nil)
        XCTAssertEqual(safari.calls.map(\.path), ["users/self", "courses", "courses"])
        XCTAssertTrue(logged.joined(separator: "\n").contains("鄭澈（id 42）"), logged.joined(separator: "\n"))
    }

    func testSwitchAfterInvalidTokenAlsoChecksIdentity() async {
        let token = FakeTransport(name: "token", responses: [invalidToken])
        let safari = FakeTransport(name: "safari", responses: [ok(#"{"id":7,"name":"Student"}"#)])
        let auto = AutoTransport(
            tokenProvider: { "stale" },
            tokenTransportFactory: { _ in token },
            safariFactory: { safari },
            expectedUserID: 42,
            log: { _ in }
        )
        do {
            _ = try await auto.send(method: "PUT", path: "courses/1/assignments/3", query: [:], jsonBody: Data("{}".utf8))
            XCTFail("expected identityMismatch")
        } catch let error as CanvasTransportError {
            XCTAssertEqual(error, .identityMismatch(expected: 42, actual: 7, name: "Student"))
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertEqual(safari.calls.map(\.path), ["users/self"])
    }
}
