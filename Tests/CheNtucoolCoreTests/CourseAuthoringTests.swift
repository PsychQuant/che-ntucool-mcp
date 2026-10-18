import XCTest
@testable import CheNtucoolCore

final class PublishGateTests: XCTestCase {
    func testDetectsPublishedTrueAtAnyDepth() {
        XCTAssertTrue(PublishGate.isStudentVisible(["module_item": ["published": true]]))
        XCTAssertTrue(PublishGate.isStudentVisible(["quiz": ["title": "x", "published": true]]))
        XCTAssertTrue(PublishGate.isStudentVisible([["published": true]]))
        XCTAssertTrue(PublishGate.isStudentVisible(["title": "t", "is_announcement": true]))
    }

    func testUnpublishedAndFalseAreNotVisible() {
        XCTAssertFalse(PublishGate.isStudentVisible(["quiz": ["published": false]]))
        XCTAssertFalse(PublishGate.isStudentVisible(["module_item": ["type": "ExternalUrl"]]))
        XCTAssertFalse(PublishGate.isStudentVisible(["published": "true"]), "only the JSON boolean publishes")
    }

    func testInvisibleWriteNeedsNothing() throws {
        try PublishGate.authorize(visible: false, environment: [:], assumeYes: false, confirm: { XCTFail("no prompt"); return false })
    }

    func testVisibleWriteRefusedWithoutEnvironmentEvenWithYes() {
        XCTAssertThrowsError(try PublishGate.authorize(visible: true, environment: [:], assumeYes: true, confirm: { nil })) { error in
            XCTAssertEqual(error as? PublishGateError, .environmentMissing)
        }
    }

    func testVisibleWriteWithEnvironmentNeedsYesOrConfirmation() throws {
        let env = ["COOL_ALLOW_PUBLISH": "1"]
        try PublishGate.authorize(visible: true, environment: env, assumeYes: true, confirm: { XCTFail("--yes skips prompt"); return nil })
        try PublishGate.authorize(visible: true, environment: env, assumeYes: false, confirm: { true })
        XCTAssertThrowsError(try PublishGate.authorize(visible: true, environment: env, assumeYes: false, confirm: { false })) {
            XCTAssertEqual($0 as? PublishGateError, .declined)
        }
        // No TTY to ask on and no --yes: refuse rather than assume.
        XCTAssertThrowsError(try PublishGate.authorize(visible: true, environment: env, assumeYes: false, confirm: { nil })) {
            XCTAssertEqual($0 as? PublishGateError, .noConfirmation)
        }
    }
}

final class TimeInputTests: XCTestCase {
    func testBareTimestampGetsConfiguredOffset() throws {
        XCTAssertEqual(try TimeInput.normalize("2026-09-30T11:55", offset: "+08:00"), "2026-09-30T11:55:00+08:00")
        XCTAssertEqual(try TimeInput.normalize("2026-09-30 11:55:30", offset: "+08:00"), "2026-09-30T11:55:30+08:00")
    }

    func testExplicitOffsetOrZIsKept() throws {
        XCTAssertEqual(try TimeInput.normalize("2026-09-30T03:55:00Z", offset: "+08:00"), "2026-09-30T03:55:00Z")
        XCTAssertEqual(try TimeInput.normalize("2026-09-30T11:55:00+09:00", offset: "+08:00"), "2026-09-30T11:55:00+09:00")
    }

    func testGarbageAndDateOnlyAreRejected() {
        XCTAssertThrowsError(try TimeInput.normalize("next tuesday", offset: "+08:00"))
        XCTAssertThrowsError(try TimeInput.normalize("2026-09-30", offset: "+08:00"), "a date without a time is ambiguous for a deadline")
        XCTAssertThrowsError(try TimeInput.normalize("2026-13-30T11:55", offset: "+08:00"))
    }

    func testCanvasUTCIsRenderedInLocalOffset() {
        XCTAssertEqual(TimeInput.display("2026-09-30T03:55:00Z", offset: "+08:00"), "2026-09-30 11:55 +08:00")
        XCTAssertEqual(TimeInput.display(nil, offset: "+08:00"), "—")
    }
}

