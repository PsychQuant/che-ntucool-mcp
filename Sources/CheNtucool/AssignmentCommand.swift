import ArgumentParser
import CheNtucoolCore
import Foundation

struct AssignmentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assignment", abstract: "作業：群組、列出、建立（未發布）、改設定。",
        subcommands: [Groups.self, List.self, Create.self, Set.self])

    struct Groups: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "列出作業群組與權重。")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let groups = try await global.session().assignmentGroups()
            if global.json { return Output.json(groups) }
            for g in groups { print("\(g["id"] ?? "?")\t\(Output.name(g))\t\(g["group_weight"] ?? "")") }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "列出作業。")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let session = try global.session()
            let items = try await session.assignments()
            if global.json { return Output.json(items) }
            for a in items {
                let due = TimeInput.display(a["due_at"] as? String, offset: session.config.timezone)
                print("\(a["id"] ?? "?")\t\(Output.name(a))\t\(Output.pub(a))\t\(a["points_possible"] ?? "")\t\(due)")
            }
        }
    }

    /// Shared fields for create/set.
    struct Fields: ParsableArguments {
        @Option(help: "滿分") var points: Double?
        @Option(help: "開放時間") var unlock: String?
        @Option(help: "截止時間") var due: String?
        @Option(help: "關閉時間") var lock: String?
        @Option(help: "作業群組 id") var groupID: Int?
        @Option(help: "繳交方式，逗號分隔（如 online_text_entry）") var submissionTypes: String?
        @Option(help: "說明（markdown 檔，轉成 HTML）") var descriptionFile: String?

        func dictionary(offset: String) throws -> [String: Any] {
            var d: [String: Any] = [:]
            if let points { d["points_possible"] = points }
            if let v = try normalizedTime(unlock, offset: offset) { d["unlock_at"] = v }
            if let v = try normalizedTime(due, offset: offset) { d["due_at"] = v }
            if let v = try normalizedTime(lock, offset: offset) { d["lock_at"] = v }
            if let groupID { d["assignment_group_id"] = groupID }
            if let submissionTypes { d["submission_types"] = submissionTypes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            if let descriptionFile { d["description"] = Markdown.blocks(try readFile(descriptionFile)) }
            return d
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "建立作業（一律未發布；--week 則放進該週模組）。")
        @OptionGroup var global: GlobalOptions
        @Option(help: "作業名稱") var name: String
        @Option(help: "週次，如 W03") var week: String?
        @OptionGroup var fields: Fields

        func run() async throws {
            let session = try global.session()
            var d = try fields.dictionary(offset: session.config.timezone)
            d["name"] = name
            let id = try await session.createAssignment(fields: d, week: week)
            global.json ? Output.json(["assignment_id": id]) : print("作業 \(id) 已建立（未發布）")
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "改作業設定。已發布的作業改任何欄位都走發布閘。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "作業 id") var assignment: Int
        @Option(help: "新名稱") var name: String?
        @Option(help: "true / false") var published: Bool?
        @OptionGroup var fields: Fields

        func run() async throws {
            let session = try global.session()
            var d = try fields.dictionary(offset: session.config.timezone)
            if let name { d["name"] = name }
            if let published { d["published"] = published }
            guard !d.isEmpty else { throw ValidationError("沒有要改的欄位") }
            try await session.setAssignment(id: assignment, fields: d)
            print("作業 \(assignment) 已更新")
        }
    }
}
