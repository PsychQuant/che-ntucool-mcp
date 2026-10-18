import Foundation

/// RFC 4180 field quoting for the one CSV the CLI appends to.
public enum CSV {
    public static func field(_ value: String) -> String {
        // Scalars, not Characters: "\r\n" is a single Character in Swift and
        // equals neither "\r" nor "\n".
        guard value.unicodeScalars.contains(where: { ",\"\r\n".unicodeScalars.contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
