import XCTest
@testable import CheNtucoolMCP

/// Tests for the payload-binding half of the write gate.
///
/// The elicitation half cannot be unit-tested here — it needs a live MCP client
/// to answer the dialog — so these cover the part that *is* testable in
/// isolation: that a token cannot be reused, cannot outlive its window, and
/// cannot be redeemed against a payload other than the one a human saw.
final class WriteGateTests: XCTestCase {

    private func grades(_ pairs: [(Int, String)], course: Int = 1, assignment: Int = 2) -> WritePayload {
        .grades(
            courseId: course,
            assignmentId: assignment,
            entries: pairs.map { GradeEntry(userId: $0.0, grade: $0.1) }
        )
    }

    // MARK: - Canonicalization

    func testGradeOrderDoesNotChangeHash() {
        // The same three grades listed in a different order are the same write;
        // forcing a re-preview over argument order would be noise.
        let a = grades([(1, "85"), (2, "90"), (3, "78")])
        let b = grades([(3, "78"), (1, "85"), (2, "90")])
        XCTAssertEqual(a.payloadHash, b.payloadHash)
    }

    func testDifferentGradeChangesHash() {
        let a = grades([(1, "85")])
        let b = grades([(1, "87")])
        XCTAssertNotEqual(a.payloadHash, b.payloadHash)
    }

    func testDifferentAssignmentChangesHash() {
        let a = grades([(1, "85")], assignment: 2)
        let b = grades([(1, "85")], assignment: 3)
        XCTAssertNotEqual(a.payloadHash, b.payloadHash)
    }

    func testDelimiterInFreeTextCannotForgeACollision() {
        // Without length-prefixing, a title able to contain the field separator
        // could make two distinct announcements canonicalize identically. This
        // is the payload equivalent of SQL injection, so it is pinned.
        let a = WritePayload.announcement(courseId: 1, title: "A|10:B", message: "C")
        let b = WritePayload.announcement(courseId: 1, title: "A", message: "10:B|C")
        XCTAssertNotEqual(a.payloadHash, b.payloadHash)
    }

    // MARK: - Token lifecycle

    func testValidTokenRedeemsOnce() async throws {
        let gate = WriteGate()
        let payload = grades([(1, "85")])
        let token = await gate.issue(for: payload, preview: "PREVIEW TEXT")

        let preview = try await gate.consume(token: token, payload: payload)
        XCTAssertEqual(preview, "PREVIEW TEXT")

        // Replay must fail — otherwise one approval could authorise N writes.
        do {
            _ = try await gate.consume(token: token, payload: payload)
            XCTFail("expected replay to be refused")
        } catch WriteGateError.unknownOrExpiredToken {
            // expected
        }
    }

    func testUnknownTokenIsRefused() async {
        let gate = WriteGate()
        do {
            _ = try await gate.consume(token: "made-up", payload: grades([(1, "85")]))
            XCTFail("expected refusal")
        } catch WriteGateError.unknownOrExpiredToken {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// The headline case: a human approved 85/92/78, and 87 shows up instead.
    func testPayloadDriftIsRefused() async {
        let gate = WriteGate()
        let previewed = grades([(1, "85"), (2, "92"), (3, "78")])
        let drifted = grades([(1, "85"), (2, "92"), (3, "87")])
        let token = await gate.issue(for: previewed, preview: "PREVIEW")

        do {
            _ = try await gate.consume(token: token, payload: drifted)
            XCTFail("expected drifted payload to be refused")
        } catch WriteGateError.payloadMismatch {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// A mismatch burns the token, so the corrected payload cannot ride in on
    /// the approval the human gave to the original one.
    func testDriftConsumesTheTokenSoTheCorrectionMustBeRepreviewed() async throws {
        let gate = WriteGate()
        let previewed = grades([(1, "85")])
        let drifted = grades([(1, "87")])
        let token = await gate.issue(for: previewed, preview: "PREVIEW")

        _ = try? await gate.consume(token: token, payload: drifted)

        // Even the ORIGINAL, correctly-previewed payload can no longer use it.
        do {
            _ = try await gate.consume(token: token, payload: previewed)
            XCTFail("expected the token to have been burned by the mismatch")
        } catch WriteGateError.unknownOrExpiredToken {
            // expected
        }
    }

    func testExpiredTokenIsRefused() async {
        let gate = WriteGate(ttl: 600)
        let payload = grades([(1, "85")])
        let token = await gate.issue(for: payload, preview: "PREVIEW", now: Date())

        // Redeem 11 minutes later.
        let later = Date().addingTimeInterval(660)
        do {
            _ = try await gate.consume(token: token, payload: payload, now: later)
            XCTFail("expected expiry")
        } catch WriteGateError.unknownOrExpiredToken {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTokensAreDistinctPerIssue() async {
        let gate = WriteGate()
        let payload = grades([(1, "85")])
        let t1 = await gate.issue(for: payload, preview: "P")
        let t2 = await gate.issue(for: payload, preview: "P")
        XCTAssertNotEqual(t1, t2, "identical payloads must still get distinct tokens")
    }

    func testCrossPayloadTypeIsRefused() async {
        // A grades token must not redeem an announcement.
        let gate = WriteGate()
        let token = await gate.issue(for: grades([(1, "85")]), preview: "P")
        do {
            _ = try await gate.consume(
                token: token,
                payload: .announcement(courseId: 1, title: "t", message: "m")
            )
            XCTFail("expected refusal")
        } catch WriteGateError.payloadMismatch {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

final class ForesayRenderingTests: XCTestCase {

    func testConfirmationCarriesScopeAndIrreversibility() {
        let out = Foresay.operationConfirmation(
            action: "post_grades",
            target: "普通心理學 [PSY1007-13]",
            parameters: ["assignment: 期中考 (id 12345)"],
            scope: "3 students",
            irreversibleBecause: "students are notified immediately",
            residue: "whether these are the right scores"
        )
        XCTAssertTrue(out.contains("I will perform:"))
        XCTAssertTrue(out.contains("3 students"))
        XCTAssertTrue(out.contains("cannot be undone"))
        XCTAssertTrue(out.contains("Not operationalized"))
        XCTAssertTrue(out.hasSuffix("Proceed?"))
    }

    func testConfirmationOmitsIrreversibilityWhenRecoverable() {
        // A manual-posting assignment genuinely is recoverable; crying wolf
        // there would erode the warning where it matters.
        let out = Foresay.operationConfirmation(
            action: "post_grades",
            target: "course",
            parameters: [],
            scope: "1 student",
            irreversibleBecause: nil,
            residue: nil
        )
        XCTAssertFalse(out.contains("cannot be undone"))
        XCTAssertFalse(out.contains("Not operationalized"))
    }

    func testReportStatesActualNotEstimatedScope() {
        let out = Foresay.operationReport(
            action: "post_grades",
            target: "course 1, assignment 2",
            scope: "2 of 3 students",
            residue: nil
        )
        XCTAssertTrue(out.hasPrefix("Done:"))
        XCTAssertTrue(out.contains("2 of 3 students"))
    }
}
