# Changelog

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
