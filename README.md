# che-ntucool-mcp

Read-only MCP server for **NTU COOL**, National Taiwan University's Canvas LMS
deployment (`cool.ntu.edu.tw`). Confirmed via live verification
([PsychQuant/ntu-claude-plugins#17](https://github.com/PsychQuant/ntu-claude-plugins/issues/17))
that NTU COOL is a customized Canvas deployment with a fully open standard
Canvas REST API — every endpoint this server calls was curl-tested against a
real course before any code was written.

## Scope (v0.1.0)

Read-only. No grade posting, no announcement creation — those are
teaching-incident-risk operations deliberately left out of this first version.
MVP covers the four use cases confirmed in #17: assignments, submissions/grades,
announcements, and files.

## Setup

1. Generate a Canvas Personal Access Token: NTU COOL → 帳戶 → 設定 → 新訪問令牌
2. Store it in the macOS keychain (never as an env var, never in a config file):

   ```bash
   security add-generic-password -s ntu-cool-canvas -a <login-id> -w <token>
   ```

   `<login-id>` can be any label you choose — it's the keychain account name, not
   validated against your NTU login. Override with `NTUCOOL_ACCOUNT` env var if
   you use something other than `default`.

## Installation

### Claude Code CLI

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

## Development

```bash
swift build
swift test
```

## License

MIT
