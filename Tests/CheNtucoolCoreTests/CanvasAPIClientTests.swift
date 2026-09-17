import XCTest
@testable import CheNtucoolCore

final class CanvasAPIClientTests: XCTestCase {
    func testCourseDecodingIgnoresUnknownFields() throws {
        let json = """
        {
            "id": 64652,
            "name": "普通心理學 General Psychology",
            "course_code": "普通心理學 (PSY1007-13)",
            "workflow_state": "available",
            "enrollment_term_id": 46,
            "unrelated_field_canvas_might_add_later": "ignored"
        }
        """.data(using: .utf8)!

        let course = try JSONDecoder().decode(CanvasCourse.self, from: json)
        XCTAssertEqual(course.id, 64652)
        XCTAssertEqual(course.workflowState, "available")
    }

    func testSubmissionDecodingHandlesNullScoreAndGrade() throws {
        let json = """
        {
            "id": 1,
            "user_id": 2,
            "assignment_id": 3,
            "submitted_at": null,
            "score": null,
            "grade": null,
            "workflow_state": "unsubmitted"
        }
        """.data(using: .utf8)!

        let submission = try JSONDecoder().decode(CanvasSubmission.self, from: json)
        XCTAssertNil(submission.score)
        XCTAssertNil(submission.grade)
        XCTAssertEqual(submission.workflowState, "unsubmitted")
    }
}
