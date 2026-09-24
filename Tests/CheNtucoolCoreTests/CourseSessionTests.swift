import XCTest
@testable import CheNtucoolCore

/// Transport that answers by route and records every request with its body.
final class RecordingTransport: CanvasTransport, @unchecked Sendable {
    struct Call { let method: String; let path: String; let query: [String: String]; let body: Any? }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    private let route: (String, String) -> (Int, String)

    init(route: @escaping (_ method: String, _ path: String) -> (Int, String)) { self.route = route }

    func send(method: String, path: String, query: [String: String], jsonBody: Data?) async throws -> CanvasResponse {
        let body = jsonBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        lock.withLock { calls.append(Call(method: method, path: path, query: query, body: body)) }
        let (status, text) = route(method, path)
        return CanvasResponse(status: status, body: Data(text.utf8), link: nil)
    }

    var writes: [Call] { calls.filter { $0.method != "GET" } }
}

final class CourseSessionTests: XCTestCase {
    private let config = CourseConfig(
        courseId: 64652, modules: ["W03": 900], timezone: "+08:00",
        quizOptionSets: ["nine": QuizMarkdownTests.nine]
    )

    private func session(_ t: RecordingTransport, gate: @escaping CourseSession.Gate) -> CourseSession {
        CourseSession(client: CanvasAPIClient(transport: t), config: config, gate: gate)
    }

    func testWeekLabelsResolveToModuleIDs() throws {
        let s = session(RecordingTransport { _, _ in (200, "[]") }, gate: { _ in })
        XCTAssertEqual(try s.moduleID(week: "W03"), 900)
        XCTAssertEqual(try s.moduleID(week: "3"), 900)
        XCTAssertEqual(try s.moduleID(week: "03"), 900)
        XCTAssertThrowsError(try s.moduleID(week: "W09"))
    }

