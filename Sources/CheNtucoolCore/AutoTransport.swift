import Foundation

/// The credential ladder: use the keychain token while it works, fall back to
/// the Safari session when the token is missing or rejected, and stay there.
///
/// Why a ladder rather than "always Safari": the token path needs no Safari
/// window, no Automation permission and no JavaScript-from-Apple-Events
/// setting, so when a fresh token exists it is the quieter path. Why fall
/// back at all: NTU COOL's manually issued tokens expire after roughly an
/// hour (PsychQuant/che-ntucool-mcp#1), so a token-only client fails daily.
///
/// The decision is made on the first request and the 401 fallback replays
/// that request on Safari, so callers never see the switch except as a
/// couple of lines on stderr.
///
/// Two things keep the fallback from failing *open*:
///
/// * Only a credential rejection switches. Canvas answers 401 both for a
///   dead token ("Invalid access token.") and for a permission refusal
///   ("user not authorized to perform that action"). Replaying the second
///   kind on Safari would retry the request as whoever a Safari tab is
///   logged in as — this Mac has several Safari profiles.
/// * Before the first request on Safari, `GET /users/self` names the
///   session's owner. It is always logged; with `expectedUserID` set, a
///   different id refuses the request and every later one in this process.
public final class AutoTransport: CanvasTransport, @unchecked Sendable {
    public typealias TokenProvider = @Sendable () throws -> String?
    public typealias TokenTransportFactory = @Sendable (String) -> CanvasTransport
    public typealias SafariFactory = @Sendable () -> CanvasTransport
    public typealias Log = @Sendable (String) -> Void

    private enum State {
        case undecided
        case token(CanvasTransport)
        /// Safari chosen, owner not yet checked.
        case safariUnverified(CanvasTransport)
        case safari(CanvasTransport)
        /// Safari is someone else's session. Terminal for this process.
        case refused(CanvasTransportError)
    }

    private let tokenProvider: TokenProvider
    private let tokenTransportFactory: TokenTransportFactory
    private let safariFactory: SafariFactory
    private let log: Log
    private let expectedUserID: Int?
    private let lock = NSLock()
    private var state: State = .undecided

    /// - Parameters:
    ///   - tokenProvider: returns the Personal Access Token, or nil when the
    ///     keychain has none. A thrown error is treated as "no token" (and
    ///     logged) — a locked keychain must not block the Safari path.
    ///   - tokenTransportFactory: builds the bearer transport; injectable for tests.
    ///   - safariFactory: builds the Safari transport lazily, only when needed.
    ///   - expectedUserID: Canvas user id the Safari session must belong to;
    ///     nil logs the owner without enforcing it.
    ///   - log: one-line diagnostics; defaults to stderr.
    public init(
        tokenProvider: @escaping TokenProvider,
        tokenTransportFactory: @escaping TokenTransportFactory = { TokenTransport(token: $0) },
        safariFactory: @escaping SafariFactory = { SafariSessionTransport() },
        expectedUserID: Int? = nil,
        log: @escaping Log = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.tokenProvider = tokenProvider
        self.tokenTransportFactory = tokenTransportFactory
        self.safariFactory = safariFactory
        self.expectedUserID = expectedUserID
        self.log = log
    }

    /// Which rung the ladder is on, for diagnostics ("token", "safari", or
    /// nil before the first request).
    public var activeRung: String? {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .undecided: return nil
        case .token: return "token"
        case .safari, .safariUnverified: return "safari"
        case .refused: return "refused"
        }
    }

    public func send(method: String, path: String, query: [String: String], jsonBody: Data?) async throws -> CanvasResponse {
        switch decide() {
        case .token(let token):
            let response = try await token.send(method: method, path: path, query: query, jsonBody: jsonBody)
            guard Self.isCredentialRejection(response) else { return response }
            switchToSafari(reason: "keychain token 被 NTU COOL 拒絕（HTTP 401）")
            return try await send(method: method, path: path, query: query, jsonBody: jsonBody)
        case .safariUnverified(let safari):
            try await verifyIdentity(of: safari)
            return try await send(method: method, path: path, query: query, jsonBody: jsonBody)
        case .safari(let safari):
            return try await safari.send(method: method, path: path, query: query, jsonBody: jsonBody)
        case .refused(let error):
            throw error
        case .undecided:
            preconditionFailure("decide() never returns .undecided")
        }
    }

    /// 401 that means "this credential is dead", as opposed to "this user may
    /// not do that". Canvas's bodies: `Invalid access token.` (bad or expired
    /// token) and `"status":"unauthenticated"` (no credential). A permission
    /// refusal carries `"status":"unauthorized"` and must not switch.
    static func isCredentialRejection(_ response: CanvasResponse) -> Bool {
        guard response.status == 401 else { return false }
        let text = String(decoding: response.body, as: UTF8.self).lowercased()
        return text.contains("access token") || text.contains("unauthenticated")
    }

    /// Ask the Safari session who it is. Logs the owner; with
    /// `expectedUserID` set, a mismatch parks the ladder in `.refused`.
    /// A failed probe throws without changing state, so the next call retries.
    private func verifyIdentity(of safari: CanvasTransport) async throws {
        let response = try await safari.send(method: "GET", path: "users/self", query: [:], jsonBody: nil)
        guard response.status == 200,
              let obj = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let id = obj["id"] as? Int
        else {
            throw CanvasTransportError.identityProbeFailed(
                response.status == 200 ? "回應沒有 user id" : "HTTP \(response.status)")
        }
        commitIdentity(of: safari, id: id, name: obj["name"] as? String)
    }

    private func commitIdentity(of safari: CanvasTransport, id: Int, name: String?) {
        lock.lock(); defer { lock.unlock() }
        guard case .safariUnverified = state else { return }
        if let expectedUserID, expectedUserID != id {
            let error = CanvasTransportError.identityMismatch(expected: expectedUserID, actual: id, name: name)
            log("che-ntucool: \(error.localizedDescription)")
            state = .refused(error)
            return
        }
        log("che-ntucool: Safari 登入者 \(name ?? "?")（id \(id)）")
        state = .safari(safari)
    }

    // MARK: State transitions

    private func decide() -> State {
        lock.lock(); defer { lock.unlock() }
        if case .undecided = state {
            let token: String?
            var failure: String? = nil
            do {
                token = try tokenProvider()
            } catch {
                token = nil
                failure = String(describing: error)
            }
            if let token, !token.isEmpty {
                state = .token(tokenTransportFactory(token))
            } else {
                let reason = failure.map { "keychain 讀取失敗：\($0)" } ?? "keychain 沒有 NTU COOL token"
                state = .safariUnverified(makeSafari(reason: reason))
            }
        }
        return state
    }

    private func switchToSafari(reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard case .token = state else { return }
        state = .safariUnverified(makeSafari(reason: reason))
    }

    /// Caller must hold `lock`.
    private func makeSafari(reason: String) -> CanvasTransport {
        log("che-ntucool: \(reason)；改用 Safari 已登入的 COOL 分頁（NTU COOL 手動 token 約一小時失效，這是預期行為）")
        return safariFactory()
    }
}
