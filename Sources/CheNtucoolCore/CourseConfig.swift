import Foundation

/// Per-course settings for the CLI (`ntucool.json`), so weekly commands can
/// say "W03" instead of a Canvas module id.
///
/// ```json
/// {
///   "course_id": 64652,
///   "modules": { "W01": 946894, "W02": 946895 },
///   "title_formats": { "quiz": "W{week} 隨堂測驗" },
///   "timezone": "+08:00"
/// }
/// ```
///
/// Resolution order: `--config` path → `$CHE_NTUCOOL_CONFIG` → `./ntucool.json`.
/// Times in the file and on the command line are read in `timezone`, which
/// defaults to Taipei (`+08:00`) — a bare timestamp silently read as UTC is
/// exactly the eight-hour mistake the global CLAUDE.md warns about.
public struct CourseConfig: Codable, Equatable, Sendable {
    public let courseId: Int
    /// Week label → Canvas module id, e.g. `"W01": 946894`.
    public let modules: [String: Int]
    /// Optional title templates keyed by item kind; `{week}` is substituted.
    public let titleFormats: [String: String]?
    /// ISO 8601 UTC offset, e.g. `+08:00`.
    public let timezone: String

    public static let defaultTimezone = "+08:00"
    public static let environmentKey = "CHE_NTUCOOL_CONFIG"
    public static let defaultFileName = "ntucool.json"

    enum CodingKeys: String, CodingKey {
        case courseId = "course_id"
        case modules
        case titleFormats = "title_formats"
        case timezone
    }

    public init(courseId: Int, modules: [String: Int], titleFormats: [String: String]? = nil, timezone: String = defaultTimezone) {
        self.courseId = courseId
        self.modules = modules
        self.titleFormats = titleFormats
        self.timezone = timezone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        courseId = try c.decode(Int.self, forKey: .courseId)
        modules = try c.decodeIfPresent([String: Int].self, forKey: .modules) ?? [:]
        titleFormats = try c.decodeIfPresent([String: String].self, forKey: .titleFormats)
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? Self.defaultTimezone
    }

    // MARK: Loading

    /// Production entry point: reads the process environment and current
    /// directory.
    public static func load(explicitPath: String?) throws -> CourseConfig {
        try load(
            explicitPath: explicitPath,
            environment: ProcessInfo.processInfo.environment,
            cwd: FileManager.default.currentDirectoryPath
        )
    }

    /// Testable variant with the lookup inputs injected.
    public static func load(explicitPath: String?, environment: [String: String], cwd: String) throws -> CourseConfig {
        let candidates: [String]
        if let explicitPath {
            candidates = [explicitPath]
        } else if let fromEnv = environment[environmentKey], !fromEnv.isEmpty {
            candidates = [fromEnv]
        } else {
            candidates = [(cwd as NSString).appendingPathComponent(defaultFileName)]
        }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw CourseConfigError.notFound(searched: candidates)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw CourseConfigError.invalid(at: path, detail: String(describing: error))
        }
        do {
            return try JSONDecoder().decode(CourseConfig.self, from: data)
        } catch {
            throw CourseConfigError.invalid(at: path, detail: String(describing: error))
        }
    }
}

public enum CourseConfigError: Error, LocalizedError, Equatable {
    case notFound(searched: [String])
    case invalid(at: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let searched):
            return """
            找不到課程設定檔。查過：\(searched.joined(separator: ", "))。
            提供方式（依優先序）：--config <path>、環境變數 \(CourseConfig.environmentKey)、或目前目錄的 \(CourseConfig.defaultFileName)。
            """
        case .invalid(let path, let detail):
            return "課程設定檔 \(path) 無法解析：\(detail.prefix(300))"
        }
    }
}
