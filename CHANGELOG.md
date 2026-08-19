# Changelog

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
