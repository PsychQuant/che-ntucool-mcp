import Foundation
import MCP
import CheNtucoolCore

/// NTU COOL (Canvas LMS) MCP Server — queries and human-confirmed writes against
/// the Canvas API
/// deployed at `cool.ntu.edu.tw`. See PsychQuant/ntu-claude-plugins#17 for the
/// verification that established this is safe/possible, and #18 for the tracking
/// issue this project implements.
class NtucoolMCPServer {
    private let server: Server
    private let transport: StdioTransport

    /// Keychain account used to look up the Personal Access Token. Overridable via
    /// `NTUCOOL_ACCOUNT` so this repo doesn't hardcode any one person's login id.
    private let keychainAccount: String

    /// Holds preview→write confirmation tokens. See WriteGate.swift for why the
    /// token exists alongside the elicitation dialog rather than instead of it.
    private let writeGate = WriteGate()

    /// Whether the connected client told us, at initialize time, that it can
    /// show an elicitation dialog.
    ///
    /// Captured here rather than read off the SDK because `Server` keeps its
    /// copy private AND only enforces it under `Configuration.strict` — so
    /// relying on the SDK's own `validateClientCapability` would make this
    /// server's central safety property depend on a global mode flag that is
    /// off by default and could be flipped later for an unrelated compatibility
    /// reason. That is the shape of a guard that silently stops guarding. This
    /// server owns the check instead.
    private var clientSupportsFormElicitation = false

    private static let serverInstructions = """
    # che-ntucool — NTU COOL (Canvas LMS) query server

    Queries and human-confirmed writes against NTU COOL, National Taiwan
    University's Canvas LMS deployment (`cool.ntu.edu.tw`).

    Credentials: no setup is normally needed. If the macOS keychain holds a
    working Canvas token (service `ntu-cool-canvas`, account `default` or
    $NTUCOOL_ACCOUNT) it is used; otherwise — including when NTU COOL rejects
    it, which manually issued tokens do after about an hour — requests go
    through a logged-in Safari tab on cool.ntu.edu.tw. If a call fails with
    "Safari 沒有已登入的 COOL 分頁", ask the user to open and log in to NTU COOL
    in Safari; do not ask them for a token. Never ask the user to paste a token
    into the conversation.

    For course building (modules, quizzes from markdown, assignments,
    announcement files, publishing) use the `che-ntucool` CLI; this server
    covers reads plus gated grade and announcement writes.

    ## Read tools

    - `list_courses` — courses the token owner is enrolled in / teaching
    - `list_assignments` — assignments in a course
    - `list_announcements` — announcements in a course
    - `list_submissions` — submission/grading status for a course's students
    - `list_files` — files uploaded to a course
    - `list_enrollments` — roster for a course

    ## Write tools — two-step, human-confirmed

    Writes notify students immediately and cannot be un-sent, so each is gated
    twice and BOTH steps are mandatory:

    1. `preview_grade_change` / `preview_announcement` — renders exactly what
       would happen (current grade → new grade, per student) and returns a
       `confirmation_token` bound to that exact payload.
    2. `post_grades` / `post_announcement` — requires that token, then asks the
       user directly through the client's own confirmation dialog. The write
       happens only if the user accepts.

    You cannot skip step 1: the write refuses without a valid token. You cannot
    satisfy step 2 on the user's behalf: the dialog does not pass through you.
    A token is single-use, expires in 10 minutes, and is bound to the payload it
    previewed — if the payload changes at all, the write is refused and you must
    preview again so a human sees the corrected version.

    Do not attempt to route around a refusal (e.g. by telling the user to make
    the change manually in NTU COOL). A refusal means a human has not approved
    this write; carry that outcome back to them plainly.
    """

    init() async {
        self.keychainAccount = ProcessInfo.processInfo.environment["NTUCOOL_ACCOUNT"] ?? "default"
        self.transportLadder = Self.makeTransport(keychainAccount: keychainAccount)
        self.server = Server(
            name: "che-ntucool-mcp",
            version: "0.3.0",
            instructions: Self.serverInstructions,
            capabilities: .init(tools: .init()),
            // Strict mode is correct on its own terms (the spec requires clients
            // to initialize before anything else), and it also re-arms the SDK's
            // own capability validation. It is belt to the braces in
            // `confirmWithUser` — not a substitute for it.
            configuration: .strict
        )
        self.transport = StdioTransport()
        await registerToolHandlers()
    }

