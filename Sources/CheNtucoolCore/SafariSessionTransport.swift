import Foundation

// MARK: - Script execution seam

/// Executes an AppleScript and returns its textual result. Abstracted so the
/// Safari transport can be tested without Safari: tests inject a fake that
/// answers the tab-listing script and the `do JavaScript` script from canned
/// data.
public protocol ScriptRunner: Sendable {
    func run(appleScript: String) throws -> String
}

/// Real runner: `/usr/bin/osascript` reading the script from stdin.
///
/// Requirements on the machine (one-time, human-performed — the tool can only
/// detect and explain): Safari → 開發 → 允許 Apple Events 執行 JavaScript,
/// and macOS Automation permission for the calling process. Signed release
/// builds additionally need the `com.apple.security.automation.apple-events`
/// entitlement (handled in the release slice of #1).
public struct OSAScriptRunner: ScriptRunner {
    public init() {}

    public func run(appleScript: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(appleScript.utf8))
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CanvasTransportError.safariScriptFailed(detail.isEmpty ? "osascript exit \(process.terminationStatus)" : detail)
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - Safari tab model

public struct SafariTab: Sendable, Equatable {
    public let window: Int
    public let tab: Int
    public let url: String
    public let isCurrent: Bool

    public var label: String { "window \(window) tab \(tab) \(url)" }
}

// MARK: - Transport

/// Rides an already-logged-in Safari session: every request is a synchronous
/// same-origin XMLHttpRequest executed inside a `cool.ntu.edu.tw` tab via
/// AppleScript `do JavaScript`. Canvas accepts the session cookie for reads;
/// writes additionally need the `_csrf_token` cookie echoed as `X-CSRF-Token`.
///
/// Tab selection: on first use, list every Safari tab, keep those on the COOL
/// host, order them (current tab first, then course pages, then the rest) and
/// probe each with `GET /users/self`. The first tab answering 200 is locked
/// and reused for the life of the process. Probing one by one matters:
/// Safari unloads background tabs and an unloaded tab answers the XHR with a
/// script error rather than a session.
public final class SafariSessionTransport: CanvasTransport, @unchecked Sendable {
    private let runner: ScriptRunner
    private let host: String
    private let expectedUserID: Int?
    private let lock = NSLock()
    private var locked: SafariTab?
    private var pinned: Int?

    /// - Parameter expectedUserID: Canvas user id every locked tab must belong
    ///   to. Without it, the first tab's owner becomes the pin, so a later
    ///   re-probe (the locked tab closed or navigated) can never move this
    ///   transport to a different account — a switch the layer above would
    ///   not see.
    public init(runner: ScriptRunner = OSAScriptRunner(), host: String = "cool.ntu.edu.tw", expectedUserID: Int? = nil) {
        self.runner = runner
        self.host = host
        self.expectedUserID = expectedUserID
    }

    /// Canvas user id every request on this transport runs as, once known.
    public var pinnedUserID: Int? {
        lock.lock(); defer { lock.unlock() }
        return expectedUserID ?? pinned
    }

    private var origin: String { "https://\(host)" }

    /// The tab currently locked, if probing has happened. Exposed for tests
    /// and for the CLI's diagnostics output.
    public var lockedTab: SafariTab? {
        lock.lock(); defer { lock.unlock() }
        return locked
    }

    public func send(method: String, path: String, query: [String: String], jsonBody: Data?) async throws -> CanvasResponse {
        let sameOrigin = try CanvasURL.checkedSameOriginPath(path: path, query: query, host: host)
        // Built at execution time, after the tab is chosen and the owner pinned:
        // a script built before probe() would carry no owner check on a
        // transport's very first request, even when that request is a write.
        func script() -> String {
            Self.javascript(method: method, sameOriginPath: sameOrigin, jsonBody: jsonBody, origin: origin,
                            expectedUserID: pinnedUserID)
        }

        if let tab = lockedTab {
            do {
                return try executeUnlockingOnMismatch(script(), in: tab)
            } catch CanvasTransportError.safariScriptFailed {
                // The locked tab went away (closed, navigated, unloaded).
                // Forget it and fall through to a fresh probe.
                setLocked(nil)
            }
        }
        let tab = try probe()
        setLocked(tab)
        return try executeUnlockingOnMismatch(script(), in: tab)
    }

