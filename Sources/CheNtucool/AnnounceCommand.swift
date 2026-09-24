import ArgumentParser
import CheNtucoolCore
import Foundation

struct AnnounceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "announce", abstract: "公告：列出、從公告檔發出、編輯已發出的公告。",
        discussion: "公告檔格式同課程 repo 的 announcements/：只貼「## 正文」段，標題取 # 那一行。發出與編輯都會通知或改動全班看到的內容，一律走發布閘。",
        subcommands: [List.self, Post.self, Edit.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "列出公告。")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let session = try global.session()
            let items = try await session.announcements()
            if global.json { return Output.json(items) }
            for a in items {
                let at = TimeInput.display(a["posted_at"] as? String, offset: session.config.timezone)
                print("\(a["id"] ?? "?")\t\(at)\t\(Output.name(a))")
            }
        }
    }

    struct Post: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "發出公告（全班通知，無法收回）。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "公告檔（.md）") var file: String

        func run() async throws {
            let parsed = try AnnouncementFile.parse(try readFile(file))
            let id = try await global.session().postAnnouncement(parsed)
            global.json ? Output.json(["announcement_id": id]) : print("公告 \(id) 已發出；記得回填檔案的 status／posted_at／cool_announcement_id")
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "用公告檔覆寫已發出的公告（不重發通知，但學生看到的內容會變）。")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "公告 id") var id: Int
        @Argument(help: "公告檔（.md）") var file: String

        func run() async throws {
            let parsed = try AnnouncementFile.parse(try readFile(file))
            try await global.session().editAnnouncement(id: id, parsed)
            print("公告 \(id) 已更新；記得在檔案的「## 修訂」記一筆")
        }
    }
}