    func testAddURLCreatesUnpublishedAndDoesNotAskTheGate() async throws {
        let t = RecordingTransport { m, p in
            if m == "GET" { return (200, "[]") }
            return (200, #"{"id":5,"type":"ExternalUrl","published":false}"#)
        }
        var asked: [WriteRequest] = []
        let s = session(t, gate: { asked.append($0) })
        _ = try await s.addURL(week: "W03", title: "投影片", url: "https://slides.example/w03", publish: false)
        XCTAssertEqual(t.writes.map(\.method), ["POST"])
        XCTAssertEqual(t.writes[0].path, "courses/64652/modules/900/items")
        XCTAssertFalse(PublishGate.isStudentVisible(t.writes[0].body!))
        XCTAssertTrue(asked.allSatisfy { !$0.visible })
    }

    func testAddURLWithPublishRoutesThePublishThroughTheGate() async throws {
        let t = RecordingTransport { m, _ in m == "GET" ? (200, "[]") : (200, #"{"id":5}"#) }
        struct Refused: Error {}
        let s = session(t, gate: { if $0.visible { throw Refused() } })
        do {
            _ = try await s.addURL(week: "W03", title: "投影片", url: "https://slides.example/w03", publish: true)
            XCTFail("expected the gate to refuse")
        } catch is Refused {}
        // The item was created (unpublished) but the publishing PUT never went out.
        XCTAssertEqual(t.writes.map(\.method), ["POST"])
    }

    func testEditingAPublishedQuizIsStudentVisibleEvenWithoutPublishedInBody() async throws {
        let t = RecordingTransport { m, p in
            if m == "GET" && p == "courses/64652/quizzes/7" { return (200, #"{"id":7,"title":"Q","published":true}"#) }
            return (200, #"{"id":7}"#)
        }
        var seen: [WriteRequest] = []
        let s = session(t, gate: { seen.append($0) })
        try await s.setQuiz(id: 7, fields: ["time_limit": 20])
        XCTAssertEqual(seen.count, 1)
        XCTAssertTrue(seen[0].visible, "a published quiz's settings are student-visible")
        XCTAssertTrue(seen[0].preview.contains("time_limit"))
    }

    func testEditingAnUnpublishedQuizIsNotVisible() async throws {
        let t = RecordingTransport { m, p in
            m == "GET" ? (200, #"{"id":7,"title":"Q","published":false}"#) : (200, #"{"id":7}"#)
        }
        var seen: [WriteRequest] = []
        let s = session(t, gate: { seen.append($0) })
        try await s.setQuiz(id: 7, fields: ["time_limit": 20])
        XCTAssertEqual(seen.map(\.visible), [false])
    }

    func testQuizBuildRefusesDuplicateTitle() async {
        let t = RecordingTransport { _, p in p.hasSuffix("/quizzes") ? (200, #"[{"id":1,"title":"第三週"}]"#) : (200, "[]") }
        let s = session(t, gate: { _ in })
        let spec = QuizBuildSpec(markdown: QuizMarkdownTests.sample, week: "W03", title: "第三週", quizType: "assignment",
                                 unlock: nil, due: nil, lock: nil, timeLimit: 15, pointsEach: 0.2,
                                 assignmentGroup: nil, optionSet: "nine")
        do { _ = try await s.buildQuiz(spec); XCTFail("expected duplicate refusal") }
        catch let e as CourseSessionError { XCTAssertEqual(e, .alreadyExists("quiz", 1)) }
        catch { XCTFail("\(error)") }
        XCTAssertTrue(t.writes.isEmpty)
    }

    func testQuizBuildCreatesUnpublishedQuizQuestionsAndModuleItem() async throws {
        let t = RecordingTransport { m, p in
            if m == "GET" { return (200, p.hasSuffix("assignment_groups") ? #"[{"id":33,"name":"隨堂測驗"}]"# : "[]") }
            if p == "courses/64652/quizzes" { return (200, #"{"id":77}"#) }
            return (200, #"{"id":1}"#)
        }
        var seen: [WriteRequest] = []
        let s = session(t, gate: { seen.append($0) })
        let spec = QuizBuildSpec(markdown: QuizMarkdownTests.sample, week: "W03", title: "第三週隨堂測驗", quizType: "assignment",
                                 unlock: "2026-09-30T11:40:00+08:00", due: "2026-09-30T11:55:00+08:00", lock: nil,
                                 timeLimit: 15, pointsEach: 0.2, assignmentGroup: "隨堂測驗", optionSet: "nine")
        let id = try await s.buildQuiz(spec)
        XCTAssertEqual(id, 77)
        XCTAssertTrue(seen.allSatisfy { !$0.visible }, "building never publishes")

        let quizBody = t.writes[0].body as! [String: Any]
        let quiz = quizBody["quiz"] as! [String: Any]
        XCTAssertEqual(quiz["published"] as? Bool, false)
        XCTAssertEqual(quiz["assignment_group_id"] as? Int, 33)
        XCTAssertEqual(quiz["points_possible"] as? Double, 0.4)
        XCTAssertEqual(quiz["lock_at"] as? String, "2026-09-30T11:55:00+08:00", "lock defaults to due")

        let questionPosts = t.writes.filter { $0.path == "courses/64652/quizzes/77/questions" }
        XCTAssertEqual(questionPosts.count, 2)
        let q2 = (questionPosts[1].body as! [String: Any])["question"] as! [String: Any]
        let weights = (q2["answers"] as! [[String: Any]]).map { $0["answer_weight"] as! Int }
        XCTAssertEqual(weights.filter { $0 == 100 }.count, 2)

        let item = t.writes.last!
        XCTAssertEqual(item.path, "courses/64652/modules/900/items")
        XCTAssertFalse(PublishGate.isStudentVisible(item.body!))
    }

    func testAnnouncementPostAndEditAreAlwaysVisible() async throws {
        let t = RecordingTransport { _, _ in (200, #"{"id":9,"title":"t"}"#) }
        var seen: [WriteRequest] = []
        let s = session(t, gate: { seen.append($0) })
        let file = try AnnouncementFile.parse(AnnouncementFileTests.sample)
        _ = try await s.postAnnouncement(file)
        try await s.editAnnouncement(id: 9, file)
        XCTAssertEqual(seen.map(\.visible), [true, true])
        XCTAssertTrue(seen[0].preview.contains("第三週：應用作業格式"))
        XCTAssertTrue(seen[0].preview.contains("照模板"))
        XCTAssertFalse(seen[0].preview.contains("不要貼"))
    }

    func testEnrollmentCountsActiveStudentsByType() async throws {
        let t = RecordingTransport { _, _ in (200, #"""
        [{"id":1,"type":"StudentEnrollment","enrollment_state":"active"},
         {"id":2,"type":"StudentEnrollment","enrollment_state":"active"},
         {"id":3,"type":"StudentEnrollment","enrollment_state":"invited"},
         {"id":4,"type":"TeacherEnrollment","enrollment_state":"active"},
         {"id":5,"type":"TaEnrollment","enrollment_state":"active"}]
        """#) }
        let counts = try await session(t, gate: { _ in }).enrollmentCounts()
        XCTAssertEqual(counts, EnrollmentCounts(students: 2, studentsInvited: 1, teachers: 1, tas: 1))
    }
}
