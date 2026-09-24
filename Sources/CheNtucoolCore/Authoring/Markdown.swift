import Foundation

/// The small Markdown subset the course files use (bold, italic, bare URLs,
/// paragraphs, `- ` lists), rendered to the HTML Canvas stores. Ported from
/// `md_inline` in the course repo's `cool_build.py` so the two render alike.
public enum Markdown {
    private static let bold = try! NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#)
    private static let italic = try! NSRegularExpression(pattern: #"\*([^*]+)\*"#)
    private static let url = try! NSRegularExpression(pattern: #"(https?://[^\s<]+)"#)

    public static func inline(_ text: String) -> String {
        var s = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        s = replace(bold, in: s, with: "<strong>$1</strong>")
        s = replace(italic, in: s, with: "<em>$1</em>")
        s = replace(url, in: s, with: #"<a href="$1">$1</a>"#)
        return s
    }

    /// Blank-line separated blocks; a block whose every line starts with
    /// `- ` is a list, anything else a paragraph with `<br>` line breaks.
    public static func blocks(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var html = ""
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !lines.isEmpty else { continue }
            if lines.allSatisfy({ $0.hasPrefix("- ") }) {
                html += "<ul>" + lines.map { "<li>\(inline(String($0.dropFirst(2))))</li>" }.joined() + "</ul>"
            } else {
                html += "<p>" + lines.map(inline).joined(separator: "<br>") + "</p>"
            }
        }
        return html
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
