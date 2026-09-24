import XCTest
@testable import CheNtucoolCore

/// Fake AppleScript runner: never touches Safari. It answers the tab-listing
/// script with a canned tab table and answers `do JavaScript` scripts by
/// looking up which tab the script targets and which HTTP method it uses.
final class FakeScriptRunner: ScriptRunner, @unchecked Sendable {
    var tabTable: String
    /// (window, tab, method) -> envelope JSON returned by "Safari"
    var responses: [String: String] = [:]
    private(set) var scripts: [String] = []
    private let lock = NSLock()

    init(tabTable: String) { self.tabTable = tabTable }

    func run(appleScript: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        scripts.append(appleScript)
        if appleScript.contains("do JavaScript") {
            let target = Self.target(of: appleScript)
            let method = Self.method(of: appleScript)
            guard let reply = responses["\(target.window)/\(target.tab)/\(method)"] else {
                throw CanvasTransportError.safariScriptFailed("no canned reply for \(target) \(method)")
            }
            return reply
        }
        return tabTable
    }

    var listCalls: Int { scripts.filter { !$0.contains("do JavaScript") }.count }
    var jsCalls: [String] { scripts.filter { $0.contains("do JavaScript") } }

    static func target(of script: String) -> (window: Int, tab: Int) {
        let re = try! NSRegularExpression(pattern: #"tab (\d+) of window (\d+)"#)
        let m = re.firstMatch(in: script, range: NSRange(script.startIndex..., in: script))!
        let t = Int(script[Range(m.range(at: 1), in: script)!])!
        let w = Int(script[Range(m.range(at: 2), in: script)!])!
        return (w, t)
    }

    static func method(of script: String) -> String {
        // The request itself is `x.open`; a write script also carries the owner
        // check's `w.open("GET"…)` before it.
        for m in ["GET", "POST", "PUT", "DELETE"] where script.contains("x.open(\\\"\(m)\\\"") { return m }
        return "?"
    }

    static func envelope(status: Int, text: String, link: String = "") -> String {
        let obj: [String: Any] = ["s": status, "t": text, "l": link]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }
}

final class SafariSessionTransportTests: XCTestCase {

    // 3 tabs: window 1 tab 1 is current but a non-course page; window 1 tab 2
    // is a course page; window 2 tab 1 is unrelated.
    private let tabs = """
    1\t1\t1\thttps://cool.ntu.edu.tw/
    1\t2\t0\thttps://cool.ntu.edu.tw/courses/64652/modules
    2\t1\t1\thttps://example.com/
    2\t2\t0\thttps://cool.ntu.edu.tw/calendar

    """

    func testEnvelopeParsingStripsWhile1AndReadsLink() throws {
        let raw = FakeScriptRunner.envelope(
            status: 200, text: #"while(1);[{"id":1}]"#,
            link: #"<https://cool.ntu.edu.tw/api/v1/x?page=2>; rel="next""#
        )
        let response = try SafariSessionTransport.parseEnvelope(raw)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), #"[{"id":1}]"#)
        XCTAssertEqual(response.nextURL, "https://cool.ntu.edu.tw/api/v1/x?page=2")
    }

