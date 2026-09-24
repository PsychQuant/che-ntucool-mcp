import Foundation

public enum QuizMarkdownError: Error, LocalizedError, Equatable {
    case missingSection(String)
    case missingAnswer(question: Int)
    case answerMatchesNoOption(answer: String)

    public var errorDescription: String? {
        switch self {
        case .missingSection(let s): return "測驗檔缺少「\(s)」段"
        case .missingAnswer(let n): return "第 \(n) 題在「答案與講解」表裡沒有答案"
        case .answerMatchesNoOption(let a): return "答案「\(a)」對不到任何選項（選項組在 ntucool.json 的 quiz_option_sets）"
        }
    }
}

/// A course quiz file (`W<NN>/測驗.md`), in the format `cool_build.py`'s
/// `parse_quiz` reads:
///
/// * `## 給學生的說明…` — quiz description, up to the next `---` or `##`.
/// * `## 題目` — items opening `**N.** stem`; following `> ` lines are
///   references (HTML comments stripped); `---` ends the section.
/// * `## 答案與講解…` — a table whose rows start `| N | **answer** |`.
public struct QuizMarkdown: Equatable, Sendable {
    public struct Question: Equatable, Sendable {
        public let number: Int
        public let html: String
        public let answer: String
    }

    public struct Choice: Equatable, Sendable {
        public let text: String
        public let weight: Int
    }

    public let descriptionHTML: String
    public let questions: [Question]

    private static let item = try! NSRegularExpression(pattern: #"(?m)^\*\*(\d+)\.\*\* "#)
    private static let answerRow = try! NSRegularExpression(pattern: #"(?m)^\| (\d+) \| \*\*(.*?)\*\*"#)
    private static let comment = try! NSRegularExpression(pattern: #"\s*<!--.*?-->"#)
    private static let circled = Array("①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳")

    public static func parse(_ source: String) throws -> QuizMarkdown {
        let description = section(source, startingWith: "## 給學生的說明").map { Markdown.blocks($0) } ?? ""
        guard let body = section(source, startingWith: "## 題目") else { throw QuizMarkdownError.missingSection("## 題目") }
        guard let answersText = section(source, startingWith: "## 答案與講解", stopAtRule: false) else {
            throw QuizMarkdownError.missingSection("## 答案與講解")
        }

        var answers: [Int: String] = [:]
        for m in answerRow.matches(in: answersText, range: NSRange(answersText.startIndex..., in: answersText)) {
            if let n = Int(string(answersText, m.range(at: 1))) { answers[n] = string(answersText, m.range(at: 2)) }
        }

        let matches = item.matches(in: body, range: NSRange(body.startIndex..., in: body))
        var questions: [Question] = []
        for (i, m) in matches.enumerated() {
            let number = Int(string(body, m.range(at: 1)))!
            let start = m.range.location + m.range.length
            let end = i + 1 < matches.count ? matches[i + 1].range.location : (body as NSString).length
            let chunk = (body as NSString).substring(with: NSRange(location: start, length: end - start))
            let lines = chunk.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let stem = lines.first else { continue }
            var html = "<p>\(Markdown.inline(stem))</p>"
            for ref in lines.dropFirst() where ref.hasPrefix("> ") {
                let text = String(ref.dropFirst(2))
                let clean = comment.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                html += #"<p style="font-size:.9em;color:#555;margin-left:1.5em;text-indent:-1.5em">\#(Markdown.inline(clean))</p>"#
            }
            guard let answer = answers[number] else { throw QuizMarkdownError.missingAnswer(question: number) }
            questions.append(Question(number: number, html: html, answer: answer))
        }
        return QuizMarkdown(descriptionHTML: description, questions: questions)
    }

    /// Canvas answers for one multiple-choice question. `answer` is either the
    /// full text of one option or a set of circled numbers (`④、⑦`); every
    /// option it names gets weight 100 — the course's "any defensible answer
    /// scores" rule.
    public static func answerWeights(answer: String, options: [String]) throws -> [Choice] {
        if options.contains(answer) {
            return options.map { Choice(text: $0, weight: $0 == answer ? 100 : 0) }
        }
        let hits = Set(answer.filter { circled.contains($0) })
        let optionMarks = Set(options.compactMap(\.first))
        guard !hits.isEmpty, hits.isSubset(of: optionMarks) else {
            throw QuizMarkdownError.answerMatchesNoOption(answer: answer)
        }
        return options.map { Choice(text: $0, weight: $0.first.map(hits.contains) == true ? 100 : 0) }
    }

    // MARK: Helpers

    /// Text after the line beginning `heading`, up to the next `## ` heading
    /// (and, when `stopAtRule`, a `---` rule).
    static func section(_ source: String, startingWith heading: String, stopAtRule: Bool = true) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix(heading) }) else { return nil }
        var out: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("## ") || (stopAtRule && line.trimmingCharacters(in: .whitespaces) == "---") { break }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func string(_ s: String, _ r: NSRange) -> String { (s as NSString).substring(with: r) }
}
