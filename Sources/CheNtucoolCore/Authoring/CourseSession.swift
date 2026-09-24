import Foundation

/// A write about to be sent, handed to the gate first.
public struct WriteRequest: @unchecked Sendable {
    public let method: String
    public let path: String
    public let body: Any?
    /// True when students can see the effect: the body publishes, it is an
    /// announcement, or the target is already published.
    public let visible: Bool
    /// Human-readable description of the write, shown before confirmation.
    public let preview: String
}

public enum CourseSessionError: Error, LocalizedError, Equatable {
    case unknownWeek(String, known: [String])
    case alreadyExists(String, Int)
    case unknownOptionSet(String, known: [String])
    case notFound(String)
    case unexpectedResponse(String)
    /// Created with `published: false` but Canvas reports it published. It
    /// has already been unpublished again; the error says so loudly because
    /// students may have seen it in between.
    case publishedUnexpectedly(String, Int)

    public var errorDescription: String? {
        switch self {
        case .unknownWeek(let w, let known):
            return "ntucool.json 的 modules 沒有「\(w)」；已知：\(known.sorted().joined(separator: ", "))"
        case .alreadyExists(let kind, let id):
            return "同名的 \(kind) 已存在（id \(id)）；要重建請先刪除，要修改請用 set / update-question"
        case .unknownOptionSet(let name, let known):
            return "ntucool.json 的 quiz_option_sets 沒有「\(name)」；已知：\(known.sorted().joined(separator: ", "))"
        case .notFound(let what): return "找不到 \(what)"
        case .unexpectedResponse(let what): return "Canvas 回應格式不符：\(what)"
        case .publishedUnexpectedly(let kind, let id):
            return "\(kind) \(id) 建立時要求未發布，Canvas 卻回報已發布；已立即取消發布，但學生可能在這之間看到。請到 COOL 確認"
        }
    }
}

/// Everything `quiz build` needs; times are already normalized (with offset).
public struct QuizBuildSpec: Sendable {
    public var markdown: String
    public var week: String
    public var title: String
    public var quizType: String
    public var unlock: String?
    public var due: String?
    public var lock: String?
    public var timeLimit: Int?
    public var pointsEach: Double
    public var assignmentGroup: String?
    public var optionSet: String

    public init(markdown: String, week: String, title: String, quizType: String, unlock: String?, due: String?, lock: String?,
                timeLimit: Int?, pointsEach: Double, assignmentGroup: String?, optionSet: String) {
        self.markdown = markdown; self.week = week; self.title = title; self.quizType = quizType
        self.unlock = unlock; self.due = due; self.lock = lock; self.timeLimit = timeLimit
        self.pointsEach = pointsEach; self.assignmentGroup = assignmentGroup; self.optionSet = optionSet
    }
}

public struct EnrollmentCounts: Equatable, Sendable, Codable {
    public let students: Int
    public let studentsInvited: Int
    public let teachers: Int
    public let tas: Int
}

/// The course operations behind the CLI. Every write goes through `write`,
/// which works out whether students would see the effect and hands the
/// request to `gate` before anything is sent — there is no other path to
/// the network for a write.
public final class CourseSession {
    public typealias Gate = (WriteRequest) throws -> Void

    public let client: CanvasAPIClient
    public let config: CourseConfig
    private let gate: Gate
    private var course: String { "courses/\(config.courseId)" }

    public init(client: CanvasAPIClient, config: CourseConfig, gate: @escaping Gate) {
        self.client = client
        self.config = config
        self.gate = gate
    }

    // MARK: Lookup

    /// "W03", "03" and "3" all name the module keyed "W03" in the config.
    public func moduleID(week: String) throws -> Int {
        let digits = week.uppercased().hasPrefix("W") ? String(week.dropFirst()) : week
        let key = Int(digits).map { String(format: "W%02d", $0) } ?? week
        guard let id = config.modules[key] else {
            throw CourseSessionError.unknownWeek(week, known: Array(config.modules.keys))
        }
        return id
    }

    private func getObject(_ path: String) async throws -> [String: Any] {
        guard let obj = try await client.sendJSON("GET", path: path, object: nil) as? [String: Any] else {
            throw CourseSessionError.unexpectedResponse(path)
        }
        return obj
    }

    // MARK: The single write path

    @discardableResult
    private func write(_ method: String, _ path: String, body: [String: Any]?, targetPublished: Bool = false,
                       alwaysVisible: Bool = false, summary: String, detail: String? = nil) async throws -> Any {
        let visible = alwaysVisible || targetPublished || (body.map(PublishGate.isStudentVisible) ?? false)
        let preview = [summary, detail ?? body.map(Self.pretty)].compactMap { $0 }.joined(separator: "\n")
        try gate(WriteRequest(method: method, path: path, body: body, visible: visible, preview: preview))
        return try await client.sendJSON(method, path: path, object: body)
    }