    func testEnvelopeParsingRejectsNonEnvelope() {
        XCTAssertThrowsError(try SafariSessionTransport.parseEnvelope("execution error: Safari got an error")) { error in
            guard case CanvasTransportError.safariScriptFailed = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testNonGETCarriesCSRFTokenAndJSONBody() {
        let js = SafariSessionTransport.javascript(
            method: "POST", sameOriginPath: "/api/v1/courses/1/modules",
            jsonBody: Data(#"{"module":{"name":"W01"}}"#.utf8)
        )
        XCTAssertTrue(js.contains("X-CSRF-Token"))
        XCTAssertTrue(js.contains("_csrf_token"))
        XCTAssertTrue(js.contains("decodeURIComponent"))
        XCTAssertTrue(js.contains(#"setRequestHeader("Content-Type","application/json")"#))
        XCTAssertTrue(js.contains(#"setRequestHeader("Accept","application/json")"#))
        XCTAssertTrue(js.contains(#"x.send("{\"module\":{\"name\":\"W01\"}}")"#), js)

        let get = SafariSessionTransport.javascript(method: "GET", sameOriginPath: "/api/v1/users/self", jsonBody: nil)
        XCTAssertFalse(get.contains("X-CSRF-Token"))
        XCTAssertTrue(get.contains("x.send(null)"))
    }

    func testCandidateRanking() {
        let parsed = SafariSessionTransport.parseTabList(tabs)
        XCTAssertEqual(parsed.count, 4)
        let ranked = SafariSessionTransport.rankCandidates(parsed, host: "cool.ntu.edu.tw")
        XCTAssertEqual(ranked.map { "\($0.window)/\($0.tab)" }, ["1/1", "1/2", "2/2"])
    }

    func testProbesInOrderLocksFirst200AndReuses() async throws {
        let runner = FakeScriptRunner(tabTable: tabs)
        runner.responses["1/1/GET"] = FakeScriptRunner.envelope(status: 401, text: #"{"status":"unauthenticated"}"#)
        runner.responses["1/2/GET"] = FakeScriptRunner.envelope(status: 200, text: #"while(1);{"id":42}"#)
        runner.responses["1/2/POST"] = FakeScriptRunner.envelope(status: 201, text: #"{"id":7}"#)
        let transport = SafariSessionTransport(runner: runner)

        let first = try await transport.send(method: "GET", path: "users/self", query: [:], jsonBody: nil)
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(String(decoding: first.body, as: UTF8.self), #"{"id":42}"#)
        XCTAssertEqual(transport.lockedTab.map { "\($0.window)/\($0.tab)" }, "1/2")

        let second = try await transport.send(
            method: "POST", path: "courses/1/modules", query: [:], jsonBody: Data("{}".utf8)
        )
        XCTAssertEqual(second.status, 201)
        // Probing happened once (two probes: 1/1 failed, 1/2 answered 200);
        // the two real requests then went straight to the locked tab.
        XCTAssertEqual(runner.listCalls, 1)
        XCTAssertEqual(runner.jsCalls.count, 4)
        XCTAssertTrue(runner.jsCalls[0].contains("tab 1 of window 1"))
        XCTAssertTrue(runner.jsCalls[1].contains("tab 2 of window 1"))
        XCTAssertTrue(runner.jsCalls.last!.contains("tab 2 of window 1"))
    }

    func testAllProbesFailingThrowsDescriptiveError() async {
        let runner = FakeScriptRunner(tabTable: tabs)
        runner.responses["1/1/GET"] = FakeScriptRunner.envelope(status: 401, text: "")
        runner.responses["1/2/GET"] = FakeScriptRunner.envelope(status: 401, text: "")
        runner.responses["2/2/GET"] = FakeScriptRunner.envelope(status: 302, text: "")
        let transport = SafariSessionTransport(runner: runner)
        do {
            _ = try await transport.send(method: "GET", path: "users/self", query: [:], jsonBody: nil)
            XCTFail("expected throw")
        } catch let error as CanvasTransportError {
            guard case .noSafariSession(let tried) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(tried.count, 3)
            XCTAssertTrue(error.localizedDescription.contains("Safari 沒有已登入的 COOL 分頁"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testNoCoolTabsAtAllThrows() async {
        let runner = FakeScriptRunner(tabTable: "1\t1\t1\thttps://example.com/\n")
        let transport = SafariSessionTransport(runner: runner)
        do {
            _ = try await transport.send(method: "GET", path: "users/self", query: [:], jsonBody: nil)
            XCTFail("expected throw")
        } catch let error as CanvasTransportError {
            XCTAssertEqual(error, .noSafariSession(tried: []))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// Inside `tell application "Safari"` the word `tab` is Safari's tab
    /// class, so `& tab &` emits the literal text "tab" and every line fails
    /// `parseTabList` — found in the live acceptance run (#1), invisible to
    /// the canned-output tests above.
    func testTabListScriptUsesARealTabCharacter() {
        XCTAssertFalse(SafariSessionTransport.tabListScript.contains("& tab &"))
        XCTAssertTrue(SafariSessionTransport.tabListScript.contains("character id 9"))
        XCTAssertTrue(SafariSessionTransport.parseTabList("5tab29tab1tabhttps://cool.ntu.edu.tw/x\n").isEmpty,
                      "documents the failure mode the script change fixes")
    }
}
