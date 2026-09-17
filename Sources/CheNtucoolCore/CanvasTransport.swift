import Foundation

// MARK: - Transport abstraction
//
// A "transport" is one way of getting an HTTP request to NTU COOL with a
// credential attached. Two exist:
//
//   * `TokenTransport`  — bearer Personal Access Token over URLSession. NTU
//     COOL's manually issued tokens expire after roughly an hour (see
//     PsychQuant/che-ntucool-mcp#1), so on its own this is a daily 401.
//   * `SafariSessionTransport` — same-origin XMLHttpRequest executed inside an
//     already-logged-in Safari tab via AppleScript, riding the session cookie.
//
// `AutoTransport` picks between them at first use ("the ladder"). The client
// above (`CanvasAPIClient`) only ever sees the protocol.

/// Raw outcome of one HTTP exchange. Status is carried, not thrown, because
/// the ladder needs to *see* a 401 to know when to switch credentials.
public struct CanvasResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data
    /// Verbatim `Link` header (Canvas pagination), if the server sent one.
    public let link: String?

    public init(status: Int, body: Data, link: String?) {
        self.status = status
        self.body = body
        self.link = link
    }

    /// URL of the `rel="next"` entry in the `Link` header, or nil on the last
    /// page (or when there is no header).
    public var nextURL: String? {
        guard let link else { return nil }
        for part in link.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2,
                  pieces.dropFirst().contains(where: { $0 == #"rel="next""# }),
                  pieces[0].hasPrefix("<"), pieces[0].hasSuffix(">")
            else { continue }
            return String(pieces[0].dropFirst().dropLast())
        }
        return nil
    }
}

public protocol CanvasTransport: Sendable {
    /// - Parameters:
    ///   - method: HTTP verb, upper-case.
    ///   - path: either a path relative to `/api/v1/` (a leading `/` or an
    ///     `api/v1/` prefix is tolerated) or an absolute URL — Canvas
    ///     pagination hands back absolute `next` URLs and callers pass them
    ///     straight through.
    ///   - query: extra query items; merged after whatever `path` carries.
    ///   - jsonBody: pre-encoded JSON, sent with `Content-Type: application/json`.
    func send(method: String, path: String, query: [String: String], jsonBody: Data?) async throws -> CanvasResponse
}

public enum CanvasTransportError: Error, LocalizedError, Equatable {
    case invalidResponse
    /// No Safari tab holds a live NTU COOL session.
    case noSafariSession(tried: [String])
    /// Safari returned something that is not the JSON envelope our script emits
    /// (typically: "Allow JavaScript from Apple Events" is off, or Automation
    /// permission was denied).
    case safariScriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Canvas returned a non-HTTP response"
        case .noSafariSession(let tried):
            let list = tried.isEmpty ? "（沒有任何 cool.ntu.edu.tw 分頁）" : tried.joined(separator: ", ")
            return "Safari 沒有已登入的 COOL 分頁：請在 Safari 開啟 https://cool.ntu.edu.tw 並登入後重試。探測過：\(list)"
        case .safariScriptFailed(let detail):
            return "Safari 腳本執行失敗（需要「開發 > 允許 Apple Events 執行 JavaScript」與自動化權限）：\(detail.prefix(300))"
        }
    }
}

// MARK: - URL helpers

public enum CanvasURL {
    public static let defaultAPIBase = URL(string: "https://cool.ntu.edu.tw/api/v1")!

    /// Path relative to `/api/v1/`, with the tolerated prefixes stripped.
    static func relative(_ path: String) -> String {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        if p.hasPrefix("api/v1/") { p.removeFirst("api/v1/".count) }
        return p
    }

    static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("http://") || path.hasPrefix("https://")
    }

    private static func appending(query: [String: String], to components: URLComponents) -> URLComponents {
        guard !query.isEmpty else { return components }
        var c = components
        let extra = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        c.queryItems = (c.queryItems ?? []) + extra
        return c
    }

    /// Absolute URL for URLSession.
    public static func resolve(path: String, query: [String: String], base: URL = defaultAPIBase) -> URL {
        let components: URLComponents
        if isAbsolute(path), let c = URLComponents(string: path) {
            components = c
        } else {
            let url = base.appendingPathComponent(relative(path))
            components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        }
        return appending(query: query, to: components).url!
    }

    /// Path-and-query for a same-origin request issued from inside a
    /// `cool.ntu.edu.tw` page (Safari transport).
    public static func sameOriginPath(path: String, query: [String: String]) -> String {
        var components: URLComponents
        if isAbsolute(path), let c = URLComponents(string: path) {
            components = c
        } else {
            components = URLComponents()
            components.path = "/api/v1/" + relative(path)
        }
        components = appending(query: query, to: components)
        var out = components.percentEncodedPath
        if let q = components.percentEncodedQuery, !q.isEmpty { out += "?" + q }
        return out
    }
}

// MARK: - TokenTransport

/// Bearer-token transport over URLSession. HTTP errors are *returned* as
/// status codes so the ladder can react to 401; only non-HTTP failures throw.
public final class TokenTransport: CanvasTransport, @unchecked Sendable {
    private let token: String
    private let baseURL: URL
    private let session: URLSession

    /// - Parameters:
    ///   - token: Personal Access Token (caller sources it, e.g. from `CanvasAuth`).
    ///   - baseURL: API root; configurable so tests and other Canvas instances
    ///     can be targeted without a code change.
    ///   - session: injectable for tests (URLProtocol stubs).
    public init(token: String, baseURL: URL = CanvasURL.defaultAPIBase, session: URLSession? = nil) {
        self.token = token
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config)
        }
    }

    public func send(method: String, path: String, query: [String: String], jsonBody: Data?) async throws -> CanvasResponse {
        var request = URLRequest(url: CanvasURL.resolve(path: path, query: query, base: baseURL))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CanvasTransportError.invalidResponse
        }
        return CanvasResponse(
            status: http.statusCode,
            body: data,
            link: http.value(forHTTPHeaderField: "Link")
        )
    }
}
