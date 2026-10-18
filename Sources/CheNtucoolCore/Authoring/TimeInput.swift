import Foundation

public enum TimeInputError: Error, LocalizedError, Equatable {
    case unparseable(String)

    public var errorDescription: String? {
        switch self {
        case .unparseable(let s):
            return "看不懂時間「\(s)」：請寫成 2026-09-30T11:55（用設定檔的時區）或帶時區 2026-09-30T11:55:00+08:00"
        }
    }
}

/// Times typed on the command line. A bare timestamp is read in the course's
/// offset (Taipei by default) and always leaves with an explicit offset — a
/// bare value sent to Canvas is read as UTC, eight hours off.
public enum TimeInput {
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?(Z|[+-]\d{2}:\d{2})?$"#
    )

    public static func normalize(_ raw: String, offset: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let range = NSRange(s.startIndex..., in: s)
        guard let m = pattern.firstMatch(in: s, range: range) else { throw TimeInputError.unparseable(raw) }
        func group(_ i: Int) -> String? {
            Range(m.range(at: i), in: s).map { String(s[$0]) }
        }
        let (y, mo, d, h, mi) = (group(1)!, group(2)!, group(3)!, group(4)!, group(5)!)
        let sec = group(6) ?? "00"
        let zone = group(7) ?? offset

        var components = DateComponents()
        components.year = Int(y); components.month = Int(mo); components.day = Int(d)
        components.hour = Int(h); components.minute = Int(mi); components.second = Int(sec)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard components.isValidDate(in: calendar) else { throw TimeInputError.unparseable(raw) }
        return "\(y)-\(mo)-\(d)T\(h):\(mi):\(sec)\(zone)"
    }

    /// Canvas returns UTC (`…Z`); show it in the course offset.
    public static func display(_ iso: String?, offset: String) -> String {
        guard let iso else { return "—" }
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso), let tz = timeZone(offset) else { return iso }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = tz
        out.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(out.string(from: date)) \(offset)"
    }

    public static func timeZone(_ offset: String) -> TimeZone? {
        guard offset.count == 6, let sign = offset.first, sign == "+" || sign == "-",
              let h = Int(offset.dropFirst().prefix(2)), let m = Int(offset.suffix(2)) else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (h * 3600 + m * 60))
    }
}