    /// A tab shown to hold someone else's session is dropped, so reads stop
    /// using it too; the next request re-probes and the pin refuses that tab.
    private func executeUnlockingOnMismatch(_ js: String, in tab: SafariTab) throws -> CanvasResponse {
        do {
            return try execute(js, in: tab)
        } catch let error as CanvasTransportError {
            if case .identityMismatch = error { setLocked(nil) }
            throw error
        }
    }

    // MARK: Probing

    private func probe() throws -> SafariTab {
        let listing = try runner.run(appleScript: Self.tabListScript)
        let candidates = Self.rankCandidates(Self.parseTabList(listing), host: host)
        var tried: [String] = []
        let probeJS = Self.javascript(method: "GET", sameOriginPath: "/api/v1/users/self", jsonBody: nil, origin: origin)
        let pin = pinnedUserID
        for tab in candidates {
            guard let response = try? execute(probeJS, in: tab), response.status == 200 else {
                tried.append(tab.label)
                continue
            }
            // A 200 without an integer id cannot be pinned, so it cannot be trusted.
            guard let id = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["id"] as? Int else {
                tried.append("\(tab.label)（/users/self 沒有可辨識的 id）")
                continue
            }
            if let pin, id != pin {
                tried.append("\(tab.label)（登入者 id \(id)，不是 \(pin)）")
                continue
            }
            if pin == nil { setPinned(id) }
            return tab
        }
        throw CanvasTransportError.noSafariSession(tried: tried)
    }

    private func setPinned(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        pinned = id
    }

    private func execute(_ js: String, in tab: SafariTab) throws -> CanvasResponse {
        let raw = try runner.run(appleScript: Self.doJavaScriptScript(js: js, tab: tab))
        return try Self.parseEnvelope(raw, expectedUserID: pinnedUserID)
    }

    private func setLocked(_ tab: SafariTab?) {
        lock.lock(); defer { lock.unlock() }
        locked = tab
    }

    // MARK: Pure helpers (unit-tested)

