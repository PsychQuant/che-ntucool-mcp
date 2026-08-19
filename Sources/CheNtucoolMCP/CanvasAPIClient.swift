import Foundation

/// Thin REST client for the Canvas LMS API as deployed at NTU COOL
/// (`https://cool.ntu.edu.tw`). NTU COOL is a customized Canvas deployment — see
/// PsychQuant/ntu-claude-plugins#17 for the verification that confirmed this
/// (login URL structure, `ntu-cool/canvas-rce-api` fork, and a live curl probe
/// against `/api/v1/courses` returning real course data).
///
/// Scope for v0.1.0: read-only. Grade/announcement *writes* are deliberately not
/// wired up yet — the risk of a misfire (wrong grade posted, wrong announcement
/// sent to a live class) is a teaching incident, not a bug. Read tools ship first;
/// write tools are a follow-up once the read path has been exercised for real.
public enum CanvasAPIError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Canvas API returned a non-HTTP response"
        case .httpError(let code, let body):
            return "Canvas API HTTP \(code): \(body.prefix(300))"
        case .decodingError(let detail):
            return "Failed to decode Canvas API response: \(detail)"
        }
    }
}

// MARK: - Response models (only the fields tools actually surface)

public struct CanvasCourse: Codable {
    public let id: Int
    public let name: String
    public let courseCode: String?
    public let workflowState: String?
    public let enrollmentTermId: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case courseCode = "course_code"
        case workflowState = "workflow_state"
        case enrollmentTermId = "enrollment_term_id"
    }
}

public struct CanvasAssignment: Codable {
    public let id: Int
    public let name: String
    public let dueAt: String?
    public let pointsPossible: Double?
    public let submissionTypes: [String]?
    /// Canvas posting policy. `true` means grades stay hidden from students
    /// until explicitly posted, which is the one case where writing a grade is
    /// *reversible* in Foresay's sense (nothing has been externally observed
    /// yet). Optional and treated as "assume visible" when absent — an unknown
    /// posting policy must fail toward the more cautious warning, not away
    /// from it.
    public let postManually: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case dueAt = "due_at"
        case pointsPossible = "points_possible"
        case submissionTypes = "submission_types"
        case postManually = "post_manually"
    }
}

public struct CanvasAnnouncement: Codable {
    public let id: Int
    public let title: String
    public let postedAt: String?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case id, title, message
        case postedAt = "posted_at"
    }
}

public struct CanvasSubmission: Codable {
    public let id: Int
    public let userId: Int
    public let assignmentId: Int
    public let submittedAt: String?
    public let score: Double?
    public let grade: String?
    public let workflowState: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case assignmentId = "assignment_id"
        case submittedAt = "submitted_at"
        case score, grade
        case workflowState = "workflow_state"
    }
}

public struct CanvasFile: Codable {
    public let id: Int
    public let displayName: String
    public let size: Int?
    public let url: String?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, size, url
        case displayName = "display_name"
        case createdAt = "created_at"
    }
}

public struct CanvasEnrollmentUser: Codable {
    public let id: Int
    public let name: String?
    public let sisUserId: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case sisUserId = "sis_user_id"
    }
}

public struct CanvasEnrollment: Codable {
    public let id: Int
    public let type: String
    public let enrollmentState: String?
    public let user: CanvasEnrollmentUser?

    enum CodingKeys: String, CodingKey {
        case id, type, user
        case enrollmentState = "enrollment_state"
    }
}

// MARK: - Client

public final class CanvasAPIClient {
    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - baseURL: Canvas API root, e.g. `https://cool.ntu.edu.tw/api/v1`.
    ///     Kept configurable (not hardcoded) so the client can be pointed at
    ///     another Canvas instance during testing without a code change.
    ///   - token: Personal Access Token, read by the caller from Keychain
    ///     (`CanvasAuth.read`) — never accepted as a literal here to keep this
    ///     class free of any credential-sourcing decision.
    public init(baseURL: URL = URL(string: "https://cool.ntu.edu.tw/api/v1")!, token: String) {
        self.baseURL = baseURL
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }

