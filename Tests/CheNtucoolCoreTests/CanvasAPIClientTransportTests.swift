import XCTest
@testable import CheNtucoolCore

/// Transport fake that answers by path (with query) so pagination and body
/// encoding can be asserted without the network.
final class RoutingTransport: CanvasTransport, @unchecked Sendable {
    var routes: [String: CanvasResponse] = [:]
    private(set) var calls: [(method: String, path: String, query: [String: String], body: Data?)] = []
    private let lock = NSLock()

    func send(method: String, path: String, query: [String: String], jsonBody: Data?) async throws -> CanvasResponse {
        lock.lock(); defer { lock.unlock() }
        calls.append((method, path, query, jsonBody))
        guard let r = routes[path] else {
            return CanvasResponse(status: 404, body: Data("{\"errors\":[{\"message\":\"not found\"}]}".utf8), link: nil)
        }
        return r
    }
}

final class CanvasAPIClientTransportTests: XCTestCase {

    func testRequestReturnsBodyAndPassesQuery() async throws {
        let t = RoutingTransport()
        t.routes["courses/1"] = CanvasResponse(status: 200, body: Data(#"{"id":1}"#.utf8), link: nil)
        let client = CanvasAPIClient(transport: t)
        let data = try await client.request("GET", path: "courses/1", query: ["include[]": "term"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"id":1}"#)
        XCTAssertEqual(t.calls.first?.query, ["include[]": "term"])
        XCTAssertNil(t.calls.first?.body)
    }

    func testRequestThrowsHTTPErrorAtOrAbove400() async {
        let t = RoutingTransport()
        let client = CanvasAPIClient(transport: t)
        do {
            _ = try await client.request("GET", path: "missing")
            XCTFail("expected throw")
        } catch let CanvasAPIError.httpError(code, body) {
            XCTAssertEqual(code, 404)
            XCTAssertTrue(body.contains("not found"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRequestEncodesEncodableJSONBody() async throws {
        struct ModulePayload: Encodable { let module: [String: String] }
        let t = RoutingTransport()
        t.routes["courses/1/modules"] = CanvasResponse(status: 200, body: Data("{}".utf8), link: nil)
        let client = CanvasAPIClient(transport: t)
        _ = try await client.request("POST", path: "courses/1/modules", json: ModulePayload(module: ["name": "W01"]))
        XCTAssertEqual(t.calls.first?.method, "POST")
        let sent = try XCTUnwrap(t.calls.first?.body)
        let obj = try JSONSerialization.jsonObject(with: sent) as? [String: [String: String]]
        XCTAssertEqual(obj, ["module": ["name": "W01"]])
    }

    func testPaginateFollowsLinkNextAcrossPages() async throws {
        let t = RoutingTransport()
        let page2 = "https://cool.ntu.edu.tw/api/v1/courses/1/modules?page=2&per_page=100"
        t.routes["courses/1/modules"] = CanvasResponse(
            status: 200, body: Data(#"[{"id":1},{"id":2}]"#.utf8),
            link: "<\(page2)>; rel=\"next\", <https://cool.ntu.edu.tw/api/v1/courses/1/modules?page=1&per_page=100>; rel=\"current\""
        )
        t.routes[page2] = CanvasResponse(status: 200, body: Data(#"[{"id":3}]"#.utf8), link: #"<x>; rel="current""#)
        let client = CanvasAPIClient(transport: t)
        let items = try await client.paginate(path: "courses/1/modules", query: ["include[]": "items"])
        XCTAssertEqual(items.map { $0["id"] as? Int }, [1, 2, 3])
        XCTAssertEqual(t.calls.count, 2)
        // First call carries per_page=100 plus the caller's query; the next
        // URL is passed verbatim with no extra query (it already has them).
        XCTAssertEqual(t.calls[0].query, ["include[]": "items", "per_page": "100"])
        XCTAssertEqual(t.calls[1].path, page2)
        XCTAssertEqual(t.calls[1].query, [:])
    }

    func testPaginateDecodedTypedWrapper() async throws {
        let t = RoutingTransport()
        t.routes["courses"] = CanvasResponse(status: 200, body: Data(#"[{"id":5,"name":"A"}]"#.utf8), link: nil)
        let client = CanvasAPIClient(transport: t)
        let courses: [CanvasCourse] = try await client.paginateDecoded(path: "courses")
        XCTAssertEqual(courses.map(\.id), [5])
    }

    func testTypedListCoursesIsAThinWrapper() async throws {
        let t = RoutingTransport()
        t.routes["courses"] = CanvasResponse(status: 200, body: Data(#"[{"id":64652,"name":"普通心理學"}]"#.utf8), link: nil)
        let client = CanvasAPIClient(transport: t)
        let courses = try await client.listCourses()
        XCTAssertEqual(courses.first?.id, 64652)
        XCTAssertEqual(t.calls.first?.query["per_page"], "50")
    }

    func testTypedWritesSendJSONBodies() async throws {
        let t = RoutingTransport()
        t.routes["courses/1/assignments/2/submissions/3"] = CanvasResponse(
            status: 200, body: Data(#"{"id":9,"user_id":3,"assignment_id":2,"score":85,"grade":"85"}"#.utf8), link: nil
        )
        t.routes["courses/1/discussion_topics"] = CanvasResponse(
            status: 200, body: Data(#"{"id":11,"title":"Hi"}"#.utf8), link: nil
        )
        let client = CanvasAPIClient(transport: t)
        _ = try await client.updateSubmissionGrade(courseId: 1, assignmentId: 2, userId: 3, grade: "85+")
        _ = try await client.createAnnouncement(courseId: 1, title: "Hi", message: "a & b")
        let grade = try JSONSerialization.jsonObject(with: XCTUnwrap(t.calls[0].body)) as? [String: [String: String]]
        XCTAssertEqual(grade, ["submission": ["posted_grade": "85+"]])
        XCTAssertEqual(t.calls[0].method, "PUT")
        let ann = try JSONSerialization.jsonObject(with: XCTUnwrap(t.calls[1].body)) as? [String: Any]
        XCTAssertEqual(ann?["title"] as? String, "Hi")
        XCTAssertEqual(ann?["message"] as? String, "a & b")
        XCTAssertEqual(ann?["is_announcement"] as? Bool, true)
    }

    func testTokenConvenienceInitBuildsTokenTransport() {
        let client = CanvasAPIClient(token: "x")
        XCTAssertTrue(client.transport is TokenTransport)
    }
}