    func run() async throws {
        try await server.start(transport: transport) { [weak self] _, capabilities in
            // The only moment the client states what it can do. Recorded so the
            // write gate can refuse up front instead of sending an
            // `elicitation/create` into a client that will never answer it —
            // which would hang the tool call rather than fail it.
            await self?.recordClientCapabilities(capabilities)
        }
        await server.waitUntilCompleted()
    }

    private func recordClientCapabilities(_ capabilities: Client.Capabilities) {
        clientSupportsFormElicitation = capabilities.elicitation?.form != nil
    }

    // MARK: - Client construction

    /// One transport per server process: the credential ladder decides once
    /// (token → Safari) and every tool call after that reuses the decision.
    private let transportLadder: CanvasTransport

    private static func makeTransport(keychainAccount: String) -> CanvasTransport {
        // `NTUCOOL_API_BASE` points the bearer transport at a stub so the write
        // gate can be verified end-to-end — that override is token-only, since
        // the Safari path is by construction same-origin with cool.ntu.edu.tw.
        let env = ProcessInfo.processInfo.environment
        let baseURL = env["NTUCOOL_API_BASE"]
            .flatMap(URL.init(string:)) ?? CanvasURL.defaultAPIBase
        // Pins the Safari fallback to one Canvas account (see AutoTransport).
        let expectedUserID = env["NTUCOOL_EXPECTED_USER_ID"].flatMap(Int.init)
        return AutoTransport(
            tokenProvider: {
                do {
                    // Always headless (spawned over stdio): never wait on a
                    // keychain dialog; .uiRequired propagates and the ladder
                    // uses Safari.
                    return try CanvasAuth.read(account: keychainAccount, allowUI: false)
                } catch CanvasAuthError.itemNotFound {
                    return nil
                }
            },
            tokenTransportFactory: { TokenTransport(token: $0, baseURL: baseURL) },
            expectedUserID: expectedUserID
        )
    }

    private func makeClient() throws -> CanvasAPIClient {
        CanvasAPIClient(transport: transportLadder)
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
            ),

            // MARK: Write tools (two-step, human-confirmed)

