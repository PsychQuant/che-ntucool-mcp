# Changelog

## [0.3.0] - 2026-09-24

The plugin is now **che-ntucool**: a command-line client alongside the MCP
server, over one shared Canvas library (PsychQuant/che-ntucool-mcp#1).

### Upgrading

The plugin and its marketplace were renamed, so the old install does not update
in place:

```
claude plugin uninstall che-ntucool-mcp@che-ntucool-mcp
claude plugin marketplace remove che-ntucool-mcp
claude plugin marketplace add PsychQuant/che-ntucool-mcp
claude plugin install che-ntucool@che-ntucool
```

The MCP binary keeps its name (`CheNtucoolMCP`) so existing macOS permission
grants stay valid. The GitHub repository keeps its name until it is renamed
separately; the download URL works either way.

### Added
- `che-ntucool` CLI (on the Bash tool's PATH via the plugin's `bin/`):
  `state`, `module add-url|publish`, `quiz list|build|update-question|set`,
  `assignment groups|list|create|set`, `announce list|post|edit`, `enroll`,
  with `--json`. Course settings in `ntucool.json` (`course_id`, week →
  module ids, `timezone`, `expected_user_id`, `quiz_option_sets`).
- Quizzes are built from the course repo's `W<NN>/測驗.md` format;
  `--dry-run` parses and checks every answer against the option set offline.
  Announcements are posted from `announcements/*.md` (title line and
  `## 正文` only).
- Safari session fallback: when the keychain has no token or NTU COOL
  rejects it (manual tokens expire after about an hour), requests ride a
  logged-in Safari tab on cool.ntu.edu.tw. Used by both the CLI and the MCP
  server. The session owner is logged; `expected_user_id` /
  `NTUCOOL_EXPECTED_USER_ID` refuses any other account.
- `com.apple.security.automation.apple-events` entitlement on both binaries.

### Safety
- Everything the CLI creates is unpublished. A student-visible write (body
  publishes, announcement post/edit, or the target is already published)
  prints a preview and needs `COOL_ALLOW_PUBLISH=1` plus `--yes` or an
  interactive `y` — the same contract as the course repo's `cool_build.py`,
  so the repo's publish hook still fires.
- Bearer tokens are only sent to the configured API origin over https:
  absolute URLs from callers or from Canvas `Link` headers pointing
  anywhere else are refused before a request is built.
- Only a credential-rejection 401 switches to Safari; a permission 401
  ("user not authorized") is returned as-is instead of being retried under
  whoever a Safari tab is logged in as.

### Fixed
- Safari tab listing emitted the word "tab" instead of a tab character
  (inside `tell application "Safari"`, `tab` is Safari's tab class), so the
  Safari path could never find a COOL tab. Found in the live acceptance run.

### Verified
- `che-ntucool state` against course 64652 matches `cool_build.py state`
  item for item (17 modules, 47 items, 16 discussions, 13 quizzes, 15
  assignments, 3 files).

## [0.2.2] - 2026-08-19

### Fixed
- The keychain account name was documented as `<login-id>`, with a note saying it
  could be any label. It cannot: the wrapper and the server both look up
  `${NTUCOOL_ACCOUNT:-default}`, so a token stored under a login-id is simply not
  found. Anyone following the setup instructions literally ended up with a token
  the server could not read. Now documented as `default`, with the override
  described as a lookup key rather than a label.

- Every example passed the token as `-w <token>`, which places it in the process
  argument list for the lifetime of the command — readable by any local process
  via `ps`, whether or not it was ever echoed. Omitting the value makes `security`
  prompt for it instead. Corrected in the README, the `ntucool-canvas` skill, the
  wrapper's stderr hint, the server's `instructions` string, and the token-missing
  error message.

  The last two matter beyond documentation: they are compiled into the binary, so
  until this release the shipped server told users — and told the model, through
  `instructions` — to run the leaking form.

## [0.2.1] - 2026-08-19

### Fixed
- Setup instructions pointed at a token path that dead-ends as written. The Canvas
  control lives under 帳戶 → 設定 → **已核准的整合** → 新訪問令牌, and NTU COOL's
  custom theme hides that entire block:

  ```css
  .approved_integration_headers, .approved_integration_content { display: none; }
  ```

  So a reader following the documented path looks for a button inside a section
  they cannot see, and concludes the feature is unavailable.

  Corrected in all four places that carried the old path: the README setup step,
  the server's own `instructions` string (delivered to the client — the model was
  reading the wrong path too, and would have relayed it), the `ntucool-canvas`
  skill, and the wrapper's token-missing stderr hint.

  The hide is cosmetic, not Canvas's `limit_personal_access_tokens` account
  setting — `.add_access_token_link` is still rendered into the page, so tokens
  remain obtainable. Verified against a live NTU COOL session 2026-08-19.

## [0.2.0] - 2026-08-19

### Added — write operations, human-confirmed (Foresay protocol)
- `preview_grade_change` / `post_grades` — set grades on an assignment
- `preview_announcement` / `post_announcement` — publish a course announcement

Both follow the [Foresay](https://github.com/kiki830621/foresay) confirmation
protocol. Foresay's `operation` rule is that an irreversible operation always
takes the confirm branch, and these are irreversible in its sense — students are
notified and a notification cannot be un-sent — so there is no scope threshold
below which the gate is skipped.

The gate has two independent layers, because they catch different failures:

- **Elicitation** (`elicitation/create`) puts the confirmation in front of the
  user through the client's own dialog. The model cannot skip it or answer it,
  because the answer does not pass through the model. This is what Foresay's own
  case study called its biggest gap — *"Foresay is a protocol, not a runtime"* —
  and it closes it, because this project controls the server rather than only
  the skill layer.
- **Payload-bound token.** A preview mints a single-use, 10-minute token bound
  to the exact payload it rendered; the write refuses any payload whose hash
  differs. This catches what the dialog structurally cannot: the human approved
  `[85, 92, 78]` and `[85, 92, 87]` reached the API. A mismatch burns the token,
  so the correction must be re-previewed rather than riding in on the old
  approval.

Fail-closed in every direction — no elicitation support, decline, cancel, or
transport error all refuse the write.

Reversibility is read from the assignment rather than assumed: an assignment on
a **manual** posting policy genuinely is recoverable (grades stay hidden until
posted), and the confirmation says so instead of crying wolf. An unreadable
posting policy is treated as automatic — unknown fails toward the more cautious
warning.

### Fixed
- `Server` now runs with `Configuration.strict`. The SDK's
  `validateClientCapability` is a **no-op unless strict mode is on**, and the
  default is off — so the elicitation capability check that this feature's
  safety was assumed to rest on was not actually running. Caught by reading the
  SDK rather than trusting the assumption.
- The elicitation capability is additionally checked *directly* by this server
  (captured at the initialize handshake) rather than relying only on the SDK's
  strict-mode path, so the safety property does not hinge on a global config
  flag that could later be flipped for an unrelated reason.
- `NTUCOOL_API_BASE` now overrides the Canvas base URL. `CanvasAPIClient`
  documented this as configurable "for testing", but the server hardcoded it,
  making the claim untrue and the write gate unverifiable offline.

### Verification
The gate was exercised end-to-end against a stub Canvas server: a valid token
was minted by a preview, the write was attempted from a client that declared no
elicitation support, the write was **refused rather than hung**, and the stub
recorded **zero** write requests. 16 unit tests cover replay, expiry, payload
drift, cross-payload-type redemption, and delimiter-collision resistance.

## [0.1.0] - 2026-08-19

### Added
- Initial release
- `list_courses`, `list_assignments`, `list_announcements`, `list_submissions`, `list_files`, `list_enrollments` tools
- Keychain-backed Canvas Personal Access Token storage (service `ntu-cool-canvas`)
- Read-only scope — write operations (grades, announcements) deliberately deferred

### Distribution
- Developer ID signing + notarization pipeline (`scripts/sign-and-notarize.sh`, `Sources/CheNtucoolMCP/Entitlements.plist`), reusing the shared `che-mcps-notary` keychain profile
- `scripts/release.sh` + `make release-signed` — universal (arm64+x86_64) binary build, sign, notarize, package `.mcpb`, tag, GitHub Release
- `scripts/build-mcpb.sh` / `scripts/package-mcpb.sh` — unsigned dev-build convenience path
- Not functionally required (this server makes only outbound HTTPS calls, no TCC-gated APIs) — applied for Gatekeeper cleanliness and family consistency
- Self-hosted Claude Code plugin at `plugin/` (`.claude-plugin/marketplace.json` at repo root), same pattern as `che-apple-mail-mcp`: version-aware auto-download wrapper, SessionStart staleness-detection hook, `ntucool-canvas` skill, `/ntucool-courses` command
