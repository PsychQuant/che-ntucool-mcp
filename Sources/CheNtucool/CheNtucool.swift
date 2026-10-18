import ArgumentParser
import CheNtucoolCore
import Foundation

/// `che-ntucool` — command-line client for NTU COOL (Canvas LMS).
///
/// Reads need nothing but a logged-in Safari tab (or a fresh keychain token).
/// Anything students can see — publishing, announcements, edits to published
/// content — prints a preview and needs `COOL_ALLOW_PUBLISH=1` plus `--yes`
/// or a y/N answer. Everything created starts unpublished.
@main
struct CheNtucool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "che-ntucool",
        abstract: "NTU COOL（Canvas）命令列工具：讀取、建置、經確認後發布。",
        discussion: """
        通行證自動選：keychain token（service ntu-cool-canvas）能用就用，沒有或失效就改走 \
        Safari 已登入的 cool.ntu.edu.tw 分頁。課程設定讀 --config、$CHE_NTUCOOL_CONFIG 或 ./ntucool.json。
        學生看得到的寫入（發布、公告、修改已發布的內容）要 COOL_ALLOW_PUBLISH=1，並用 --yes 或互動確認。
        """,
        subcommands: [
            StateCommand.self, ModuleCommand.self, QuizCommand.self,
            AssignmentCommand.self, AnnounceCommand.self, EnrollCommand.self,
        ]
    )
}

/// Options every subcommand takes.
struct GlobalOptions: ParsableArguments {
    @Option(help: "課程設定檔（預設 $CHE_NTUCOOL_CONFIG 或 ./ntucool.json）")
    var config: String?

    @Flag(help: "以 JSON 輸出（寫入的預覽仍印在 stderr）")
    var json = false

    @Flag(name: [.customShort("y"), .long], help: "學生可見的寫入不再互動詢問；仍需 COOL_ALLOW_PUBLISH=1")
    var yes = false

    @Option(help: "keychain account（預設 $NTUCOOL_ACCOUNT 或 default）")
    var account: String?

    func loadConfig() throws -> CourseConfig {
        try CourseConfig.load(explicitPath: config)
    }

    /// Session wired to the real transport ladder and the console gate.
    func session() throws -> CourseSession {
        let config = try loadConfig()
        let env = ProcessInfo.processInfo.environment
        let keychainAccount = account ?? env["NTUCOOL_ACCOUNT"] ?? "default"
        // A keychain dialog is fine for a person at a terminal; for a headless
        // caller it would block forever, so there the read fails fast and the
        // ladder goes to Safari.
        let allowUI = isatty(STDIN_FILENO) != 0
        let transport = AutoTransport(
            tokenProvider: {
                do { return try CanvasAuth.read(account: keychainAccount, allowUI: allowUI) }
                catch CanvasAuthError.itemNotFound { return nil }
                // .uiRequired propagates: the ladder logs it and uses Safari.
            },
            expectedUserID: config.expectedUserId
        )
        let gate = ConsoleGate(environment: env, assumeYes: yes)
        return CourseSession(client: CanvasAPIClient(transport: transport), config: config, gate: gate.check)
    }
}

/// The CLI's gate: announce every write on stderr; for student-visible ones
/// print the full preview and apply `PublishGate`.
struct ConsoleGate {
    var environment: [String: String]
    var assumeYes: Bool
    var isInteractive: Bool = isatty(STDIN_FILENO) != 0
    var readAnswer: () -> String? = { readLine() }
    var err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    func check(_ request: WriteRequest) throws {
        guard request.visible else {
            err("→ \(request.preview.split(separator: "\n").first ?? "")")
            return
        }
        err("──── 學生看得到：\(request.method) \(request.path) ────\n\(request.preview)\n────────────────")
        try PublishGate.authorize(visible: true, environment: environment, assumeYes: assumeYes) {
            guard isInteractive else { return nil }
            err("送出？[y/N] ")
            return readAnswer()?.trimmingCharacters(in: .whitespaces).lowercased() == "y"
        }
    }
}
