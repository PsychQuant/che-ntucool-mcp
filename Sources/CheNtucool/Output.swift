import CheNtucoolCore
import Foundation

enum Output {
    static func json(_ object: Any) {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: options) {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    static func pub(_ obj: [String: Any]) -> String {
        obj["published"] as? Bool == true ? "pub" : "unpub"
    }

    static func name(_ obj: [String: Any]) -> String {
        (obj["title"] ?? obj["name"] ?? obj["display_name"]) as? String ?? "?"
    }

    /// Text rendering of `CourseSession.state()`, the same shape as
    /// `cool_build.py state` so the two can be compared line by line.
    static func stateText(_ state: [String: Any], offset: String) -> String {
        var lines: [String] = []
        for m in state["modules"] as? [[String: Any]] ?? [] {
            lines.append("\(m["id"] ?? "?")\t\(name(m))\t\(pub(m))")
            for item in m["items"] as? [[String: Any]] ?? [] {
                lines.append("    \(item["id"] ?? "?")\t\(item["type"] ?? "?")\t\(name(item))\t\(pub(item))")
            }
        }
        for kind in ["discussion_topics", "quizzes", "assignments"] {
            lines.append("== \(kind)")
            for x in state[kind] as? [[String: Any]] ?? [] {
                let due = TimeInput.display(x["due_at"] as? String, offset: offset)
                lines.append("  \(x["id"] ?? "?")\t\(name(x))\t\(pub(x))\t\(due)")
            }
        }
        lines.append("== files")
        for f in state["files"] as? [[String: Any]] ?? [] {
            lines.append("  \(f["id"] ?? "?")\t\(name(f))\t\(f["size"] ?? "")")
        }
        return lines.joined(separator: "\n")
    }
}
