import Foundation

/// Thin REST client for the Canvas LMS API as deployed at NTU COOL
/// (`https://cool.ntu.edu.tw`). NTU COOL is a customized Canvas deployment — see
/// PsychQuant/ntu-claude-plugins#17 for the verification that confirmed this
/// (login URL structure, `ntu-cool/canvas-rce-api` fork, and a live curl probe
/// against `/api/v1/courses` returning real course data).
///
/// Scope: reads are unguarded. Grade/announcement *writes* landed in v0.2.0 but
/// never fire on a model decision alone — the risk of a misfire (wrong grade
/// posted, wrong announcement sent to a live class) is a teaching incident, not a
/// bug. See WriteGate.swift for the two layers that gate them.
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

/// Wraps a `CanvasTransport` with JSON encoding, error mapping and
/// pagination. Credential choice lives entirely in the transport (see
/// `AutoTransport`); this class never sees a token.
public final class CanvasAPIClient: @unchecked Sendable {
    public let transport: CanvasTransport
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(transport: CanvasTransport) {
        self.transport = transport
    }

    /// Bearer-token client (the pre-ladder behaviour). Kept so callers that
    /// already hold a token — and tests pointing at another Canvas instance
    /// via `baseURL` — need no change.
    public convenience init(baseURL: URL = CanvasURL.defaultAPIBase, token: String) {
        self.init(transport: TokenTransport(token: token, baseURL: baseURL))
    }

    // MARK: Generic requests

    /// One request, raw JSON back. HTTP ≥ 400 becomes `CanvasAPIError.httpError`.
    public func request(
        _ method: String,
        path: String,
        query: [String: String] = [:],
        json: Encodable? = nil
    ) async throws -> Data {
        let body = try json.map { try encoder.encode(AnyEncodable($0)) }
        let response = try await transport.send(method: method, path: path, query: query, jsonBody: body)
        guard response.status < 400 else {
            let text = String(data: response.body, encoding: .utf8) ?? "<non-utf8 body>"
            throw CanvasAPIError.httpError(response.status, text)
        }
        return response.body
    }

    /// One request with a `JSONSerialization` body; the parsed response back
    /// (`NSNull` for an empty body). For the CLI, whose payloads are built
    /// as dictionaries so the publish gate can inspect them before sending.
    public func sendJSON(_ method: String, path: String, query: [String: String] = [:], object: Any?) async throws -> Any {
        let body = try object.map { try JSONSerialization.data(withJSONObject: $0) }
        let response = try await transport.send(method: method, path: path, query: query, jsonBody: body)
        guard response.status < 400 else {
            throw CanvasAPIError.httpError(response.status, String(data: response.body, encoding: .utf8) ?? "<non-utf8 body>")
        }
        guard !response.body.isEmpty else { return NSNull() }
        do {
            return try JSONSerialization.jsonObject(with: response.body, options: [.fragmentsAllowed])
        } catch {
            throw CanvasAPIError.decodingError("non-JSON response from \(path)")
        }
    }

    /// GET every page of a list endpoint by following `Link: rel="next"`,
    /// asking for 100 per page. Returns the concatenated JSON objects.
    public func paginate(path: String, query: [String: String] = [:]) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        for page in try await paginatePages(path: path, query: query) {
            guard let array = try JSONSerialization.jsonObject(with: page) as? [[String: Any]] else {
                throw CanvasAPIError.decodingError("expected a JSON array from \(path)")
            }
            items.append(contentsOf: array)
        }
        return items
    }

    /// Typed variant of `paginate`.
    public func paginateDecoded<T: Decodable>(path: String, query: [String: String] = [:]) async throws -> [T] {
        var items: [T] = []
        for page in try await paginatePages(path: path, query: query) {
            items.append(contentsOf: try decode([T].self, from: page))
        }
        return items
    }

    /// Raw pages, in order. The first request carries `query` plus
    /// `per_page=100`; subsequent ones use the server's `next` URL verbatim.
    public func paginatePages(path: String, query: [String: String] = [:]) async throws -> [Data] {
        var pages: [Data] = []
        var firstQuery = query
        firstQuery["per_page"] = firstQuery["per_page"] ?? "100"
        var next: (path: String, query: [String: String])? = (path, firstQuery)
        while let current = next {
            let response = try await transport.send(method: "GET", path: current.path, query: current.query, jsonBody: nil)
            guard response.status < 400 else {
                throw CanvasAPIError.httpError(response.status, String(data: response.body, encoding: .utf8) ?? "<non-utf8 body>")
            }
            pages.append(response.body)
            next = response.nextURL.map { ($0, [:]) }
        }
        return pages
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw CanvasAPIError.decodingError(String(describing: error))
        }
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try decode(T.self, from: try await request("GET", path: path, query: query))
    }

    // MARK: Typed reads (thin wrappers)

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
        struct Payload: Encodable { let submission: [String: String] }
        let data = try await request(
            "PUT",
            path: "courses/\(courseId)/assignments/\(assignmentId)/submissions/\(userId)",
            json: Payload(submission: ["posted_grade": grade])
        )
        return try decode(CanvasSubmission.self, from: data)
    }

    public func createAnnouncement(
        courseId: Int,
        title: String,
        message: String
    ) async throws -> CanvasAnnouncement {
        struct Payload: Encodable {
            let title: String
            let message: String
            let is_announcement: Bool
        }
        let data = try await request(
            "POST",
            path: "courses/\(courseId)/discussion_topics",
            json: Payload(title: title, message: message, is_announcement: true)
        )
        return try decode(CanvasAnnouncement.self, from: data)
    }
}

/// Type-erasing box so `request(json:)` can take any `Encodable`.
struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void
    init(_ value: Encodable) { encodeImpl = value.encode }
    func encode(to encoder: Encoder) throws { try encodeImpl(encoder) }
}
