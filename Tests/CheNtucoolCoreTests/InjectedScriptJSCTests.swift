import XCTest
import JavaScriptCore
@testable import CheNtucoolCore

/// Executes the script SafariSessionTransport injects, in JavaScriptCore with
/// stubbed `location` and `XMLHttpRequest`, so the guards are tested as code
/// rather than as substrings.
final class InjectedScriptJSCTests: XCTestCase {
    private func run(_ js: String, origin: String, selfBody: String) -> (envelope: [String: Any], sent: [String]) {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, e in XCTFail("JS exception: \(e?.toString() ?? "?")") }
        ctx.evaluateScript("""
        var location = {origin: \(String(reflecting: origin))};
        var document = {cookie: "_csrf_token=abc"};
        var __sent = [];
        function XMLHttpRequest() { this.h = {}; }
        XMLHttpRequest.prototype.open = function(m, u) { this.m = m; this.u = u; };
        XMLHttpRequest.prototype.setRequestHeader = function(k, v) { this.h[k] = v; };
        XMLHttpRequest.prototype.getResponseHeader = function() { return ""; };
        XMLHttpRequest.prototype.send = function(b) {
          __sent.push(this.m + " " + this.u);
          if (this.u === "/api/v1/users/self") { this.status = 200; this.responseText = \(String(reflecting: selfBody)); }
          else { this.status = 201; this.responseText = "{}"; }
        };
        """)
        let out = ctx.evaluateScript(js)!.toString()!
        let env = (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]) ?? [:]
        let sent = ctx.objectForKeyedSubscript("__sent").toArray() as? [String] ?? []
        return (env, sent)
    }

    private func write(_ expected: Int?) -> String {
        SafariSessionTransport.javascript(method: "PUT", sameOriginPath: "/api/v1/courses/1/quizzes/2",
                                          jsonBody: Data(#"{"quiz":{"published":true}}"#.utf8),
                                          origin: "https://cool.ntu.edu.tw", expectedUserID: expected)
    }

    func testRightOwnerSends() {
        let r = run(write(42), origin: "https://cool.ntu.edu.tw", selfBody: #"while(1);{"id":42}"#)
        XCTAssertEqual(r.envelope["s"] as? Int, 201)
        XCTAssertEqual(r.sent, ["GET /api/v1/users/self", "PUT /api/v1/courses/1/quizzes/2"])
    }

    func testOtherOwnerSendsNothing() {
        let r = run(write(42), origin: "https://cool.ntu.edu.tw", selfBody: #"{"id":999,"name":"Other"}"#)
        XCTAssertEqual(r.envelope["s"] as? Int, -2)
        XCTAssertEqual(r.sent, ["GET /api/v1/users/self"], "the PUT never left")
    }

    func testWrongOriginSendsNothingAtAll() {
        let r = run(write(42), origin: "https://evil.example", selfBody: #"{"id":42}"#)
        XCTAssertEqual(r.envelope["s"] as? Int, -1)
        XCTAssertEqual(r.sent, [])
    }

    func testReadsDoNotProbeTheOwner() {
        let js = SafariSessionTransport.javascript(method: "GET", sameOriginPath: "/api/v1/courses", jsonBody: nil,
                                                   origin: "https://cool.ntu.edu.tw", expectedUserID: 42)
        let r = run(js, origin: "https://cool.ntu.edu.tw", selfBody: #"{"id":42}"#)
        XCTAssertEqual(r.sent, ["GET /api/v1/courses"])
    }
}