            Tool(
                name: "preview_grade_change",
                description: """
                    STEP 1 of 2 for posting grades. Renders what would change \
                    (current grade → new grade, per student) and returns a \
                    confirmation_token. Performs no write. Show the returned \
                    preview to the user before calling post_grades.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "course_id": .object(courseIdProperty),
                        "assignment_id": .object([
                            "type": .string("integer"),
                            "description": .string("Canvas assignment id (from list_assignments)")
                        ]),
                        "grades": .object([
                            "type": .string("array"),
                            "description": .string(
                                "Grades to set. Each item: {user_id: int, grade: string}. "
                                + "grade accepts points (\"85\"), percentage (\"85%\"), letter (\"A\"), "
                                + "or \"pass\"/\"fail\" — whatever the assignment's grading type takes."
                            ),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "user_id": .object(["type": .string("integer")]),
                                    "grade": .object(["type": .string("string")])
                                ]),
                                "required": .array([.string("user_id"), .string("grade")])
                            ])
                        ])
                    ]),
                    "required": .array([
                        .string("course_id"), .string("assignment_id"), .string("grades")
                    ])
                ])
            ),
            Tool(
                name: "post_grades",
                description: """
                    STEP 2 of 2. Writes grades to NTU COOL after asking the user \
                    to confirm in their own dialog. Requires the confirmation_token \
                    from preview_grade_change with an IDENTICAL payload — any \
                    difference is refused. Students are notified; this cannot be undone.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "course_id": .object(courseIdProperty),
                        "assignment_id": .object([
                            "type": .string("integer"),
                            "description": .string("Canvas assignment id")
                        ]),
                        "grades": .object([
                            "type": .string("array"),
                            "description": .string("Must match preview_grade_change exactly."),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "user_id": .object(["type": .string("integer")]),
                                    "grade": .object(["type": .string("string")])
                                ]),
                                "required": .array([.string("user_id"), .string("grade")])
                            ])
                        ]),
                        "confirmation_token": .object([
                            "type": .string("string"),
                            "description": .string("The token returned by preview_grade_change.")
                        ])
                    ]),
                    "required": .array([
                        .string("course_id"), .string("assignment_id"),
                        .string("grades"), .string("confirmation_token")
                    ])
                ])
            ),
            Tool(
                name: "preview_announcement",
                description: """
                    STEP 1 of 2 for posting an announcement. Renders what would be \
                    published and to how many people, and returns a confirmation_token. \
                    Performs no write. Show the returned preview to the user before \
                    calling post_announcement.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "course_id": .object(courseIdProperty),
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("Announcement title")
                        ]),
                        "message": .object([
                            "type": .string("string"),
                            "description": .string("Announcement body (HTML permitted)")
                        ])
                    ]),
                    "required": .array([
                        .string("course_id"), .string("title"), .string("message")
                    ])
                ])
            ),
            Tool(
                name: "post_announcement",
                description: """
                    STEP 2 of 2. Publishes the announcement after asking the user to \
                    confirm in their own dialog. Requires the confirmation_token from \
                    preview_announcement with IDENTICAL title and message. Students are \
                    notified; this cannot be un-sent.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "course_id": .object(courseIdProperty),
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("Must match preview_announcement exactly.")
                        ]),
                        "message": .object([
                            "type": .string("string"),
                            "description": .string("Must match preview_announcement exactly.")
                        ]),
                        "confirmation_token": .object([
                            "type": .string("string"),
                            "description": .string("The token returned by preview_announcement.")
                        ])
                    ]),
                    "required": .array([
                        .string("course_id"), .string("title"),
                        .string("message"), .string("confirmation_token")
                    ])
                ])
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
        // Writes are gated BEFORE anything else happens — including before the
        // keychain is read. Two reasons. A bad token is a cheaper and more
        // informative failure than a missing credential, so it should not be
        // masked by one. And gating first means the refusal path can be
        // exercised on a machine with no Canvas token at all, which is what
        // makes "does the gate actually hold?" a question with a testable
        // answer rather than a claim resting on reading the code.
        switch name {
        case "post_grades":
            return try await postGrades(args: args)
        case "post_announcement":
            return try await postAnnouncement(args: args)
        default:
            break
        }

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

        case "preview_grade_change":
            return try await previewGradeChange(client: client, args: args)

        case "preview_announcement":
            return try await previewAnnouncement(client: client, args: args)

        default:
            throw CanvasToolError.unknownTool(name)
        }
    }

    // MARK: - Write argument parsing

    private func requireInt(_ args: [String: Value], _ key: String) throws -> Int {
        guard let v = args[key]?.intValue else { throw CanvasToolError.missingArgument(key) }
        return v
    }

    private func requireString(_ args: [String: Value], _ key: String) throws -> String {
        guard let v = args[key]?.stringValue else { throw CanvasToolError.missingArgument(key) }
        return v
    }

    /// Parse the `grades` array.
    ///
    /// `grade` is accepted as a string, an int, or a double. A model asked for a
    /// score will very reasonably emit `85` rather than `"85"`, and refusing that
    /// would be a schema-pedantry failure that costs a round trip and teaches
    /// nothing. Numbers are normalised to their shortest exact spelling so that
    /// `85` and `85.0` do not produce two different payload hashes for what is
    /// plainly the same grade.
    private func parseGradeEntries(_ args: [String: Value]) throws -> [GradeEntry] {
        guard let raw = args["grades"]?.arrayValue else {
            throw CanvasToolError.missingArgument("grades")
        }
        guard !raw.isEmpty else {
            throw CanvasToolError.emptyGrades
        }
        var entries: [GradeEntry] = []
        for (i, item) in raw.enumerated() {
            guard let obj = item.objectValue else {
                throw CanvasToolError.badGradeEntry(index: i, why: "not an object")
            }
            guard let userId = obj["user_id"]?.intValue else {
                throw CanvasToolError.badGradeEntry(index: i, why: "missing or non-integer user_id")
            }
            let grade: String
            if let s = obj["grade"]?.stringValue {
                grade = s
            } else if let n = obj["grade"]?.intValue {
                grade = String(n)
            } else if let d = obj["grade"]?.doubleValue {
                grade = d == d.rounded() ? String(Int(d)) : String(d)
            } else {
                throw CanvasToolError.badGradeEntry(index: i, why: "missing grade")
            }
            entries.append(GradeEntry(userId: userId, grade: grade))
        }
        // A duplicate user_id means two different grades were requested for one
        // student; whichever landed last would silently win. Refuse instead —
        // the caller has to say which one it meant.
        let ids = entries.map(\.userId)
        if Set(ids).count != ids.count {
            throw CanvasToolError.duplicateStudents
        }
        return entries
    }

    // MARK: - The confirmation gate
    //
    // Layer 1 of the gate. Every write funnels through here, and it is the only
    // place `requestElicitation` is called, so there is no second path to the
    // API that skips the human.
    //
    // Fail-closed in every direction:
    //   - client does not support elicitation → `requestElicitation` throws
    //     (`validateClientCapability`) → we do not write
    //   - user declines or cancels          → we do not write
    //   - transport error / timeout         → throws → we do not write
    //
    // The one thing this cannot defend against is a user who has configured an
    // `Elicitation` hook in Claude Code to auto-answer. That is a deliberate,
    // user-owned decision made outside this server, which is a different thing
    // from the model deciding to skip a step on its own — but it is a real hole
    // and worth knowing about rather than assuming the dialog is inviolable.
    private func confirmWithUser(_ renderedConfirmation: String) async throws {
        // Refuse BEFORE sending, not after waiting. A client that never declared
        // elicitation may simply drop an unknown request on the floor, and
        // `requestElicitation` would then wait for a reply that is never coming —
        // turning a write that should have failed in milliseconds into a wedged
        // tool call. Refusing here converts that hang into a stated refusal.
        guard clientSupportsFormElicitation else {
            throw WriteGateError.confirmationUnavailable
        }

        let result = try await server.requestElicitation(
            message: renderedConfirmation,
            requestedSchema: Elicitation.RequestSchema(
                title: "Confirm NTU COOL write",
                description: "This writes to a live course and notifies students.",
                properties: [:],
                required: []
            ),
            mode: .form
        )

        switch result.action {
        case .accept:
            return
        case .decline:
            throw WriteGateError.declined("declined")
        case .cancel:
            throw WriteGateError.declined("cancelled")
        }
    }

    // MARK: - Grades

    /// Build the human-facing preview AND the payload, from one place.
    ///
    /// Preview and write share this so the confirmation cannot describe one
    /// thing while the payload carries another — the drift that layer 2 exists
    /// to catch is prevented here rather than merely detected later.
    private func renderGradeConfirmation(
        client: CanvasAPIClient,
        courseId: Int,
        assignmentId: Int,
        entries: [GradeEntry]
    ) async throws -> String {
        let course = try await client.getCourse(courseId: courseId)
        let assignment = try await client.getAssignment(courseId: courseId, assignmentId: assignmentId)

        var lines: [String] = []
        lines.append("assignment: \(assignment.name) (id \(assignmentId))")
        if let pts = assignment.pointsPossible {
            lines.append("out of: \(formatNumber(pts)) points")
        }
        lines.append("changes:")
        for e in entries {
            // Current state per student. A failed lookup is reported inline
            // rather than aborting: a student who cannot be read is itself
            // something the human should see before approving the batch.
            let current: String
            let who: String
            do {
                let sub = try await client.getSubmission(
                    courseId: courseId, assignmentId: assignmentId, userId: e.userId
                )
                current = sub.grade ?? sub.score.map { formatNumber($0) } ?? "(ungraded)"
            } catch {
                current = "(could not read current grade)"
            }
            if let user = try? await client.getUser(userId: e.userId), let name = user.name {
                who = "\(name) (id \(e.userId))"
            } else {
                who = "user \(e.userId)"
            }
            lines.append("  - \(who): \(current) → \(e.grade)")
        }

        // Reversibility is read off the assignment, not assumed. Foresay branches
        // on it, so getting it wrong in either direction is a real error: claiming
        // "cannot be undone" for a manually-posted assignment cries wolf, and
        // omitting it for an auto-posted one hides the thing that matters.
        let irreversible: String?
        switch assignment.postManually {
        case .some(true):
            irreversible = nil
        case .some(false):
            irreversible = "this assignment posts grades automatically, so students are "
                + "notified as soon as the grade is written, and a notification cannot be un-sent"
        case .none:
            irreversible = "the posting policy for this assignment could not be read, so this "
                + "assumes the default (automatic) — students would be notified immediately"
        }

        var confirmation = Foresay.operationConfirmation(
            action: "post_grades",
            target: "\(course.name) [\(course.courseCode ?? "?")]",
            parameters: lines,
            scope: "\(entries.count) student\(entries.count == 1 ? "" : "s")",
            irreversibleBecause: irreversible,
            residue: "whether these are the right scores for these students — this server "
                + "can check that the assignment and students exist, not that the grades are correct"
        )

        if assignment.postManually == true {
            confirmation += "\n\nNote: this assignment uses a MANUAL posting policy, so the "
                + "grades stay hidden from students until you post them in NTU COOL. "
                + "That makes this write recoverable — but only until you post."
        }
        return confirmation
    }

    private func previewGradeChange(client: CanvasAPIClient, args: [String: Value]) async throws -> String {
        let courseId = try requireInt(args, "course_id")
        let assignmentId = try requireInt(args, "assignment_id")
        let entries = try parseGradeEntries(args)

        let confirmation = try await renderGradeConfirmation(
            client: client, courseId: courseId, assignmentId: assignmentId, entries: entries
        )
        let payload = WritePayload.grades(
            courseId: courseId, assignmentId: assignmentId, entries: entries
        )
        let token = await writeGate.issue(for: payload, preview: confirmation)

        return """
            \(confirmation)

            ---
            Show the above to the user. To proceed, call post_grades with the SAME \
            course_id / assignment_id / grades plus:

            confirmation_token: \(token)

            (single-use, expires in 10 minutes; the user will also be asked to confirm directly)
            """
    }

    private func postGrades(args: [String: Value]) async throws -> String {
        let courseId = try requireInt(args, "course_id")
        let assignmentId = try requireInt(args, "assignment_id")
        let entries = try parseGradeEntries(args)
        let token = try requireString(args, "confirmation_token")

        let payload = WritePayload.grades(
            courseId: courseId, assignmentId: assignmentId, entries: entries
        )

        // Layer 2: token must exist, be unexpired, and be bound to THIS payload.
        let approvedPreview = try await writeGate.consume(token: token, payload: payload)

        // Layer 1: the user confirms the very text the token was issued against,
        // so the dialog cannot show something the preview did not.
        try await confirmWithUser(approvedPreview)

        // Only now is a credential needed. Everything above can refuse without one.
        let client = try makeClient()

        // Per-student, so a partial failure is reported as a partial failure
        // rather than collapsing a mixed outcome into one verdict.
        var succeeded: [String] = []
        var failed: [String] = []
        for e in entries {
            do {
                _ = try await client.updateSubmissionGrade(
                    courseId: courseId, assignmentId: assignmentId,
                    userId: e.userId, grade: e.grade
                )
                succeeded.append("user \(e.userId) → \(e.grade)")
            } catch {
                failed.append("user \(e.userId) → \(e.grade): \(error.localizedDescription)")
            }
        }

        var report = Foresay.operationReport(
            action: "post_grades",
            target: "course \(courseId), assignment \(assignmentId)",
            scope: "\(succeeded.count) of \(entries.count) student"
                + "\(entries.count == 1 ? "" : "s")",
            residue: nil
        )
        if !succeeded.isEmpty {
            report += "\nWritten:\n" + succeeded.map { "  - \($0)" }.joined(separator: "\n") + "\n"
        }
        if !failed.isEmpty {
            report += "\n⚠ FAILED (these grades were NOT written):\n"
                + failed.map { "  - \($0)" }.joined(separator: "\n")
                + "\n\nThe successful writes above have already notified those students; "
                + "they are not rolled back. Re-preview only the failed entries to retry them.\n"
        }
        return report
    }

    // MARK: - Announcements

    private func renderAnnouncementConfirmation(
        client: CanvasAPIClient,
        courseId: Int,
        title: String,
        message: String
    ) async throws -> String {
        let course = try await client.getCourse(courseId: courseId)

        // Audience size, so "who sees this" is a number rather than an
        // abstraction. Failure to count is stated, not silently omitted — an
        // absent number would otherwise read as "nobody".
        let audience: String
        do {
            let enrollments = try await client.listEnrollments(courseId: courseId, perPage: 100)
            let students = enrollments.filter { $0.type == "StudentEnrollment" }.count
            audience = "\(students) student\(students == 1 ? "" : "s") enrolled in this course"
        } catch {
            audience = "everyone enrolled in this course (roster size could not be read)"
        }

        let preview = message.count > 500 ? String(message.prefix(500)) + "\n  […truncated in this preview]" : message

        return Foresay.operationConfirmation(
            action: "post_announcement",
            target: "\(course.name) [\(course.courseCode ?? "?")]",
            parameters: [
                "title: \(title)",
                "message:",
                preview.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "    \($0)" }.joined(separator: "\n"),
            ],
            scope: audience,
            irreversibleBecause: "publishing an announcement notifies every student immediately; "
                + "deleting it afterwards does not un-send the notification",
            residue: "whether this is the right wording to send to a live class"
        )
    }

    private func previewAnnouncement(client: CanvasAPIClient, args: [String: Value]) async throws -> String {
        let courseId = try requireInt(args, "course_id")
        let title = try requireString(args, "title")
        let message = try requireString(args, "message")

        let confirmation = try await renderAnnouncementConfirmation(
            client: client, courseId: courseId, title: title, message: message
        )
        let payload = WritePayload.announcement(courseId: courseId, title: title, message: message)
        let token = await writeGate.issue(for: payload, preview: confirmation)

        return """
            \(confirmation)

            ---
            Show the above to the user. To proceed, call post_announcement with the \
            SAME course_id / title / message plus:

            confirmation_token: \(token)

            (single-use, expires in 10 minutes; the user will also be asked to confirm directly)
            """
    }

    private func postAnnouncement(args: [String: Value]) async throws -> String {
        let courseId = try requireInt(args, "course_id")
        let title = try requireString(args, "title")
        let message = try requireString(args, "message")
        let token = try requireString(args, "confirmation_token")

        let payload = WritePayload.announcement(courseId: courseId, title: title, message: message)

        let approvedPreview = try await writeGate.consume(token: token, payload: payload)
        try await confirmWithUser(approvedPreview)

        // Only now is a credential needed. Everything above can refuse without one.
        let client = try makeClient()

        let created = try await client.createAnnouncement(
            courseId: courseId, title: title, message: message
        )

        return Foresay.operationReport(
            action: "post_announcement",
            target: "course \(courseId)",
            scope: "published as announcement #\(created.id) — \"\(created.title)\"",
            residue: nil
        )
    }

    private func formatNumber(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(d)
    }
}

enum CanvasToolError: Error, LocalizedError {
    case missingArgument(String)
    case unknownTool(String)
    case emptyGrades
    case badGradeEntry(index: Int, why: String)
    case duplicateStudents

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "Missing required argument: \(name)"
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .emptyGrades:
            return "grades is empty — nothing to write."
        case .badGradeEntry(let index, let why):
            return "grades[\(index)] is malformed: \(why). Each item must be {user_id: int, grade: string}."
        case .duplicateStudents:
            return """
                grades lists the same user_id more than once. Whichever entry was applied \
                last would silently win, so this is refused — send one grade per student.
                """
        }
    }
}
