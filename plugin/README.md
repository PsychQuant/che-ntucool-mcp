# che-ntucool (plugin)

Claude Code plugin for NTU COOL (Canvas LMS): the `che-ntucool` CLI (on the
Bash tool's PATH via `bin/che-ntucool`) for course building, and the MCP server
for reads plus human-confirmed grade and announcement writes.

## Install

```
claude plugin marketplace add PsychQuant/che-ntucool-mcp
claude plugin install che-ntucool@che-ntucool
```

Both wrappers (`bin/che-ntucool`, `bin/che-ntucool-mcp-wrapper.sh`, sharing
`lib/ensure-binary.sh`) auto-download their binary from
this repo's GitHub Releases on first use, and re-downloads when the plugin's
`binary_version` moves ahead of what's installed.

## Setup

Store a Canvas Personal Access Token in the macOS keychain — see the top-level
[README](../README.md#setup) or `skills/ntucool-canvas/SKILL.md`.

## What's in here

- `bin/` — the auto-download wrapper
- `hooks/` — SessionStart staleness detection (kills a stale running binary so
  Claude Code respawns the updated one)
- `commands/` — quick slash commands
- `skills/` — tool usage guide, loaded automatically when relevant

## Binary source

The actual Swift MCP server lives at the repo root — see the top-level
[README](../README.md) for build/development instructions.
