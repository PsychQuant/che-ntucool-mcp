import XCTest
import ArgumentParser
@testable import che_ntucool
@testable import CheNtucoolCore

final class ConsoleGateTests: XCTestCase {
    private func request(visible: Bool) -> WriteRequest {
        WriteRequest(method: "PUT", path: "courses/1/quizzes/2", body: ["quiz": ["published": visible]],
                     visible: visible, preview: "發布「第三週」\n{…}")
    }

    func testInvisibleWriteOnlyAnnouncesOneLine() throws {
        var lines: [String] = []
        let gate = ConsoleGate(environment: [:], assumeYes: false, isInteractive: false, readAnswer: { XCTFail(); return nil },
                               err: { lines.append($0) })
        try gate.check(request(visible: false))
        XCTAssertEqual(lines, ["→ 發布「第三週」"])
    }

    func testVisibleWithoutEnvironmentIsRefusedEvenWithYes() {
        var lines: [String] = []
        let gate = ConsoleGate(environment: [:], assumeYes: true, isInteractive: true, readAnswer: { "y" }, err: { lines.append($0) })
        XCTAssertThrowsError(try gate.check(request(visible: true))) { XCTAssertEqual($0 as? PublishGateError, .environmentMissing) }
        XCTAssertTrue(lines.joined().contains("學生看得到"), "the preview is shown before refusing")
    }

    func testVisibleNonInteractiveWithoutYesIsRefused() {
        let gate = ConsoleGate(environment: ["COOL_ALLOW_PUBLISH": "1"], assumeYes: false, isInteractive: false,
                               readAnswer: { XCTFail("no TTY"); return nil }, err: { _ in })
        XCTAssertThrowsError(try gate.check(request(visible: true))) { XCTAssertEqual($0 as? PublishGateError, .noConfirmation) }
    }

    func testInteractiveAnswerDecides() throws {
        let env = ["COOL_ALLOW_PUBLISH": "1"]
        try ConsoleGate(environment: env, assumeYes: false, isInteractive: true, readAnswer: { " Y " }, err: { _ in }).check(request(visible: true))
        XCTAssertThrowsError(try ConsoleGate(environment: env, assumeYes: false, isInteractive: true, readAnswer: { "" }, err: { _ in })
            .check(request(visible: true))) { XCTAssertEqual($0 as? PublishGateError, .declined) }
    }
}

final class ArgumentParsingTests: XCTestCase {
    func testQuizBuildParsesAllOptions() throws {
        let cmd = try CheNtucool.parseAsRoot([
            "quiz", "build", "--file", "W03/測驗.md", "--week", "W03", "--title", "第三週隨堂測驗",
            "--options", "nine", "--unlock", "2026-09-30T11:40", "--due", "2026-09-30T11:55",
            "--time-limit", "15", "--group", "隨堂測驗", "--dry-run", "--config", "/tmp/x.json",
        ])
        let build = try XCTUnwrap(cmd as? QuizCommand.Build)
        XCTAssertEqual(build.timeLimit, 15)
        XCTAssertEqual(build.pointsEach, 0.2)
        XCTAssertEqual(build.type, "assignment")
        XCTAssertTrue(build.dryRun)
        XCTAssertEqual(build.global.config, "/tmp/x.json")
    }

    func testQuizSetPublishedTakesABoolean() throws {
        let cmd = try CheNtucool.parseAsRoot(["quiz", "set", "73971", "--published", "false", "--type", "practice_quiz"])
        let set = try XCTUnwrap(cmd as? QuizCommand.Set)
        XCTAssertEqual(set.published, false)
        XCTAssertEqual(set.type, "practice_quiz")
        XCTAssertThrowsError(try CheNtucool.parseAsRoot(["quiz", "set", "1", "--published", "maybe"]))
    }

    func testYesShortFlag() throws {
        let cmd = try CheNtucool.parseAsRoot(["announce", "post", "a.md", "-y"])
        XCTAssertTrue(try XCTUnwrap(cmd as? AnnounceCommand.Post).global.yes)
    }

    func testBadTimeIsAValidationError() {
        XCTAssertThrowsError(try normalizedTime("tomorrow noon", offset: "+08:00")) { XCTAssertTrue($0 is ValidationError) }
        XCTAssertEqual(try normalizedTime("2026-09-30T11:55", offset: "+08:00"), "2026-09-30T11:55:00+08:00")
    }
}

final class DryRunTests: XCTestCase {
    func testDryRunNeedsNoNetworkAndChecksAnswers() throws {
        let config = CourseConfig(courseId: 1, modules: ["W03": 9], quizOptionSets: ["nine": QuizFixture.nine])
        let spec = QuizBuildSpec(markdown: QuizFixture.markdown, week: "W03", title: "t", quizType: "assignment",
                                 unlock: nil, due: nil, lock: nil, timeLimit: nil, pointsEach: 0.2,
                                 assignmentGroup: nil, optionSet: "nine")
        XCTAssertNoThrow(try QuizCommand.Build.dryRun(spec, config: config, json: true))
        var bad = spec
        bad.optionSet = "thirteen"
        XCTAssertThrowsError(try QuizCommand.Build.dryRun(bad, config: config, json: true))
    }
}

enum QuizFixture {
    static let nine = ["①a", "②b", "③c", "④d", "⑤e", "⑥f", "⑦g", "⑧h", "⑨i"]
    static let markdown = """
    ## 題目

    **1.** 題幹一。

    ---

    ## 答案與講解

    | 1 | **⑤** | x |
    """
}
