import Foundation
import CryptoKit

/// The confirmation gate for write operations, implementing the Foresay
/// confirmation protocol (`~/Developer/foresay`, core v5.0.0).
///
/// Foresay's workflow branches a "dryrun" on two properties — `clarity` and
/// `reversible` — and its `operation` rule is explicit: *"An irreversible
/// operation is never traceable — it always takes the confirm branch."* Posting
/// a grade or an announcement notifies students immediately, and a notification
/// cannot be un-sent, so both operations here are irreversible and both are
/// unconditionally gated. There is no scope threshold below which the gate is
/// skipped: scale is not what forces the branch, irreversibility is.
///
/// Foresay's own case study (`examples/email_archive_case_study.md`) names its
/// biggest limitation honestly: *"Foresay is a protocol, not a runtime. If the
/// host LLM doesn't follow it, Foresay itself has no recourse."* That case study
/// could only reach for a host-side commitment device (a task-tracker entry per
/// phase) because it did not control the client. This server does something
/// strictly stronger, because MCP elicitation lets the *server* put the
/// confirmation in front of the human directly:
///
///   Layer 1 — elicitation. `Server.requestElicitation` asks the user through
///   the client's own dialog. The model never sees a chance to skip it, because
///   it is not the model's decision to make; it cannot fabricate the answer
///   because the answer does not pass through it.
///
///   Layer 2 — the token in this file. A preview issues a token bound to the
///   *exact* payload it rendered. The write refuses any payload whose hash does
///   not match. This catches a different failure from layer 1: the human
///   approved grades `[85, 92, 78]`, and what actually reached the API was
///   `[85, 92, 87]`. Layer 1 cannot see that drift — the dialog would faithfully
///   display whatever it was handed. Layer 2 is what makes "what you approved"
///   and "what was written" the same object.
///
/// Neither layer subsumes the other, which is why both are here.
enum WriteGateError: Error, LocalizedError {
    case unknownOrExpiredToken
    case payloadMismatch
    case declined(String)
    case confirmationUnavailable

    var errorDescription: String? {
        switch self {
        case .unknownOrExpiredToken:
            return """
                No valid confirmation token. A write must be preceded by its preview \
                tool, and the token it returns expires after \(Int(WriteGate.defaultTTL / 60)) minutes and is \
                single-use. Run the preview again and pass the fresh token.
                """
        case .payloadMismatch:
            return """
                The payload does not match what this token previewed — refusing the write. \
                This is the guard against approving one thing and writing another. \
                The token has been consumed; run the preview again on the payload you \
                actually intend to write, so a human sees the corrected version.
                """
        case .declined(let how):
            return "Write refused: the user \(how) the confirmation dialog. Nothing was written."
        case .confirmationUnavailable:
            return """
                Write refused: this MCP client cannot show a confirmation dialog (it did not \
                declare the elicitation capability at connection time), so there is no way to \
                ask the user to approve a write that notifies students and cannot be undone. \
                Nothing was written. Use a client that supports elicitation (Claude Code does), \
                or make this change directly in NTU COOL where you can see what you are \
                approving. Do not report this as a transient error to retry — retrying will \
                refuse identically until the client changes.
                """
        }
    }
}

/// A write that has been rendered for a human but not yet performed.
///
/// The associated values are everything the write needs, so the hash covers the
/// whole operation — not a summary of it. A hash over a *rendering* would let
/// two different writes that happen to render alike share a token.
enum WritePayload: Sendable, Hashable {
    case grades(courseId: Int, assignmentId: Int, entries: [GradeEntry])
    case announcement(courseId: Int, title: String, message: String)

    /// Length-prefix every free-text field so no value can impersonate the
    /// delimiter structure. Without this, a title containing the separator could
    /// make two distinct payloads canonicalize identically.
    private static func lp(_ s: String) -> String { "\(s.utf8.count):\(s)" }

    var canonicalForm: String {
        switch self {
        case .grades(let courseId, let assignmentId, let entries):
            // Sorted so that argument order cannot change the hash — the same
            // three grades listed in a different order are the same write.
            let body = entries
                .sorted { $0.userId < $1.userId }
                .map { "\($0.userId)=\(Self.lp($0.grade))" }
                .joined(separator: ";")
            return "grades|\(courseId)|\(assignmentId)|\(body)"
        case .announcement(let courseId, let title, let message):
            return "announcement|\(courseId)|\(Self.lp(title))|\(Self.lp(message))"
        }
    }

