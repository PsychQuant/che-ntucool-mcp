import Foundation

public enum AnnouncementFileError: Error, LocalizedError, Equatable {
    case missingTitle
    case missingBody

    public var errorDescription: String? {
        switch self {
        case .missingTitle: return "公告檔沒有「# 標題」一行"
        case .missingBody: return "公告檔沒有「## 正文」段，或正文是空的"
        }
    }
}

/// One file under the course repo's `announcements/`: optional front matter
/// (`status:` …), a `# ` title line, and a `## 正文` section — the only part
/// that is posted. Every other `## ` section (the rationale, follow-ups,
/// revisions) is for the author and never leaves the file.
public struct AnnouncementFile: Equatable, Sendable {
    public let title: String
    public let status: String?
    public let bodyMarkdown: String

    public var html: String { Markdown.blocks(bodyMarkdown) }

    public static func parse(_ source: String) throws -> AnnouncementFile {
        let lines = source.components(separatedBy: "\n")
        var status: String?
        if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") {
            for line in lines[1..<close] where line.hasPrefix("status:") {
                status = line.dropFirst("status:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let titleLine = lines.first(where: { $0.hasPrefix("# ") }) else { throw AnnouncementFileError.missingTitle }
        let title = String(titleLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard let body = QuizMarkdown.section(source, startingWith: "## 正文", stopAtRule: false), !body.isEmpty else {
            throw AnnouncementFileError.missingBody
        }
        return AnnouncementFile(title: title, status: status, bodyMarkdown: body)
    }
}