    /// Percent-encoding for `application/x-www-form-urlencoded` bodies.
    ///
    /// `.urlQueryAllowed` is not sufficient on its own: it permits `+`, `&` and
    /// `=`, all of which are structural in a form body. A grade of "85+" or an
    /// announcement containing "&" would otherwise corrupt the request.
    private static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func send<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        form: [(String, String)]? = nil
    ) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw CanvasAPIError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(
                form.map { "\(Self.formEscape($0.0))=\(Self.formEscape($0.1))" }
                    .joined(separator: "&")
                    .utf8
            )
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CanvasAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw CanvasAPIError.httpError(httpResponse.statusCode, body)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CanvasAPIError.decodingError(String(describing: error))
        }
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send("GET", path, query: query)
    }

    public func listCourses(perPage: Int = 50) async throws -> [CanvasCourse] {
        try await get("courses", query: ["per_page": "\(perPage)"])
    }

    public func listAssignments(courseId: Int, perPage: Int = 50) async throws -> [CanvasAssignment] {
        try await get("courses/\(courseId)/assignments", query: ["per_page": "\(perPage)"])
    }

    public func listAnnouncements(courseId: Int, perPage: Int = 50) async throws -> [CanvasAnnouncement] {
        try await get(
            "courses/\(courseId)/discussion_topics",
            query: ["only_announcements": "true", "per_page": "\(perPage)"]
        )
    }

    public func listSubmissions(courseId: Int, perPage: Int = 50) async throws -> [CanvasSubmission] {
        try await get(
            "courses/\(courseId)/students/submissions",
            query: ["student_ids[]": "all", "per_page": "\(perPage)"]
        )
    }

    public func listFiles(courseId: Int, perPage: Int = 50) async throws -> [CanvasFile] {
        try await get("courses/\(courseId)/files", query: ["per_page": "\(perPage)"])
    }

    public func listEnrollments(courseId: Int, perPage: Int = 50) async throws -> [CanvasEnrollment] {
        try await get("courses/\(courseId)/enrollments", query: ["per_page": "\(perPage)"])
    }

    // MARK: - Detail reads
    //
    // These exist to make a *preview* worth reading. A confirmation that echoes
    // back the ids the caller already supplied confirms nothing; the human needs
    // the course name, the assignment name, and the grade each student holds
    // right now in order to spot a mistake.

    public func getCourse(courseId: Int) async throws -> CanvasCourse {
        try await get("courses/\(courseId)")
    }

    public func getAssignment(courseId: Int, assignmentId: Int) async throws -> CanvasAssignment {
        try await get("courses/\(courseId)/assignments/\(assignmentId)")
    }

    public func getSubmission(courseId: Int, assignmentId: Int, userId: Int) async throws -> CanvasSubmission {
        try await get("courses/\(courseId)/assignments/\(assignmentId)/submissions/\(userId)")
    }

    public func getUser(userId: Int) async throws -> CanvasEnrollmentUser {
        try await get("users/\(userId)")
    }

    // MARK: - Writes
    //
    // Nothing here performs its own confirmation. These are the raw effects; the
    // gate that decides whether a human has approved them lives in the tool
    // layer (Server.swift) so that the confirmation cannot be bypassed by
    // calling a "lower-level" method. Keeping the policy out of this file is
    // deliberate — but it does mean these must never be exposed as tools
    // directly.

    public func updateSubmissionGrade(
        courseId: Int,
        assignmentId: Int,
        userId: Int,
        grade: String
    ) async throws -> CanvasSubmission {
        try await send(
            "PUT",
            "courses/\(courseId)/assignments/\(assignmentId)/submissions/\(userId)",
            form: [("submission[posted_grade]", grade)]
        )
    }

    public func createAnnouncement(
        courseId: Int,
        title: String,
        message: String
    ) async throws -> CanvasAnnouncement {
        try await send(
            "POST",
            "courses/\(courseId)/discussion_topics",
            form: [
                ("title", title),
                ("message", message),
                ("is_announcement", "true"),
            ]
        )
    }
}
