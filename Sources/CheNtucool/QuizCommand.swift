import ArgumentParser
import CheNtucoolCore
import Foundation

struct QuizCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quiz", abstract: "測驗：列出、從 md 建置、更新單題、改設定。",
        subcommands: [List.self, Build.self, UpdateQuestion.self, Set.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "列出測驗。")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let session = try global.session()
            let quizzes = try await session.quizzes()
            if global.json { return Output.json(quizzes) }
            for q in quizzes {
                let due = TimeInput.display(q["due_at"] as? String, offset: session.config.timezone)
                print("\(q["id"] ?? "?")\t\(Output.name(q))\t\(Output.pub(q))\t\(q["quiz_type"] ?? "")\t\(due)")
            }
        }
    }

    struct Build: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "從測驗 md 建立測驗（未發布）與題目，放進該週模組。",
            discussion: "md 格式同課程 repo 的 W<NN>/測驗.md。答案要對得到 --options 指定的選項組（ntucool.json 的 quiz_option_sets）。")

        @OptionGroup var global: GlobalOptions
        @Option(help: "測驗 md 檔") var file: String
        @Option(help: "週次，如 W03") var week: String
        @Option(help: "測驗標題") var title: String
        @Option(help: "選項組名稱（quiz_option_sets 的 key）") var options: String
        @Option(help: "quiz_type：assignment / practice_quiz / graded_survey / survey") var type: String = "assignment"
        @Option(help: "開放時間（無時區則用設定檔時區）") var unlock: String?
        @Option(help: "截止時間") var due: String?
        @Option(help: "關閉時間（預設同截止）") var lock: String?
        @Option(help: "作答時間上限（分）") var timeLimit: Int?
        @Option(help: "每題分數") var pointsEach: Double = 0.2
        @Option(help: "作業群組名稱（如 隨堂測驗）") var group: String?
        @Flag(help: "只解析與核對答案，不連 COOL") var dryRun = false

        func run() async throws {
            let config = try global.loadConfig()
            let markdown = try readFile(file)
            let offset = config.timezone
            let spec = QuizBuildSpec(
                markdown: markdown, week: week, title: title, quizType: type,
                unlock: try normalizedTime(unlock, offset: offset), due: try normalizedTime(due, offset: offset),
                lock: try normalizedTime(lock, offset: offset), timeLimit: timeLimit, pointsEach: pointsEach,
                assignmentGroup: group, optionSet: options)
            if dryRun { return try Self.dryRun(spec, config: config, json: global.json) }
            let id = try await global.session().buildQuiz(spec)
            global.json ? Output.json(["quiz_id": id]) : print("測驗 \(id) 已建立（未發布）：https://cool.ntu.edu.tw/courses/\(config.courseId)/quizzes/\(id)")
        }

        static func dryRun(_ spec: QuizBuildSpec, config: CourseConfig, json: Bool) throws {
            guard let options = config.quizOptionSets?[spec.optionSet] else {
                throw CourseSessionError.unknownOptionSet(spec.optionSet, known: Array((config.quizOptionSets ?? [:]).keys))
            }
            let parsed = try QuizMarkdown.parse(spec.markdown)
            var rows: [[String: Any]] = []
            for q in parsed.questions {
                let correct = try QuizMarkdown.answerWeights(answer: q.answer, options: options).filter { $0.weight == 100 }.map(\.text)
                rows.append(["number": q.number, "answer": q.answer, "correct_options": correct])
            }
            let total = (spec.pointsEach * Double(parsed.questions.count) * 100).rounded() / 100
            if json {
                return Output.json(["title": spec.title, "questions": rows, "points_possible": total,
                                    "unlock_at": spec.unlock ?? NSNull(), "due_at": spec.due ?? NSNull()])
            }
            print("「\(spec.title)」\(parsed.questions.count) 題，共 \(total) 分；開放 \(spec.unlock ?? "—")，截止 \(spec.due ?? "—")")
            for r in rows { print("  \(r["number"]!)\t\(r["answer"]!)") }
        }
    }

    struct UpdateQuestion: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update-question", abstract: "用 md 裡第 N 題覆寫測驗上的同一題（題幹與答案）。")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "測驗 id") var quiz: Int
        @Argument(help: "題號") var number: Int
        @Option(help: "測驗 md 檔") var file: String
        @Option(help: "選項組名稱") var options: String
        @Option(help: "每題分數") var pointsEach: Double = 0.2

        func run() async throws {
            try await global.session().updateQuestion(quizID: quiz, number: number, markdown: try readFile(file),
                                                      optionSet: options, pointsEach: pointsEach)
            print("第 \(number) 題已更新")
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "改測驗設定。已發布的測驗改任何欄位都算學生可見，走發布閘。")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "測驗 id") var quiz: Int
        @Option(help: "開放時間") var unlock: String?
        @Option(help: "截止時間") var due: String?
        @Option(help: "關閉時間") var lock: String?
        @Option(help: "作答時間上限（分）") var timeLimit: Int?
        @Option(help: "quiz_type") var type: String?
        @Option(help: "總分") var points: Double?
        @Option(help: "作業群組 id") var groupID: Int?
        @Option(help: "true / false") var published: Bool?

        func run() async throws {
            let session = try global.session()
            let offset = session.config.timezone
            var fields: [String: Any] = [:]
            if let v = try normalizedTime(unlock, offset: offset) { fields["unlock_at"] = v }
            if let v = try normalizedTime(due, offset: offset) { fields["due_at"] = v }
            if let v = try normalizedTime(lock, offset: offset) { fields["lock_at"] = v }
            if let timeLimit { fields["time_limit"] = timeLimit }
            if let type { fields["quiz_type"] = type }
            if let points { fields["points_possible"] = points }
            if let groupID { fields["assignment_group_id"] = groupID }
            if let published { fields["published"] = published }
            guard !fields.isEmpty else { throw ValidationError("沒有要改的欄位") }
            try await session.setQuiz(id: quiz, fields: fields)
            print("測驗 \(quiz) 已更新")
        }
    }
}