final class MarkdownTests: XCTestCase {
    func testInlineEscapesThenFormats() {
        XCTAssertEqual(Markdown.inline("a < b **粗** *斜* https://x.org/y"),
                       #"a &lt; b <strong>粗</strong> <em>斜</em> <a href="https://x.org/y">https://x.org/y</a>"#)
    }

    func testBlocksMakeParagraphsAndLists() {
        let html = Markdown.blocks("第一段\n第一段續\n\n- 甲\n- 乙\n\n最後")
        XCTAssertEqual(html, "<p>第一段<br>第一段續</p><ul><li>甲</li><li>乙</li></ul><p>最後</p>")
    }
}

final class QuizMarkdownTests: XCTestCase {
    static let sample = """
    # 第三週隨堂測驗

    ## 給學生的說明（可直接貼進 NTU COOL）

    - 十二題，每題 0.2 分。
    - **只考當週**。

    ---

    ## 題目

    **1.** 對一群高齡男性的追蹤顯示，嗅覺退化會引發巴金森氏症。Ross et al. (2008) 追蹤 2,267 位。

    > Ross, G. W. (2008). Association of olfactory dysfunction. *Annals of Neurology, 63*(2), 167–173. <!-- note -->

    **2.** 第二題題幹 *p* = .01。

    ---

    ## 答案與講解（不要與題目一起發布）

    | 題 | 答案 | 對應 | 考點 | 講解 |
    |---|---|---|---|---|
    | 1 | **⑤** | deck 55 | x | y |
    | 2 | **④、⑦** | deck 37 | x | y |
    """

    static let nine = ["①【未引用文獻】a", "②【幻覺文獻】b", "③【引文錯誤】c", "④【實務顯著性】d",
                       "⑤【內在效度】e", "⑥【構念效度】f", "⑦【外在效度】g", "⑧【忽略爭議】h", "⑨【無上述問題】i"]

    func testParsesQuestionsReferencesAndAnswers() throws {
        let quiz = try QuizMarkdown.parse(Self.sample)
        XCTAssertEqual(quiz.questions.map(\.number), [1, 2])
        XCTAssertTrue(quiz.questions[0].html.hasPrefix("<p>對一群高齡男性"))
        XCTAssertTrue(quiz.questions[0].html.contains("<em>Annals of Neurology, 63</em>"))
        XCTAssertFalse(quiz.questions[0].html.contains("note"), "HTML comments are stripped from references")
        XCTAssertEqual(quiz.questions[1].answer, "④、⑦")
        XCTAssertTrue(quiz.descriptionHTML.contains("<li><strong>只考當週</strong>。</li>"))
    }

    func testAnswerWeightsForCircledNumberSets() throws {
        let weights = try QuizMarkdown.answerWeights(answer: "④、⑦", options: Self.nine)
        XCTAssertEqual(weights.filter { $0.weight == 100 }.map(\.text), [Self.nine[3], Self.nine[6]])
        XCTAssertEqual(weights.count, 9)
    }

    func testAnswerWeightsForWholeOptionText() throws {
        let weights = try QuizMarkdown.answerWeights(answer: "相關當因果", options: ["幻覺文獻", "相關當因果"])
        XCTAssertEqual(weights.map(\.weight), [0, 100])
    }

    func testAnswerThatMatchesNoOptionIsAnError() {
        XCTAssertThrowsError(try QuizMarkdown.answerWeights(answer: "⑩", options: Self.nine))
    }

    func testMissingAnswerRowIsAnError() {
        let broken = Self.sample.replacingOccurrences(of: "| 2 | **④、⑦** | deck 37 | x | y |", with: "")
        XCTAssertThrowsError(try QuizMarkdown.parse(broken))
    }
}

final class AnnouncementFileTests: XCTestCase {
    static let sample = """
    ---
    status: draft
    ---

    # 第三週：應用作業格式

    ## 寫這則的理由（不貼）

    不要貼這段。

    ## 正文

    各位同學好，

    **一、格式。** 照模板。

    鄭澈

    ## 後續

    - 不貼
    """

    func testTakesTitleAndOnlyTheBodySection() throws {
        let a = try AnnouncementFile.parse(Self.sample)
        XCTAssertEqual(a.title, "第三週：應用作業格式")
        XCTAssertEqual(a.status, "draft")
        XCTAssertEqual(a.bodyMarkdown, "各位同學好，\n\n**一、格式。** 照模板。\n\n鄭澈")
        XCTAssertFalse(a.html.contains("不要貼"))
        XCTAssertFalse(a.html.contains("不貼"))
    }

    func testMissingBodySectionIsAnError() {
        XCTAssertThrowsError(try AnnouncementFile.parse("# 標題\n\n沒有正文段"))
    }
}
