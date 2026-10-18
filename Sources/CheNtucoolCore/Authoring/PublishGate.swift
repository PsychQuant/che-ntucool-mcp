import Foundation

public enum PublishGateError: Error, LocalizedError, Equatable {
    case environmentMissing
    case declined
    case noConfirmation

    public var errorDescription: String? {
        switch self {
        case .environmentMissing:
            return "這個動作會讓學生看得到（發布或公告）。要送出請在指令前加 \(PublishGate.environmentKey)=1，並先把最終版給使用者確認"
        case .declined:
            return "已取消，沒有送出"
        case .noConfirmation:
            return "沒有終端機可以詢問，也沒有 --yes；不會假設同意，沒有送出"
        }
    }
}

/// The CLI's publish gate. Same contract as the course repo's
/// `scripts/cool_build.py`: a write whose JSON body makes anything
/// student-visible needs `COOL_ALLOW_PUBLISH=1` in the environment. That
/// variable is what the repo's PreToolUse hook (`cool-publish-ask.sh`)
/// watches for, so a publish from an agent always surfaces a human prompt;
/// accepting `--yes` alone would be a way around that hook.
///
/// Visibility is judged from the body actually sent, not from which
/// subcommand ran — the 2026-09-19 incident was a module-item PUT that
/// published content nobody meant to publish.
public enum PublishGate {
    public static let environmentKey = "COOL_ALLOW_PUBLISH"

    /// True when any level of `json` carries `"published": true` or
    /// `"is_announcement": true` as a JSON boolean.
    public static func isStudentVisible(_ json: Any) -> Bool {
        if let dict = json as? [String: Any] {
            return dict.contains { key, value in
                ((key == "published" || key == "is_announcement") && isTrueBoolean(value)) || isStudentVisible(value)
            }
        }
        if let array = json as? [Any] {
            return array.contains(where: isStudentVisible)
        }
        return false
    }

    /// Throws unless a student-visible write is authorised.
    /// - Parameter confirm: asks the human; returns nil when there is no
    ///   terminal to ask on.
    public static func authorize(
        visible: Bool,
        environment: [String: String],
        assumeYes: Bool,
        confirm: () -> Bool?
    ) throws {
        guard visible else { return }
        guard environment[environmentKey] == "1" else { throw PublishGateError.environmentMissing }
        if assumeYes { return }
        switch confirm() {
        case .some(true): return
        case .some(false): throw PublishGateError.declined
        case .none: throw PublishGateError.noConfirmation
        }
    }

    /// `NSNumber(1)` bridges to `Bool` too; only a real boolean counts.
    private static func isTrueBoolean(_ value: Any) -> Bool {
        if let b = value as? Bool, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() { return b }
        return false
    }
}
