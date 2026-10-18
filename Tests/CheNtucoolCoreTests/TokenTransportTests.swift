import XCTest
@testable import CheNtucoolCore

/// URLProtocol stub so TokenTransport can be exercised without the network.
/// Each test installs a handler that inspects the outgoing request and
/// returns a canned (status, headers, body).
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CanvasURLTests: XCTestCase {
    private let base = URL(string: "https://cool.ntu.edu.tw/api/v1")!

    func testRelativePathAppendsToBase() {
        let url = CanvasURL.resolve(path: "courses/1/modules", query: ["per_page": "100"], base: base)
        XCTAssertEqual(url.absoluteString, "https://cool.ntu.edu.tw/api/v1/courses/1/modules?per_page=100")
    }

    func testLeadingSlashAndApiPrefixAreTolerated() {
        XCTAssertEqual(
            CanvasURL.resolve(path: "/api/v1/users/self", query: [:], base: base).absoluteString,
            "https://cool.ntu.edu.tw/api/v1/users/self"
        )
        XCTAssertEqual(
            CanvasURL.resolve(path: "/users/self", query: [:], base: base).absoluteString,
            "https://cool.ntu.edu.tw/api/v1/users/self"
        )
    }

    func testFullURLIsUsedVerbatim() {
        let next = "https://cool.ntu.edu.tw/api/v1/courses/1/modules?page=2&per_page=100"
        XCTAssertEqual(CanvasURL.resolve(path: next, query: [:], base: base).absoluteString, next)
    }

    func testSameOriginPathForSafari() {
        XCTAssertEqual(
            CanvasURL.sameOriginPath(path: "courses/1/modules", query: ["per_page": "100"]),
            "/api/v1/courses/1/modules?per_page=100"
        )
        XCTAssertEqual(
            CanvasURL.sameOriginPath(
                path: "https://cool.ntu.edu.tw/api/v1/courses/1/modules?page=2", query: [:]
            ),
            "/api/v1/courses/1/modules?page=2"
        )
    }

    func testLinkHeaderNextExtraction() {
        let link = #"<https://cool.ntu.edu.tw/api/v1/courses/1/modules?page=1&per_page=100>; rel="current",<https://cool.ntu.edu.tw/api/v1/courses/1/modules?page=2&per_page=100>; rel="next",<https://cool.ntu.edu.tw/api/v1/courses/1/modules?page=1&per_page=100>; rel="first""#
        XCTAssertEqual(
            CanvasResponse(status: 200, body: Data(), link: link).nextURL,
            "https://cool.ntu.edu.tw/api/v1/courses/1/modules?page=2&per_page=100"
        )
        XCTAssertNil(CanvasResponse(status: 200, body: Data(), link: nil).nextURL)
        XCTAssertNil(CanvasResponse(status: 200, body: Data(), link: #"<x>; rel="first""#).nextURL)
    }
}

final class TokenTransportTests: XCTestCase {
    private func makeTransport(token: String = "tok") -> TokenTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return TokenTransport(token: token, session: URLSession(configuration: config))
    }

    override func tearDown() { StubURLProtocol.handler = nil }

    func testSendsBearerAndAcceptJSON() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        StubURLProtocol.handler = { req in
            seen = req
            return (200, ["Link": #"<https://x/api/v1/a?page=2>; rel="next""#], Data("[]".utf8))
        }
        let response = try await makeTransport().send(
            method: "GET", path: "courses", query: ["per_page": "100"], jsonBody: nil
        )
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, Data("[]".utf8))
        XCTAssertEqual(response.nextURL, "https://x/api/v1/a?page=2")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(seen?.url?.absoluteString, "https://cool.ntu.edu.tw/api/v1/courses?per_page=100")
    }

    func testHTTP401IsReturnedNotThrown() async throws {
        StubURLProtocol.handler = { _ in (401, [:], Data(#"{"errors":[{"message":"Invalid access token."}]}"#.utf8)) }
        let response = try await makeTransport().send(method: "GET", path: "users/self", query: [:], jsonBody: nil)
        XCTAssertEqual(response.status, 401)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("Invalid access token"))
    }

    func testJSONBodySetsContentType() async throws {
        nonisolated(unsafe) var seen: (URLRequest, Data?)?
        StubURLProtocol.handler = { req in
            // URLProtocol exposes streamed bodies via httpBodyStream; read it.
            var data: Data?
            if let stream = req.httpBodyStream {
                stream.open()
                var buf = [UInt8](repeating: 0, count: 4096)
                var out = Data()
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    out.append(buf, count: n)
                }
                data = out
            } else {
                data = req.httpBody
            }
            seen = (req, data)
            return (201, [:], Data("{}".utf8))
        }
        let body = Data(#"{"title":"W01"}"#.utf8)
        let response = try await makeTransport().send(method: "POST", path: "courses/1/modules", query: [:], jsonBody: body)
        XCTAssertEqual(response.status, 201)
        XCTAssertEqual(seen?.0.httpMethod, "POST")
        XCTAssertEqual(seen?.0.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(seen?.1, body)
    }
}