    /// Lines of `window\ttab\tisCurrent\turl` as emitted by `tabListScript`.
    static func parseTabList(_ raw: String) -> [SafariTab] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 4, let w = Int(f[0]), let t = Int(f[1]) else { return nil }
            return SafariTab(window: w, tab: t, url: String(f[3]), isCurrent: f[2] == "1")
        }
    }

    /// Keep tabs on `host`; current tab first, then `/courses/` pages, then the
    /// rest; stable within each tier so Safari's own order is preserved.
    static func rankCandidates(_ tabs: [SafariTab], host: String) -> [SafariTab] {
        func tier(_ t: SafariTab) -> Int {
            if t.isCurrent { return 0 }
            if t.url.contains("/courses/") { return 1 }
            return 2
        }
        return tabs
            .filter { URL(string: $0.url)?.host == host }
            .enumerated()
            .sorted { (tier($0.element), $0.offset) < (tier($1.element), $1.offset) }
            .map(\.element)
    }

    /// Parse the `{"s":status,"t":responseText,"l":link}` envelope the JS
    /// returns, stripping Canvas's anti-JSON-hijacking `while(1);` prefix.
    static func parseEnvelope(_ raw: String, expectedUserID: Int? = nil) throws -> CanvasResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["s"] as? Int,
              var text = obj["t"] as? String
        else {
            throw CanvasTransportError.safariScriptFailed(trimmed)
        }
        // Negative status: our own script refused (the page was not on the
        // expected origin). Treated like any script failure so the caller
        // re-probes; nothing was sent.
        // -2: the write's own owner check found another account in this tab.
        // Not a reason to re-probe — the request was not sent, and the human
        // needs to know which account Safari is logged in as.
        if status == -2 {
            let who = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
            throw CanvasTransportError.identityMismatch(expected: expectedUserID ?? -1,
                                                        actual: who["id"] as? Int ?? -1, name: who["name"] as? String)
        }
        guard status >= 0 else { throw CanvasTransportError.safariScriptFailed(text) }
        if text.hasPrefix("while(1);") { text.removeFirst("while(1);".count) }
        let link = (obj["l"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CanvasResponse(status: status, body: Data(text.utf8), link: link)
    }

    /// Single-line JS: synchronous XHR against a same-origin path.
    /// The first statement checks the page's own origin: a tab is addressed
    /// by window/tab index, and between listing and executing it may have
    /// navigated elsewhere. On any other origin the script returns without
    /// opening a request, so neither the path nor the body leaves.
    ///
    /// With `expectedUserID`, a write first asks `/users/self` in the same
    /// script and refuses (status -2) if the tab is now someone else's — a
    /// logout/login inside the locked tab would otherwise go unnoticed.
    /// Reads skip that round trip.
    static func javascript(method: String, sameOriginPath: String, jsonBody: Data?,
                           origin: String = "https://cool.ntu.edu.tw", expectedUserID: Int? = nil) -> String {
        var parts: [String] = []
        parts.append("(function(){")
        parts.append("if(location.origin!==\"\(jsString(origin))\"){return JSON.stringify({s:-1,t:\"wrong origin \"+location.origin,l:\"\"});}")
        if let expectedUserID, method != "GET" {
            parts.append("var w=new XMLHttpRequest();w.open(\"GET\",\"/api/v1/users/self\",false);")
            parts.append("w.setRequestHeader(\"Accept\",\"application/json\");w.send(null);")
            parts.append("var wt=w.responseText.replace(/^while\\(1\\);/,\"\");var wo=null;try{wo=JSON.parse(wt);}catch(e){}")
            parts.append("if(w.status!==200||!wo||wo.id!==\(expectedUserID)){return JSON.stringify({s:-2,t:wt,l:\"\"});}")
        }
        parts.append("var x=new XMLHttpRequest();")
        parts.append("x.open(\"\(method)\",\"\(jsString(sameOriginPath))\",false);")
        parts.append("x.setRequestHeader(\"Accept\",\"application/json\");")
        if method != "GET" {
            parts.append("var m=document.cookie.match(/(?:^|;\\s*)_csrf_token=([^;]*)/);")
            parts.append("if(m){x.setRequestHeader(\"X-CSRF-Token\",decodeURIComponent(m[1]));}")
            parts.append("x.setRequestHeader(\"Content-Type\",\"application/json\");")
        }
        if let jsonBody {
            parts.append("x.send(\"\(jsString(String(decoding: jsonBody, as: UTF8.self)))\");")
        } else {
            parts.append("x.send(null);")
        }
        parts.append("return JSON.stringify({s:x.status,t:x.responseText,l:x.getResponseHeader(\"Link\")||\"\"});})()")
        return parts.joined()
    }

    /// The separator is `character id 9`, set before the `tell` block:
    /// inside it, `tab` means Safari's tab class and would print as "tab".
    static let tabListScript = """
    set sep to (character id 9)
    tell application "Safari"
    	set out to ""
    	repeat with w from 1 to (count of windows)
    		set curIdx to 0
    		try
    			set curIdx to index of current tab of window w
    		end try
    		repeat with t from 1 to (count of tabs of window w)
    			set isCur to "0"
    			if t = curIdx then set isCur to "1"
    			set out to out & w & sep & t & sep & isCur & sep & (URL of tab t of window w) & linefeed
    		end repeat
    	end repeat
    	return out
    end tell
    """

    static func doJavaScriptScript(js: String, tab: SafariTab) -> String {
        """
        tell application "Safari"
        	do JavaScript "\(appleScriptString(js))" in tab \(tab.tab) of window \(tab.window)
        end tell
        """
    }

    /// Escape for a double-quoted JS string literal.
    static func jsString(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            // Line terminators in JavaScript source, even inside a string literal
            // in older engines; escaped so the literal can never be split.
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default: out.append(c)
            }
        }
        return out
    }

    /// Escape for a double-quoted AppleScript string literal.
    static func appleScriptString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
