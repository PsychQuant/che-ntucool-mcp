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

    enum CodingKeys: String, CodingKey {
        case id, name
        case dueAt = "due_at"
        case pointsPossible = "points_possible"
        case submissionTypes = "submission_types"
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

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw CanvasAPIError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

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
}