    static func pretty(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "\(obj)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Read back what Canvas created. Anything that came back published
    /// despite `published: false` is unpublished at once and reported.
    private func ensureUnpublished(_ created: Any, kind: String, path: (Int) -> String, wrapper: String) async throws -> Int {
        guard let obj = created as? [String: Any], let id = obj["id"] as? Int else {
            throw CourseSessionError.unexpectedResponse("\(kind) id")
        }
        if obj["published"] as? Bool == true {
            try await write("PUT", path(id), body: [wrapper: ["published": false]],
                            summary: "取消發布剛建立卻被 Canvas 發布的 \(kind) \(id)")
            throw CourseSessionError.publishedUnexpectedly(kind, id)
        }
        return id
    }

    // MARK: State

    /// Modules (with items), discussions, quizzes, assignments and files.
    public func state() async throws -> [String: Any] {
        var out: [String: Any] = [:]
        // Canvas leaves `items` out of a module with too many of them even with
        // include[]=items; fetch those separately instead of showing it empty.
        var modules: [[String: Any]] = []
        for var m in try await client.paginate(path: "\(course)/modules", query: ["include[]": "items"]) {
            if m["items"] == nil, let id = m["id"] as? Int, (m["items_count"] as? Int ?? 0) > 0 {
                m["items"] = try await client.paginate(path: "\(course)/modules/\(id)/items")
            }
            modules.append(m)
        }
        out["modules"] = modules
        for kind in ["discussion_topics", "quizzes", "assignments", "files"] {
            out[kind] = try await client.paginate(path: "\(course)/\(kind)")
        }
        return out
    }

    // MARK: Modules

    /// Adds an external-URL item to the week's module, unpublished; with
    /// `publish`, a second (gated) request publishes it. Re-running with the
    /// same URL returns the existing item instead of adding a duplicate.
    @discardableResult
    public func addURL(week: String, title: String, url: String, publish: Bool) async throws -> Int {
        let moduleID = try moduleID(week: week)
        let itemsPath = "\(course)/modules/\(moduleID)/items"
        let existing = try await client.paginate(path: itemsPath)
        var itemID = existing.first { $0["type"] as? String == "ExternalUrl" && $0["external_url"] as? String == url }?["id"] as? Int
        if itemID == nil {
            let created = try await write("POST", itemsPath, body: ["module_item": [
                "type": "ExternalUrl", "title": title, "external_url": url, "new_tab": true, "published": false,
            ]], summary: "在 \(week) 模組加外部連結「\(title)」（未發布）")
            itemID = try await ensureUnpublished(created, kind: "module item", path: { "\(itemsPath)/\($0)" }, wrapper: "module_item")
        }
        guard let itemID else { throw CourseSessionError.unexpectedResponse("module item id") }
        if publish {
            try await write("PUT", "\(itemsPath)/\(itemID)", body: ["module_item": ["published": true]],
                            summary: "發布 \(week) 模組的「\(title)」")
        }
        return itemID
    }

    /// Publish (or unpublish) a module, a module item, a quiz or an assignment.
    public func setPublished(kind: PublishableKind, id: Int, moduleID: Int? = nil, published: Bool) async throws {
        let path: String
        let wrapper: String
        switch kind {
        case .module: path = "\(course)/modules/\(id)"; wrapper = "module"
        case .item:
            guard let moduleID else { throw CourseSessionError.notFound("module item 需要 --module") }
            path = "\(course)/modules/\(moduleID)/items/\(id)"; wrapper = "module_item"
        case .quiz: path = "\(course)/quizzes/\(id)"; wrapper = "quiz"
        case .assignment: path = "\(course)/assignments/\(id)"; wrapper = "assignment"
        }
        let current = try await getObject(path)
        let name = (current["title"] ?? current["name"]) as? String ?? "\(kind.rawValue) \(id)"
        try await write("PUT", path, body: [wrapper: ["published": published]],
                        targetPublished: current["published"] as? Bool == true,
                        summary: "\(published ? "發布" : "取消發布")「\(name)」（\(kind.rawValue) \(id)）")
    }

    // MARK: Quizzes

    public func quizzes() async throws -> [[String: Any]] {
        try await client.paginate(path: "\(course)/quizzes")
    }

    private func options(_ name: String) throws -> [String] {
        let sets = config.quizOptionSets ?? [:]
        guard let options = sets[name] else { throw CourseSessionError.unknownOptionSet(name, known: Array(sets.keys)) }
        return options
    }

    private func questionBody(_ q: QuizMarkdown.Question, options: [String], pointsEach: Double) throws -> [String: Any] {
        let answers = try QuizMarkdown.answerWeights(answer: q.answer, options: options)
        return ["question": [
            "question_name": "第 \(q.number) 題", "question_text": q.html,
            "question_type": "multiple_choice_question", "points_possible": pointsEach, "position": q.number,
            "answers": answers.map { ["answer_text": $0.text, "answer_weight": $0.weight] },
        ]]
    }

    /// Creates the quiz unpublished, its questions, and its module item.
    /// Every answer is checked against the option set before the first write.
    public func buildQuiz(_ spec: QuizBuildSpec) async throws -> Int {
        let options = try options(spec.optionSet)
        let parsed = try QuizMarkdown.parse(spec.markdown)
        let bodies = try parsed.questions.map { try questionBody($0, options: options, pointsEach: spec.pointsEach) }
        let moduleID = try moduleID(week: spec.week)

        if let dup = try await quizzes().first(where: { $0["title"] as? String == spec.title }), let id = dup["id"] as? Int {
            throw CourseSessionError.alreadyExists("quiz", id)
        }
        var quiz: [String: Any] = [
            "title": spec.title, "description": parsed.descriptionHTML, "quiz_type": spec.quizType,
            "points_possible": (spec.pointsEach * Double(parsed.questions.count) * 100).rounded() / 100,
            "allowed_attempts": 1, "shuffle_answers": false, "show_correct_answers": false,
            "one_question_at_a_time": false, "published": false,
        ]
        if let unlock = spec.unlock { quiz["unlock_at"] = unlock }
        if let due = spec.due { quiz["due_at"] = due }
        if let lock = spec.lock ?? spec.due { quiz["lock_at"] = lock }
        if let limit = spec.timeLimit { quiz["time_limit"] = limit }
        if let groupName = spec.assignmentGroup {
            let groups = try await client.paginate(path: "\(course)/assignment_groups")
            guard let gid = groups.first(where: { $0["name"] as? String == groupName })?["id"] as? Int else {
                throw CourseSessionError.notFound("作業群組「\(groupName)」")
            }
            quiz["assignment_group_id"] = gid
        }
        let created = try await write("POST", "\(course)/quizzes", body: ["quiz": quiz],
                                      summary: "建立測驗「\(spec.title)」（未發布，\(parsed.questions.count) 題）")
        let quizID = try await ensureUnpublished(created, kind: "quiz", path: { "\(self.course)/quizzes/\($0)" }, wrapper: "quiz")
        for (q, body) in zip(parsed.questions, bodies) {
            try await write("POST", "\(course)/quizzes/\(quizID)/questions", body: body,
                            summary: "第 \(q.number) 題（答案 \(q.answer)）", detail: "")
        }
        try await write("PUT", "\(course)/quizzes/\(quizID)", body: ["quiz": ["notify_of_update": false]],
                        summary: "不通知學生測驗更新")
        try await addItemIfMissing(moduleID: moduleID, type: "Quiz", contentID: quizID, title: spec.title)
        return quizID
    }

    private func addItemIfMissing(moduleID: Int, type: String, contentID: Int, title: String) async throws {
        let itemsPath = "\(course)/modules/\(moduleID)/items"
        let items = try await client.paginate(path: itemsPath)
        guard !items.contains(where: { $0["type"] as? String == type && $0["content_id"] as? Int == contentID }) else { return }
        // No `published` here: for quizzes and assignments the item's state *is*
        // the content's state, so publishing the item publishes the content.
        try await write("POST", itemsPath, body: ["module_item": ["type": type, "content_id": contentID]],
                        summary: "把「\(title)」放進模組 \(moduleID)")
    }

    /// Replace one question's text and answers from the markdown file.
    public func updateQuestion(quizID: Int, number: Int, markdown: String, optionSet: String, pointsEach: Double) async throws {
        let quiz = try await getObject("\(course)/quizzes/\(quizID)")
        let parsed = try QuizMarkdown.parse(markdown)
        guard let q = parsed.questions.first(where: { $0.number == number }) else {
            throw CourseSessionError.notFound("測驗檔第 \(number) 題")
        }
        let body = try questionBody(q, options: try options(optionSet), pointsEach: pointsEach)
        let existing = try await client.paginate(path: "\(course)/quizzes/\(quizID)/questions")
        guard let qid = existing.first(where: {
            $0["position"] as? Int == number || $0["question_name"] as? String == "第 \(number) 題"
        })?["id"] as? Int else { throw CourseSessionError.notFound("測驗 \(quizID) 的第 \(number) 題") }
        try await write("PUT", "\(course)/quizzes/\(quizID)/questions/\(qid)", body: body,
                        targetPublished: quiz["published"] as? Bool == true,
                        summary: "更新測驗 \(quizID) 第 \(number) 題（答案 \(q.answer)）",
                        detail: q.html)
    }

    /// PUT arbitrary quiz fields (times, limit, type, points, published).
    public func setQuiz(id: Int, fields: [String: Any]) async throws {
        let path = "\(course)/quizzes/\(id)"
        let current = try await getObject(path)
        try await write("PUT", path, body: ["quiz": fields], targetPublished: current["published"] as? Bool == true,
                        summary: "修改測驗「\(current["title"] as? String ?? "\(id)")」")
    }

    // MARK: Assignments

    public func assignmentGroups() async throws -> [[String: Any]] {
        try await client.paginate(path: "\(course)/assignment_groups")
    }

    public func assignments() async throws -> [[String: Any]] {
        try await client.paginate(path: "\(course)/assignments")
    }

    /// Creates an unpublished assignment; `fields` are Canvas assignment
    /// attributes (`name`, `points_possible`, `due_at`, …).
    public func createAssignment(fields: [String: Any], week: String?) async throws -> Int {
        var body = fields
        body["published"] = false
        let name = fields["name"] as? String ?? "?"
        if let dup = try await assignments().first(where: { $0["name"] as? String == name }), let id = dup["id"] as? Int {
            throw CourseSessionError.alreadyExists("assignment", id)
        }
        let created = try await write("POST", "\(course)/assignments", body: ["assignment": body],
                                      summary: "建立作業「\(name)」（未發布）")
        let id = try await ensureUnpublished(created, kind: "assignment", path: { "\(self.course)/assignments/\($0)" }, wrapper: "assignment")
        if let week { try await addItemIfMissing(moduleID: try moduleID(week: week), type: "Assignment", contentID: id, title: name) }
        return id
    }

    public func setAssignment(id: Int, fields: [String: Any]) async throws {
        let path = "\(course)/assignments/\(id)"
        let current = try await getObject(path)
        try await write("PUT", path, body: ["assignment": fields], targetPublished: current["published"] as? Bool == true,
                        summary: "修改作業「\(current["name"] as? String ?? "\(id)")」")
    }

    // MARK: Announcements

    public func announcements() async throws -> [[String: Any]] {
        try await client.paginate(path: "\(course)/discussion_topics", query: ["only_announcements": "true"])
    }

    /// Posting notifies the whole class and cannot be recalled.
    public func postAnnouncement(_ file: AnnouncementFile) async throws -> Int {
        let created = try await write("POST", "\(course)/discussion_topics",
                                      body: ["title": file.title, "message": file.html, "is_announcement": true],
                                      alwaysVisible: true,
                                      summary: "發公告（全班通知，無法收回）",
                                      detail: "標題：\(file.title)\n\n\(file.bodyMarkdown)")
        guard let id = (created as? [String: Any])?["id"] as? Int else { throw CourseSessionError.unexpectedResponse("announcement id") }
        return id
    }

    /// Editing a posted announcement is publishing, too.
    public func editAnnouncement(id: Int, _ file: AnnouncementFile) async throws {
        try await write("PUT", "\(course)/discussion_topics/\(id)", body: ["title": file.title, "message": file.html],
                        alwaysVisible: true,
                        summary: "修改已發出的公告 \(id)",
                        detail: "標題：\(file.title)\n\n\(file.bodyMarkdown)")
    }

    // MARK: Enrollment

    public func enrollmentCounts() async throws -> EnrollmentCounts {
        let all = try await client.paginate(path: "\(course)/enrollments", query: ["state[]": "active"])
            + (try await client.paginate(path: "\(course)/enrollments", query: ["state[]": "invited"]))
        var seen = Set<Int>()
        var students = 0, invited = 0, teachers = 0, tas = 0
        for e in all {
            if let id = e["id"] as? Int, !seen.insert(id).inserted { continue }
            let type = e["type"] as? String, state = e["enrollment_state"] as? String
            switch (type, state) {
            case ("StudentEnrollment", "active"): students += 1
            case ("StudentEnrollment", "invited"): invited += 1
            case ("TeacherEnrollment", "active"): teachers += 1
            case ("TaEnrollment", "active"): tas += 1
            default: break
            }
        }
        return EnrollmentCounts(students: students, studentsInvited: invited, teachers: teachers, tas: tas)
    }
}

public enum PublishableKind: String, CaseIterable, Sendable {
    case module, item, quiz, assignment
}
