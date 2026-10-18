import XCTest
@testable import CheNtucoolCore

/// Regression tests for the idd-verify round-1 findings on #1.
final class SafariOriginAndIdentityPinTests: XCTestCase {
    private let tabs = """
    1\t1\t1\thttps://cool.ntu.edu.tw/
    1\t2\t0\thttps://cool.ntu.edu.tw/courses/64652/modules
    2\t2\t0\thttps://cool.ntu.edu.tw/calendar

    """

    /// A tab is addressed by window/tab index; by the time a request runs the
    /// page may be another site. The request itself must check where it is.
    func testScriptChecksThePageOriginBeforeSending() {
        let js = SafariSessionTransport.javascript(method: "POST", sameOriginPath: "/api/v1/x", jsonBody: Data("{}".utf8),
                                                   origin: "https://cool.ntu.edu.tw")
        let guardRange = js.range(of: #"location.origin!=="https://cool.ntu.edu.tw""#)
        let openRange = js.range(of: "x.open(")
        XCTAssertNotNil(guardRange)
        XCTAssertNotNil(openRange)
        XCTAssertLessThan(guardRange!.lowerBound, openRange!.lowerBound, "the origin check runs before the request is opened")
    }

    func testWrongOriginEnvelopeIsAScriptFailure() {
        let raw = FakeScriptRunner.envelope(status: -1, text: "wrong origin https://evil.example")
        XCTAssertThrowsError(try SafariSessionTransport.parseEnvelope(raw)) { error in
            guard case .safariScriptFailed = error as? CanvasTransportError else { return XCTFail("\(error)") }
        }
    }

    /// Re-probing after the locked tab dies must not land on another account.
    func testRelockOntoADifferentAccountIsRefused() async throws {
        let runner = FakeScriptRunner(tabTable: tabs)
        runner.responses["1/1/GET"] = FakeScriptRunner.envelope(status: 401, text: "")
        runner.responses["1/2/GET"] = FakeScriptRunner.envelope(status: 200, text: #"{"id":42,"name":"T"}"#)
        let transport = SafariSessionTransport(runner: runner)
        _ = try await transport.send(method: "GET", path: "users/self", query: [:], jsonBody: nil)
        XCTAssertEqual(transport.pinnedUserID, 42)

        // Tab 1/2 goes away; the only other live session is someone else's.
        runner.responses["1/2/GET"] = nil
        runner.responses["1/2/POST"] = nil
        runner.responses["2/2/GET"] = FakeScriptRunner.envelope(status: 200, text: #"{"id":999,"name":"Other"}"#)
        runner.responses["2/2/POST"] = FakeScriptRunner.envelope(status: 201, text: "{}")
        do {
            _ = try await transport.send(method: "POST", path: "courses/1/discussion_topics", query: [:], jsonBody: Data("{}".utf8))
            XCTFail("expected refusal")
        } catch let error as CanvasTransportError {
            guard case .noSafariSession = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(runner.jsCalls.contains { $0.contains("tab 2 of window 2") && $0.contains(#"open(\"POST\""#) },
                       "the write never reached the other account's tab")
    }

    func testExpectedUserIDFiltersTheFirstProbeToo() async {
        let runner = FakeScriptRunner(tabTable: tabs)
        runner.responses["1/1/GET"] = FakeScriptRunner.envelope(status: 200, text: #"{"id":7}"#)
        runner.responses["1/2/GET"] = FakeScriptRunner.envelope(status: 200, text: #"{"id":42}"#)
        let transport = SafariSessionTransport(runner: runner, expectedUserID: 42)
        _ = try? await transport.send(method: "GET", path: "courses", query: [:], jsonBody: nil)
        XCTAssertEqual(transport.lockedTab.map { "\($0.window)/\($0.tab)" }, "1/2")
    }

    func testJSStringEscapesLineAndParagraphSeparators() {
        XCTAssertEqual(SafariSessionTransport.jsString("a\u{2028}b\u{2029}c"), #"a\u2028b\u2029c"#)
    }

    func testOriginPathCheckRespectsSegmentBoundary() {
        let base = URL(string: "https://cool.ntu.edu.tw/api/v1")!
        XCTAssertThrowsError(try CanvasURL.checkedResolve(path: "https://cool.ntu.edu.tw/api/v10/x", query: [:], base: base))
        XCTAssertNoThrow(try CanvasURL.checkedResolve(path: "https://cool.ntu.edu.tw/api/v1/x", query: [:], base: base))
    }
}

final class ReadBackPublishedTests: XCTestCase {
    private let config = CourseConfig(courseId: 1, modules: ["W03": 900], quizOptionSets: ["nine": QuizMarkdownTests.nine])

    func testAddURLSendsPublishedFalseExplicitly() async throws {
        let t = RecordingTransport { m, _ in m == "GET" ? (200, "[]") : (200, #"{"id":5,"published":false}"#) }
        _ = try await CourseSession(client: CanvasAPIClient(transport: t), config: config, gate: { _ in })
            .addURL(week: "W03", title: "t", url: "https://x.example", publish: false)
        let item = (t.writes[0].body as! [String: Any])["module_item"] as! [String: Any]
        XCTAssertEqual(item["published"] as? Bool, false)
    }

    /// If Canvas publishes a new item anyway, take it down at once and fail loudly.
    func testAddURLThatCameBackPublishedIsUnpublishedAndReported() async {
        let t = RecordingTransport { m, _ in
            switch m {
            case "GET": return (200, "[]")
            case "PUT": return (200, #"{"id":5,"published":false}"#)
            default: return (200, #"{"id":5,"published":true}"#)
            }
        }
        do {
            _ = try await CourseSession(client: CanvasAPIClient(transport: t), config: config, gate: { _ in })
                .addURL(week: "W03", title: "t", url: "https://x.example", publish: false)
            XCTFail("expected publishedUnexpectedly")
        } catch let e as CourseSessionError {
            XCTAssertEqual(e, .publishedUnexpectedly("module item", 5))
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(t.writes.map(\.method), ["POST", "PUT"])
        let put = (t.writes[1].body as! [String: Any])["module_item"] as! [String: Any]
        XCTAssertEqual(put["published"] as? Bool, false)
    }

    func testCreatedAssignmentThatCameBackPublishedIsReported() async {
        let t = RecordingTransport { m, _ in
            m == "GET" ? (200, "[]") : m == "PUT" ? (200, #"{"id":8,"published":false}"#) : (200, #"{"id":8,"published":true}"#)
        }
        do {
            _ = try await CourseSession(client: CanvasAPIClient(transport: t), config: config, gate: { _ in })
                .createAssignment(fields: ["name": "A"], week: nil)
            XCTFail("expected publishedUnexpectedly")
        } catch let e as CourseSessionError {
            XCTAssertEqual(e, .publishedUnexpectedly("assignment", 8))
        } catch { XCTFail("\(error)") }
    }

    func testStateFetchesItemsCanvasDidNotEmbed() async throws {
        let t = RecordingTransport { _, p in
            switch p {
            case "courses/1/modules": return (200, #"[{"id":900,"name":"W03","items_count":2}]"#)
            case "courses/1/modules/900/items": return (200, #"[{"id":1},{"id":2}]"#)
            default: return (200, "[]")
            }
        }
        let state = try await CourseSession(client: CanvasAPIClient(transport: t), config: config, gate: { _ in }).state()
        let modules = state["modules"] as! [[String: Any]]
        XCTAssertEqual((modules[0]["items"] as? [[String: Any]])?.count, 2)
    }

    func testMultiLineStemIsKept() throws {
        let md = "## 題目\n\n**1.** 第一行。\n第二行也是題幹。\n\n> Ref.\n\n---\n\n## 答案與講解\n\n| 1 | **⑤** |\n"
        let q = try QuizMarkdown.parse(md).questions[0]
        XCTAssertTrue(q.html.contains("第二行也是題幹"), q.html)
    }

    func testCSVFieldQuoting() {
        XCTAssertEqual(CSV.field("plain"), "plain")
        XCTAssertEqual(CSV.field("a,b"), "\"a,b\"")
        XCTAssertEqual(CSV.field("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSV.field("two\nlines"), "\"two\nlines\"")
    }
}

/// Found in the live re-run: after a rebuild, the keychain read waited forever
/// on an "allow access" dialog nobody could see. Without a human at a terminal
/// the read must fail fast, so the ladder moves on to Safari.
final class KeychainNoUITests: XCTestCase {
    func testNonInteractiveQueryRefusesUI() {
        let q = CanvasAuth.query(service: "s", account: "a", allowUI: false)
        XCTAssertEqual(q[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        XCTAssertNil(CanvasAuth.query(service: "s", account: "a", allowUI: true)[kSecUseAuthenticationUI as String])
    }

    func testInteractionNotAllowedReadsAsNoToken() {
        XCTAssertEqual(CanvasAuth.classify(errSecInteractionNotAllowed), .uiRequired)
        XCTAssertEqual(CanvasAuth.classify(errSecAuthFailed), .uiRequired)
        XCTAssertEqual(CanvasAuth.classify(errSecItemNotFound), .itemNotFound)
    }
}


/// idd-verify round 2 findings on #1.
final class VerifyRound2Tests: XCTestCase {
    private let config = CourseConfig(courseId: 1, modules: ["W03": 900])
    private let tabs = "1\t1\t1\thttps://cool.ntu.edu.tw/\n1\t2\t0\thttps://cool.ntu.edu.tw/courses/1\n"

    /// The corrective unpublish must be confirmed, not assumed.
    func testUnpublishThatDidNotTakeIsReportedAsFailed() async {
        let t = RecordingTransport { m, _ in m == "GET" ? (200, "[]") : (200, #"{"id":5,"published":true}"#) }
        do {
            _ = try await CourseSession(client: CanvasAPIClient(transport: t), config: config, gate: { _ in })
                .addURL(week: "W03", title: "t", url: "https://x.example", publish: false)
            XCTFail("expected unpublishFailed")
        } catch let e as CourseSessionError {
            XCTAssertEqual(e, .unpublishFailed("module item", 5))
        } catch { XCTFail("\(error)") }
    }

    func testUnpublishPUTErrorIsReportedAsFailed() async {
        let t = RecordingTransport { m, _ in
            m == "GET" ? (200, "[]") : m == "PUT" ? (500, "boom") : (200, #"{"id":5,"published":true}"#)
        }
        do {
            _ = try await CourseSession(client: CanvasAPIClient(transport: t), config: config, gate: { _ in })
                .addURL(week: "W03", title: "t", url: "https://x.example", publish: false)
            XCTFail("expected unpublishFailed")
        } catch let e as CourseSessionError {
            XCTAssertEqual(e, .unpublishFailed("module item", 5))
        } catch { XCTFail("\(error)") }
    }

    /// A 200 without a usable id must not lock the tab unpinned.
    func testProbeWithoutAnIntegerIDSkipsTheTab() async {
        let runner = FakeScriptRunner(tabTable: tabs)
        runner.responses["1/1/GET"] = FakeScriptRunner.envelope(status: 200, text: #"{"id":"42"}"#)
        runner.responses["1/2/GET"] = FakeScriptRunner.envelope(status: 200, text: #"{"name":"x"}"#)
        let transport = SafariSessionTransport(runner: runner)
        do {
            _ = try await transport.send(method: "GET", path: "courses", query: [:], jsonBody: nil)
            XCTFail("expected noSafariSession")
        } catch let e as CanvasTransportError {
            guard case .noSafariSession = e else { return XCTFail("\(e)") }
        } catch { XCTFail("\(error)") }
        XCTAssertNil(transport.pinnedUserID)
    }

    /// Same tab, different account: writes re-check the owner inside the one script.
    func testWriteScriptChecksTheOwnerBeforeSending() {
        let js = SafariSessionTransport.javascript(method: "PUT", sameOriginPath: "/api/v1/x", jsonBody: Data("{}".utf8),
                                                   origin: "https://cool.ntu.edu.tw", expectedUserID: 42)
        let who = js.range(of: "/api/v1/users/self")
        let open = js.range(of: #"x.open("PUT""#)
        XCTAssertNotNil(who); XCTAssertNotNil(open)
        XCTAssertLessThan(who!.lowerBound, open!.lowerBound)
        XCTAssertNil(SafariSessionTransport.javascript(method: "GET", sameOriginPath: "/api/v1/x", jsonBody: nil,
                                                        origin: "https://cool.ntu.edu.tw", expectedUserID: 42)
            .range(of: "/api/v1/users/self"), "reads skip the extra round trip")
    }

    func testWrongOwnerEnvelopeIsAnIdentityMismatchNotAReprobe() {
        let raw = FakeScriptRunner.envelope(status: -2, text: #"{"id":999,"name":"Other"}"#)
        XCTAssertThrowsError(try SafariSessionTransport.parseEnvelope(raw, expectedUserID: 42)) {
            XCTAssertEqual($0 as? CanvasTransportError, .identityMismatch(expected: 42, actual: 999, name: "Other"))
        }
    }

    func testCSVQuotesCRLF() {
        XCTAssertEqual(CSV.field("a\r\nb"), "\"a\r\nb\"")
    }

    func testTrailingSlashBaseStillAcceptsItsOwnPages() {
        let base = URL(string: "https://cool.ntu.edu.tw/api/v1/")!
        XCTAssertNoThrow(try CanvasURL.checkedResolve(path: "https://cool.ntu.edu.tw/api/v1/courses?page=2", query: [:], base: base))
        XCTAssertThrowsError(try CanvasURL.checkedResolve(path: "https://cool.ntu.edu.tw/api/v10/x", query: [:], base: base))
    }

    func testStateBackfillsWhenItemsIsEmptyButCountIsNot() async throws {
        let t = RecordingTransport { _, p in
            switch p {
            case "courses/1/modules": return (200, #"[{"id":900,"items_count":1,"items":[]}]"#)
            case "courses/1/modules/900/items": return (200, #"[{"id":1}]"#)
            default: return (200, "[]")
            }
        }
        let state = try await CourseSession(client: CanvasAPIClient(transport: t), config: config, gate: { _ in }).state()
        XCTAssertEqual(((state["modules"] as! [[String: Any]])[0]["items"] as? [[String: Any]])?.count, 1)
    }
}

/// idd-verify round 3 findings on #1.
final class VerifyRound3Tests: XCTestCase {
    private let tabs = "1\t1\t1\thttps://cool.ntu.edu.tw/\n1\t2\t0\thttps://cool.ntu.edu.tw/courses/1\n"

    /// The script is built after the tab is chosen and the owner pinned, so
    /// even a write that is the very first call carries the owner check.
    func testFirstCallWriteCarriesTheOwnerCheck() async throws {
        let runner = FakeScriptRunner(tabTable: tabs)
        runner.responses["1/1/GET"] = FakeScriptRunner.envelope(status: 200, text: #"{"id":42}"#)
        runner.responses["1/1/PUT"] = FakeScriptRunner.envelope(status: 200, text: "{}")
        let transport = SafariSessionTransport(runner: runner)
        _ = try await transport.send(method: "PUT", path: "courses/1/quizzes/2", query: [:], jsonBody: Data("{}".utf8))
        let put = try XCTUnwrap(runner.jsCalls.last)
        XCTAssertTrue(put.contains(#"x.open(\"PUT\""#))
        XCTAssertTrue(put.contains("wo.id!==42"), "owner check with the pinned id")
    }

    /// After a write finds another account in the tab, stop using that tab.
    func testIdentityMismatchUnlocksTheTab() async throws {
        let runner = FakeScriptRunner(tabTable: tabs)
        runner.responses["1/1/GET"] = FakeScriptRunner.envelope(status: 200, text: #"{"id":42}"#)
        let transport = SafariSessionTransport(runner: runner)
        _ = try await transport.send(method: "GET", path: "users/self", query: [:], jsonBody: nil)
        XCTAssertNotNil(transport.lockedTab)
        runner.responses["1/1/PUT"] = FakeScriptRunner.envelope(status: -2, text: #"{"id":999}"#)
        do {
            _ = try await transport.send(method: "PUT", path: "x", query: [:], jsonBody: Data("{}".utf8))
            XCTFail("expected identityMismatch")
        } catch let e as CanvasTransportError {
            XCTAssertEqual(e, .identityMismatch(expected: 42, actual: 999, name: nil))
        }
        XCTAssertNil(transport.lockedTab, "a tab proven to be someone else's is not reused")
    }
}