    var payloadHash: String {
        SHA256.hash(data: Data(canonicalForm.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct GradeEntry: Sendable, Hashable {
    let userId: Int
    /// Kept as a String, not a Double: Canvas accepts points, percentages
    /// ("85%"), letter grades, and "pass"/"fail" in the same field. Parsing it
    /// into a number here would silently reject the ones this server has no
    /// business having an opinion about.
    let grade: String
}

/// Issues and redeems single-use, payload-bound, expiring confirmation tokens.
///
/// An `actor` because tool calls are dispatched concurrently by the MCP server
/// (each incoming message runs in its own `Task`), so two writes can be in
/// flight at once.
actor WriteGate {
    static let defaultTTL: TimeInterval = 600  // 10 minutes

    private struct Pending {
        let payloadHash: String
        let preview: String
        let createdAt: Date
    }

    private var pending: [String: Pending] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = WriteGate.defaultTTL) {
        self.ttl = ttl
    }

    func issue(for payload: WritePayload, preview: String, now: Date = Date()) -> String {
        purge(now: now)
        let token = "ntucool-confirm-" + UUID().uuidString
        pending[token] = Pending(payloadHash: payload.payloadHash, preview: preview, createdAt: now)
        return token
    }

    /// Redeem a token for the preview it was issued against.
    ///
    /// The token is consumed on *every* path, including a hash mismatch. That is
    /// deliberate: a mismatch means the payload drifted after a human looked at
    /// it, and letting the caller retry the same token with a corrected payload
    /// would write something no human ever saw. Burning it forces a fresh
    /// preview, which is the only way the correction gets seen.
    func consume(token: String, payload: WritePayload, now: Date = Date()) throws -> String {
        purge(now: now)
        guard let entry = pending.removeValue(forKey: token) else {
            throw WriteGateError.unknownOrExpiredToken
        }
        guard entry.payloadHash == payload.payloadHash else {
            throw WriteGateError.payloadMismatch
        }
        return entry.preview
    }

    private func purge(now: Date) {
        pending = pending.filter { now.timeIntervalSince($0.value.createdAt) < ttl }
    }

    /// Test seam.
    func pendingCount() -> Int { pending.count }
}

// MARK: - Foresay rendering

/// Renders the Foresay shapes. Kept separate from the gate so the wording is
/// readable as prose rather than buried in control flow.
enum Foresay {

    /// `confirmation_format_shapes.operation` — what *will* be done.
    ///
    /// The `residue` line is Foresay §4.6: the part of the request that could
    /// not be operationalized. For a grade post it is load-bearing rather than
    /// ceremonial — this server can verify that an assignment and a student
    /// exist, and it cannot verify that 85 is the score that student earned.
    /// Saying so is the difference between an honest reduction and a false
    /// claim of completeness.
    static func operationConfirmation(
        action: String,
        target: String,
        parameters: [String],
        scope: String,
        irreversibleBecause: String?,
        residue: String?
    ) -> String {
        var out = "I will perform:\n\n"
        out += "  \(action) on \(target)\n"
        for line in parameters {
            out += "  \(line)\n"
        }
        out += "\nThis will affect \(scope).\n"
        if let why = irreversibleBecause {
            out += "\n⚠ This cannot be undone: \(why)\n"
        }
        if let residue {
            out += "\nNot operationalized — you confirm this yourself: \(residue)\n"
        }
        out += "\nProceed?"
        return out
    }

    /// `report_format_shapes.operation` — what *was* done.
    ///
    /// Foresay assigns this shape to the run branch (`clear_and_reversible`),
    /// and leaves the confirm branch's completion output unspecified. Reusing it
    /// here is an extension, not a conformance claim. The rule it does carry is
    /// worth keeping either way: the confirmation says "will affect
    /// approximately", and a report that merely repeats that estimate is not a
    /// trace — so `scope` here must be the measured outcome.
    static func operationReport(
        action: String,
        target: String,
        scope: String,
        residue: String?
    ) -> String {
        var out = "Done:\n\n"
        out += "  \(action) on \(target)\n"
        out += "  affected \(scope)\n"
        if let residue {
            out += "\nNot operationalized — you confirm this yourself: \(residue)\n"
        }
        return out
    }
}
