---
name: ntucool-canvas
description: |
  Query NTU COOL (Canvas LMS) — courses, assignments, submissions, announcements,
  files, roster. Use when the user asks about their NTU COOL courses, assignment
  status, who has/hasn't submitted, course announcements, or course files.
allowed-tools:
  - mcp__ntucool__list_courses
  - mcp__ntucool__list_assignments
  - mcp__ntucool__list_announcements
  - mcp__ntucool__list_submissions
  - mcp__ntucool__list_files
  - mcp__ntucool__list_enrollments
---

# NTU COOL (Canvas LMS) Query

Read-only MCP for NTU COOL, National Taiwan University's Canvas LMS deployment.
Verified against a live course before ship (PsychQuant/ntu-claude-plugins#17) —
NTU COOL is a customized Canvas deployment with a fully open standard Canvas
REST API.

## Setup (one-time, per machine)

Requires a Canvas Personal Access Token in the macOS keychain:

```bash
security add-generic-password -s ntu-cool-canvas -a default -w '<token>'
```

Generate the token at NTU COOL → 帳戶 → 設定 → 新訪問令牌. If missing, tool
calls fail with a Canvas 401 — the error message will say so; direct the user
to run the command above, not attempt to work around it.

## Tools

| Tool | Purpose |
|------|---------|
| `list_courses` | Start here — get course ids for the tools below |
| `list_assignments` | Assignments in a course |
| `list_announcements` | Announcements posted in a course |
| `list_submissions` | Submission/grading status for every student |
| `list_files` | Files uploaded to a course |
| `list_enrollments` | Enrollment roster |

## Common workflow

1. `list_courses` to find the `course_id` for the course the user means
   (disambiguate by name/course_code if the user names a course loosely — don't
   guess between two similarly-named courses, ask)
2. Call the relevant `list_*` tool with that `course_id`

## Scope (v0.1.0)

**Read-only.** No grade posting, no announcement creation, no file upload. If
the user asks for a write operation, tell them it isn't available yet — do
not attempt to work around this via another tool or manual instructions to
edit NTU COOL directly on their behalf, since that reintroduces exactly the
teaching-incident risk this scope boundary exists to prevent.
