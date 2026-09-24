import ArgumentParser
import CheNtucoolCore
import Foundation

/// Normalize a command-line time with the course offset, as a validation error.
func normalizedTime(_ raw: String?, offset: String) throws -> String? {
    guard let raw else { return nil }
    do { return try TimeInput.normalize(raw, offset: offset) }
    catch { throw ValidationError(error.localizedDescription) }
}

func readFile(_ path: String) throws -> String {
    do { return try String(contentsOfFile: path, encoding: .utf8) }
    catch { throw ValidationError("讀不到檔案 \(path)：\(error.localizedDescription)") }
}

struct StateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "state", abstract: "列出模組與項目、討論、測驗、作業、檔案與發布狀態。")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let session = try global.session()
        let state = try await session.state()
        if global.json { Output.json(state) } else { print(Output.stateText(state, offset: session.config.timezone)) }
    }
}

struct EnrollCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enroll", abstract: "修課人數（active／invited 學生、教師、助教）。")

    @OptionGroup var global: GlobalOptions

    @Option(help: "把一列加到這個 CSV（欄位 date,time,students,students_invited,teachers,tas,note）")
    var appendCSV: String?

    @Option(help: "寫進 CSV 的備註")
    var note: String = ""

    func run() async throws {
        let session = try global.session()
        let c = try await session.enrollmentCounts()
        if global.json {
            Output.json(["students": c.students, "students_invited": c.studentsInvited, "teachers": c.teachers, "tas": c.tas])
        } else {
            print("學生 \(c.students)（邀請中 \(c.studentsInvited)）｜教師 \(c.teachers)｜助教 \(c.tas)")
        }
        if let path = appendCSV {
            try appendRow(c, to: path, offset: session.config.timezone)
        }
    }

    func appendRow(_ c: EnrollmentCounts, to path: String, offset: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw ValidationError("CSV 不存在：\(path)") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeInput.timeZone(offset)
        f.dateFormat = "yyyy-MM-dd"
        let date = f.string(from: Date())
        f.dateFormat = "HH:mm"
        let note = self.note.contains(",") ? "\"\(self.note.replacingOccurrences(of: "\"", with: "\"\""))\"" : self.note
        let row = "\(date),\(f.string(from: Date()))\(offset),\(c.students),\(c.studentsInvited),\(c.teachers),\(c.tas),\(note)\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(Data(row.utf8))
        FileHandle.standardError.write(Data("→ 已加到 \(path)\n".utf8))
    }
}

struct ModuleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "module", abstract: "模組：加外部連結、發布。",
        subcommands: [AddURL.self, Publish.self])

    struct AddURL: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add-url", abstract: "在某週模組加外部連結（預設未發布；同網址已存在則不重複加）。")

        @OptionGroup var global: GlobalOptions
        @Option(help: "週次，如 W03") var week: String
        @Option(help: "項目標題") var title: String
        @Option(help: "網址") var url: String
        @Flag(help: "建好後發布（學生可見，走發布閘）") var publish = false

        func run() async throws {
            let id = try await global.session().addURL(week: week, title: title, url: url, publish: publish)
            global.json ? Output.json(["module_item_id": id]) : print("module item \(id)")
        }
    }

    struct Publish: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "publish", abstract: "發布（或 --off 取消發布）模組或模組項目。")

        @OptionGroup var global: GlobalOptions
        @Argument(help: "模組 id 或週次（W03）") var module: String
        @Option(help: "只發布這個模組項目 id") var item: Int?
        @Flag(help: "取消發布") var off = false

        func run() async throws {
            let session = try global.session()
            let moduleID = try Int(module) ?? session.moduleID(week: module)
            if let item {
                try await session.setPublished(kind: .item, id: item, moduleID: moduleID, published: !off)
            } else {
                try await session.setPublished(kind: .module, id: moduleID, published: !off)
            }
            print(off ? "已取消發布" : "已發布")
        }
    }
}
