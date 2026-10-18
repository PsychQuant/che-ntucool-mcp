# che-ntucool

Command-line client **and** MCP server for **NTU COOL**, National Taiwan University's Canvas LMS
deployment (`cool.ntu.edu.tw`). Confirmed via live verification
([PsychQuant/ntu-claude-plugins#17](https://github.com/PsychQuant/ntu-claude-plugins/issues/17))
that NTU COOL is a customized Canvas deployment with a fully open standard
Canvas REST API — every endpoint this server calls was curl-tested against a
real course before any code was written.

## Scope

Reads are unguarded. **Writes — grades and announcements — are gated behind a
human confirmation that this server asks for directly**, following the
[Foresay](https://github.com/kiki830621/foresay) confirmation protocol.

Foresay's rule is that an irreversible operation always takes the confirm
branch, and these are irreversible in its sense: students are notified, and a
notification cannot be un-sent. So there is no batch size below which the gate
is skipped — scale is not what forces the branch, irreversibility is.

Two independent layers, because they fail differently:

| Layer | Catches | Cannot catch |
|-------|---------|--------------|
| **MCP elicitation** — the server asks *you* through the client's own dialog | The model skipping or fabricating approval — it cannot, the answer never passes through it | Whether the payload it displayed is the one that gets written |
| **Payload-bound token** — a preview mints a single-use token bound to the exact payload it rendered | Approving `[85, 92, 78]` and writing `[85, 92, 87]` | Whether a human ever looked |

Fail-closed throughout: no elicitation support, decline, cancel, or transport
error all refuse the write. A client that cannot show a dialog cannot write at
all.

> **Why the server and not a skill.** Foresay's own case study names its biggest
> limitation: *"Foresay is a protocol, not a runtime. If the host LLM doesn't
> follow it, Foresay itself has no recourse."* That project could only reach for
> a skill-level commitment device, because it did not control the client. MCP
> elicitation gives the protocol a runtime — a step the model cannot rationalise
> its way past under load, because it is not the model's step to take.

## CLI

`che-ntucool` builds and inspects a course: `state`, `module add-url|publish`,
`quiz list|build|update-question|set`, `assignment groups|list|create|set`,
`announce list|post|edit`, `enroll`. Run `che-ntucool help <subcommand>`.
Course settings live in `ntucool.json` (see `plugin/skills/ntucool-canvas/SKILL.md`).

Everything it creates is unpublished. Anything students would see — publishing,
posting or editing an announcement, changing something already published —
prints a preview and needs `COOL_ALLOW_PUBLISH=1` plus `--yes` (or `y` at the
prompt).

## Credentials

Normally none. A working Canvas token in the macOS keychain (service
`ntu-cool-canvas`, account `default` or `$NTUCOOL_ACCOUNT`) is used when
present; otherwise, and whenever NTU COOL rejects it — manually issued tokens
expire after about an hour — requests ride **a logged-in Safari tab on
cool.ntu.edu.tw**. Safari needs 開發 → 允許 Apple Events 執行 JavaScript once,
and macOS asks for Automation permission on first use.

The session owner is logged on first use. Set `expected_user_id` in
`ntucool.json` (CLI) or `NTUCOOL_EXPECTED_USER_ID` (MCP server) to refuse any
other account.

Tokens are only ever sent to `https://cool.ntu.edu.tw`; absolute URLs pointing
anywhere else are refused before a request is built.

If you do want a token (it avoids Safari while it lives): NTU COOL → 帳戶 → 設定
→ 已核准的整合 → 新訪問令牌 (NTU's theme hides that block with `display: none`),
then `security add-generic-password -s ntu-cool-canvas -a default -w` — omit the
value after `-w` so it is prompted for and never lands in shell history or `ps`.

## Installation

### As a Claude Code plugin (recommended)

```
claude plugin marketplace add PsychQuant/che-ntucool-mcp
claude plugin install che-ntucool@che-ntucool
```

The plugin's wrapper auto-downloads the binary on first use and re-downloads
when a new version ships — no manual binary management. See
[`plugin/README.md`](plugin/README.md) for what's included (commands, skill,
staleness-detection hook).

### Manual (Claude Code CLI, no plugin)

```bash
mkdir -p ~/bin
# Download binary from releases
chmod +x ~/bin/CheNtucoolMCP
claude mcp add --scope user --transport stdio che-ntucool-mcp -- ~/bin/CheNtucoolMCP
```

## Tools

| Tool | Description |
|------|-------------|
| `list_courses` | Courses the token owner is enrolled in or teaching |
| `list_assignments` | Assignments in a course |
| `list_announcements` | Announcements posted in a course |
| `list_submissions` | Submission/grading status for every student in a course |
| `list_files` | Files uploaded to a course |
| `list_enrollments` | Enrollment roster for a course |
| `preview_grade_change` | Step 1 of 2 — render grade changes, mint a token. Writes nothing |
| `post_grades` | Step 2 of 2 — write grades after you confirm |
| `preview_announcement` | Step 1 of 2 — render the announcement + audience, mint a token. Writes nothing |
| `post_announcement` | Step 2 of 2 — publish after you confirm |

### Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `NTUCOOL_ACCOUNT` | `default` | Keychain account name holding the Canvas token |
| `NTUCOOL_API_BASE` | `https://cool.ntu.edu.tw/api/v1` | Canvas API root. Overriding it is what makes the write gate testable against a stub instead of a live course |

## Development

```bash
swift build
swift test
```

## Release Process (for maintainers)

```bash
./scripts/build-mcpb.sh          # dev bundle, ad-hoc signed, host-arch only
make install                     # install dev build to ~/bin
make release-signed VERSION=vX.Y.Z   # signed, notarized, universal binary + GitHub Release
```

#### Signing & Notarization (optional — not functionally required)

> **Note on scope**: che-ntucool only makes outbound HTTPS calls to the Canvas
> API — it does not touch any TCC-gated macOS API (EventKit, AppleEvents, Photos,
> etc.), so signing is not functionally required for this project to work. It's
> applied for Gatekeeper cleanliness and consistency with the rest of the
> `che-*-mcp` family, whose shared `che-mcps-notary` keychain profile this
> project reuses.

Release binaries are signed with a Developer ID Application certificate and notarized via Apple's `notarytool`, matching the rest of the `che-*-mcp` family's release process.

**Prerequisites** (one-time setup):

1. Apple Developer Program enrollment.
2. Developer ID Application certificate installed in login keychain.
   - Verify with: `security find-identity -p codesigning -v` (must show `Developer ID Application: <Your Name> (<TeamID>)`).
   - Your Team ID is your own — find it at <https://developer.apple.com/account> → Membership Details.
3. `notarytool` keychain profile named `che-mcps-notary` — **shared across the whole
   `che-*-mcp` family**. If you've released any other `che-*-mcp` project before,
   this already exists; verify with:
     ```bash
     xcrun notarytool history --keychain-profile che-mcps-notary | head -5
     ```
     `Successfully received submission history.` = still alive, skip to step 4.
   - Otherwise, create interactively (recommended — keeps password out of shell history):
     ```bash
     xcrun notarytool store-credentials che-mcps-notary --apple-id <your-apple-id> --team-id <your-team-id>
     # notarytool will prompt for the app-specific password
     ```
   - App-specific password: generate at <https://account.apple.com> → Sign-In and Security → App-Specific Passwords. Use a single-purpose password (named e.g. `che-mcps-notary`); revoke + regenerate if leaked. **Never** pass it via `--password` on the command line — it lands in `~/.zsh_history`.
4. Export your identity for the build script:
   ```bash
   export DEVELOPER_ID='Developer ID Application: <Your Name> (<TeamID>)'
   export NOTARY_PROFILE='che-mcps-notary'   # match what you set up in step 3
   ```
   Persist these in `~/.zshrc` or a project-local `.envrc` (gitignored). The script intentionally has **no defaults** for these, so a fresh fork doesn't fail with errors referring to the maintainer's identity.

**Per-release flow**:

```bash
make release-signed     # builds → signs + notarizes → packages
gh release create vX.Y.Z <path-to-binary> [<path-to-mcpb>] --notes "..."
```

`make release-signed` runs `scripts/release.sh` with `REQUIRE_CODESIGN=1` so missing prerequisites fail-fast. After universal binary creation, `scripts/sign-and-notarize.sh` performs codesign + notarization. Notarization typically takes 1–15 minutes (`notarytool submit --wait` blocks until Apple finishes).

**Verification** after build (run all three to confirm end-to-end):

```bash
# 1. Signature properties (cert + hardened runtime + team ID)
codesign -dv --verbose=2 path/to/CheNtucoolMCP
# Expected:
#   Authority=Developer ID Application: <Your Name> (<TeamID>)
#   TeamIdentifier=<TeamID>
#   flags=0x10000(runtime)

# 2. Signature integrity
codesign --verify --deep --strict --verbose=2 path/to/CheNtucoolMCP
# Expected: exit 0, no warnings

# 3. Notarization end-to-end (this is the real "Gatekeeper would accept" gate)
spctl -a -vvv -t install path/to/CheNtucoolMCP
# Expected: <binary>: accepted; source=Notarized Developer ID
#
# Note on flag choice (verified empirically on macOS 26.4.1):
#   -t execute → rejected "code is valid but does not seem to be an app"
#                (Apple's "execute" type expects a .app bundle structure,
#                 not raw Mach-O CLI binaries)
#   -t install → accepted; source=Notarized Developer ID  ← use this
#
# Apple's Code Signing Guide describes -t execute as the assessment type for
# "applications and tools", but on macOS 26 raw Mach-O binaries fall through
# the .app bundle check. -t install is the documented assessment type for
# software being installed (which describes how a CLI binary lands in ~/bin),
# and is the type that returns the actual notarization verdict in practice.
# Re-test if Apple changes this behavior in a future macOS update.
```

**Local dev iteration** without signing latency:

```bash
./scripts/build-mcpb.sh   # ad-hoc signed dev bundle; do NOT ship the result
make install               # installs ad-hoc to ~/bin (dev only)
```

`scripts/release.sh` auto-skips signing when `DEVELOPER_ID` is unset OR the cert isn't in your keychain — so contributors / CI / forks can build a working unsigned artifact for testing. `make release-signed` enforces signing via `REQUIRE_CODESIGN=1` and fails fast if anything is missing.

**Signing identity environment**:

| Env var | Default | Required for |
|---------|---------|--------------|
| `DEVELOPER_ID` | _(unset — auto-skip signing)_ | Signed release |
| `NOTARY_PROFILE` | _(unset — fail-fast in `sign-and-notarize.sh`)_ | Signed release |
| `ENTITLEMENTS` | `Sources/CheNtucoolMCP/Entitlements.plist` | Custom entitlements file |
| `SKIP_CODESIGN` | _(unset)_ | Force-skip signing even with cert present (set to `1` or `true`) |
| `REQUIRE_CODESIGN` | _(unset)_ | Fail-fast if signing prerequisites missing (set to `1` by `make release-signed`) |

**Known limitation — no stapling**: `stapler staple` does not support raw Mach-O binaries (only `.app` / `.pkg` / `.dmg` bundles). After notarization, Gatekeeper will online-check the binary on first launch instead of reading a stapled ticket. End users behind air-gapped networks may see "cannot verify developer" warnings; one launch with network resolves it (Apple caches the verdict). Mitigation: `xcrun stapler staple` on a future `.pkg` wrapper if needed.

**Upgrade trap (if shipping over an existing install)**: If users have an older version of `CheNtucoolMCP` already installed (e.g. ad-hoc signed prior version), they should `rm -f` the old binary before replacing it. macOS caches code-signature hashes per-inode; copying a new binary over an inode held open by a still-running old process leaves a stale cache that causes the kernel to kill the new binary on exec with "load code signature error 2". The `Makefile install:` target and the user-facing install instructions both use `rm -f` defensively.

**Troubleshooting**:

- Notarization rejected? `xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE` shows Apple's reason. The signing script prints the submission ID on every run.
- `codesign` complains about missing identity? `security find-identity -p codesigning -v` to confirm cert is present + valid; `xcrun notarytool history --keychain-profile $NOTARY_PROFILE` to confirm the profile works.
- Cert expired? Re-issue at <https://developer.apple.com/account/resources/certificates>, install, re-export `DEVELOPER_ID`.
- Security warning: don't unlock signing keychain on shared / untrusted machines. The cert + private key signing artifact is supply-chain critical.

## License

MIT
