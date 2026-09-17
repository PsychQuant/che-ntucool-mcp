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
/// that request on Safari, so callers never see the switch except as one
/// line on stderr.
public final class AutoTransport: CanvasTransport, @unchecked Sendable {
    public typealias TokenProvider = @Sendable () throws -> String?
    public typealias TokenTransportFactory = @Sendable (String) -> CanvasTransport
    public typealias SafariFactory = @Sendable () -> CanvasTransport
    public typealias Log = @Sendable (String) -> Void

    private enum State {
        case undecided
        case token(CanvasTransport)
        case safari(CanvasTransport)
    }

    private let tokenProvider: TokenProvider
    private let tokenTransportFactory: TokenTransportFactory
    private let safariFactory: SafariFactory
    private let log: Log
    private let lock = NSLock()
    private var state: State = .undecided

    /// - Parameters:
    ///   - tokenProvider: returns the Personal Access Token, or nil when the
    ///     keychain has none. A thrown error is treated as "no token" (and
    ///     logged) — a locked keychain must not block the Safari path.
    ///   - tokenTransportFactory: builds the bearer transport; injectable for tests.
    ///   - safariFactory: builds the Safari transport lazily, only when needed.
    ///   - log: one-line diagnostics; defaults to stderr.
    public init(
        tokenProvider: @escaping TokenProvider,
        tokenTransportFactory: @escaping TokenTransportFactory = { TokenTransport(token: $0) },
        safariFactory: @escaping SafariFactory = { SafariSessionTransport() },
        log: @escaping Log = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.tokenProvider = tokenProvider
        self.tokenTransportFactory = tokenTransportFactory
        self.safariFactory = safariFactory
        self.log = log
    }

    /// Which rung the ladder is on, for diagnostics ("token", "safari", or
    /// nil before the first request).
    public var activeRung: String? {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .undecided: return nil
        case .token: return "token"
        case .safari: return "safari"
        }
    }

    public func send(method: String, path: String, query: [String: String], jsonBody: Data?) async throws -> CanvasResponse {
        switch decide() {
        case .safari(let safari):
            return try await safari.send(method: method, path: path, query: query, jsonBody: jsonBody)
        case .token(let token):
            let response = try await token.send(method: method, path: path, query: query, jsonBody: jsonBody)
            guard response.status == 401 else { return response }
            let safari = switchToSafari(reason: "keychain token 被 NTU COOL 拒絕（HTTP 401）")
            return try await safari.send(method: method, path: path, query: query, jsonBody: jsonBody)
        case .undecided:
            preconditionFailure("decide() never returns .undecided")
        }
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
                state = .safari(makeSafari(reason: reason))
            }
        }
        return state
    }

    private func switchToSafari(reason: String) -> CanvasTransport {
        lock.lock(); defer { lock.unlock() }
        if case .safari(let existing) = state { return existing }
        let safari = makeSafari(reason: reason)
        state = .safari(safari)
        return safari
    }

    /// Caller must hold `lock`.
    private func makeSafari(reason: String) -> CanvasTransport {
        log("che-ntucool: \(reason)；改用 Safari 已登入的 COOL 分頁（NTU COOL 手動 token 約一小時失效，這是預期行為）")
        return safariFactory()
    }
}
