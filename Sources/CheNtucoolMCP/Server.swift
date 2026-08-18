import Foundation
import MCP

/// NTU COOL (Canvas LMS) MCP Server — read-only queries against the Canvas API
/// deployed at `cool.ntu.edu.tw`. See PsychQuant/ntu-claude-plugins#17 for the
/// verification that established this is safe/possible, and #18 for the tracking
/// issue this project implements.
class NtucoolMCPServer {
    private let server: Server
    private let transport: StdioTransport

    /// Keychain account used to look up the Personal Access Token. Overridable via
    /// `NTUCOOL_ACCOUNT` so this repo doesn't hardcode any one person's login id.
    private let keychainAccount: String

    private static let serverInstructions = """
    # che-ntucool-mcp — NTU COOL (Canvas LMS) query server

    Read-only queries against NTU COOL, National Taiwan University's Canvas LMS
    deployment (`cool.ntu.edu.tw`). Requires a Canvas Personal Access Token stored
    in the macOS keychain (service `ntu-cool-canvas`) — generate one at
    NTU COOL → 帳戶 → 設定 → 新訪問令牌, then:

        security add-generic-password -s ntu-cool-canvas -a <login-id> -w <token>

    ## Scope (v0.1.0)

    Read-only. No grade posting, no announcement creation — those are teaching-
    incident-risk operations deliberately left out of this first version.

    ## Tools

    - `list_courses` — courses the token owner is enrolled in / teaching
    - `list_assignments` — assignments in a course
    - `list_announcements` — announcements in a course
    - `list_submissions` — submission/grading status for a course's students
    - `list_files` — files uploaded to a course
    - `list_enrollments` — roster for a course
    """

    init() async {
        self.keychainAccount = ProcessInfo.processInfo.environment["NTUCOOL_ACCOUNT"] ?? "default"
        self.server = Server(
            name: "che-ntucool-mcp",
            version: "0.1.0",
            instructions: Self.serverInstructions,
            capabilities: .init(tools: .init())
        )
        self.transport = StdioTransport()
        await registerToolHandlers()
    }

    func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Client construction

    private func makeClient() throws -> CanvasAPIClient {
        let token = try CanvasAuth.read(account: keychainAccount)
        return CanvasAPIClient(token: token)
    }

    // MARK: - Handler registration

    private func registerToolHandlers() async {
        let tools = allTools
        await server.withMethodHandler(ListTools.self) { [tools] _ in
            ListTools.Result(tools: tools)
        }
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self = self else {
                return CallTool.Result(content: [.text("Server unavailable")], isError: true)
            }
            return await self.handleToolCall(params)
        }
    }

    // MARK: - Tool definitions

    private var allTools: [Tool] {
        let courseIdProperty: [String: Value] = [
            "type": .string("integer"),
            "description": .string("Canvas course id (from list_courses)")
        ]
        let courseIdSchema: (String) -> Value = { description in
            .object([
                "type": .string("object"),
                "properties": .object(["course_id": .object(courseIdProperty)]),
                "required": .array([.string("course_id")])
            ])
        }

        return [
            Tool(
                name: "list_courses",
                description: "List courses the token owner is enrolled in or teaching",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([])
                ])
            ),
            Tool(
                name: "list_assignments",
                description: "List assignments in a course",
                inputSchema: courseIdSchema("course_id")
            ),
            Tool(
                name: "list_announcements",
                description: "List announcements posted in a course",
                inputSchema: courseIdSchema("course_id")
            ),
            Tool(
                name: "list_submissions",
                description: "List submission/grading status for every student in a course",
                inputSchema: courseIdSchema("course_id")
            ),
            Tool(
                name: "list_files",
                description: "List files uploaded to a course",
                inputSchema: courseIdSchema("course_id")
            ),
            Tool(
                name: "list_enrollments",
                description: "List the enrollment roster for a course",
                inputSchema: courseIdSchema("course_id")
            )
        ]
    }

    // MARK: - Tool dispatch

    private func handleToolCall(_ params: CallTool.Parameters) async -> CallTool.Result {
        let args = params.arguments ?? [:]
        do {
            let text = try await executeTool(name: params.name, args: args)
            return CallTool.Result(content: [.text(text)])
        } catch {
            return CallTool.Result(
                content: [.text("Error: \(error.localizedDescription)")],
                isError: true
            )
        }
    }

    private func requireCourseId(_ args: [String: Value]) throws -> Int {
        guard let courseId = args["course_id"]?.intValue else {
            throw CanvasToolError.missingArgument("course_id")
        }
        return courseId
    }

    private func executeTool(name: String, args: [String: Value]) async throws -> String {
        let client = try makeClient()

        switch name {
        case "list_courses":
            let courses = try await client.listCourses()
            if courses.isEmpty { return "No courses found." }
            return courses.map { c in
                "#\(c.id)  \(c.name)  [\(c.courseCode ?? "?")]  state=\(c.workflowState ?? "?")"
            }.joined(separator: "\n")

        case "list_assignments":
            let courseId = try requireCourseId(args)
            let assignments = try await client.listAssignments(courseId: courseId)
            if assignments.isEmpty { return "No assignments found for course #\(courseId)." }
            return assignments.map { a in
                let due = a.dueAt ?? "no due date"
                let pts = a.pointsPossible.map { "\($0) pts" } ?? "? pts"
                return "#\(a.id)  \(a.name)  due=\(due)  \(pts)"
            }.joined(separator: "\n")

        case "list_announcements":
            let courseId = try requireCourseId(args)
            let announcements = try await client.listAnnouncements(courseId: courseId)
            if announcements.isEmpty { return "No announcements found for course #\(courseId)." }
            return announcements.map { a in
                "#\(a.id)  \(a.title)  posted=\(a.postedAt ?? "?")"
            }.joined(separator: "\n")

        case "list_submissions":
            let courseId = try requireCourseId(args)
            let submissions = try await client.listSubmissions(courseId: courseId)
            if submissions.isEmpty { return "No submissions found for course #\(courseId)." }
            return submissions.map { s in
                let scoreStr = s.score.map { "\($0)" } ?? s.grade ?? "ungraded"
                let submitted = s.submittedAt ?? "not submitted"
                return "user=\(s.userId)  assignment=\(s.assignmentId)  submitted=\(submitted)  score=\(scoreStr)  state=\(s.workflowState ?? "?")"
            }.joined(separator: "\n")

        case "list_files":
            let courseId = try requireCourseId(args)
            let files = try await client.listFiles(courseId: courseId)
            if files.isEmpty { return "No files found for course #\(courseId)." }
            return files.map { f in
                let sizeKB = f.size.map { "\($0 / 1024) KB" } ?? "? KB"
                return "#\(f.id)  \(f.displayName)  \(sizeKB)  \(f.url ?? "")"
            }.joined(separator: "\n")

        case "list_enrollments":
            let courseId = try requireCourseId(args)
            let enrollments = try await client.listEnrollments(courseId: courseId)
            if enrollments.isEmpty { return "No enrollments found for course #\(courseId)." }
            return enrollments.map { e in
                "\(e.user?.name ?? "user \(e.user?.id ?? -1)")  type=\(e.type)  state=\(e.enrollmentState ?? "?")"
            }.joined(separator: "\n")

        default:
            throw CanvasToolError.unknownTool(name)
        }
    }
}

enum CanvasToolError: Error, LocalizedError {
    case missingArgument(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "Missing required argument: \(name)"
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        }
    }
}
