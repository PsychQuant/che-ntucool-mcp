---
name: ntucool-canvas
description: |
  Query and update NTU COOL (Canvas LMS) — courses, assignments, submissions,
  announcements, files, roster; plus posting grades and announcements. Use when
  the user asks about their NTU COOL courses, assignment status, who has/hasn't
  submitted, course announcements or files, or asks to enter grades or publish
  an announcement.
allowed-tools:
  - mcp__ntucool__list_courses
  - mcp__ntucool__list_assignments
  - mcp__ntucool__list_announcements
  - mcp__ntucool__list_submissions
  - mcp__ntucool__list_files
  - mcp__ntucool__list_enrollments
  - mcp__ntucool__preview_grade_change
  - mcp__ntucool__post_grades
  - mcp__ntucool__preview_announcement
  - mcp__ntucool__post_announcement
---

# NTU COOL (Canvas LMS) Query

MCP for NTU COOL, National Taiwan University's Canvas LMS deployment. Reads are
unguarded; grade and announcement writes are two-step and human-confirmed.
Verified against a live course before ship (PsychQuant/ntu-claude-plugins#17) —
NTU COOL is a customized Canvas deployment with a fully open standard Canvas
REST API.

## Setup (one-time, per machine)

Requires a Canvas Personal Access Token in the macOS keychain:

```bash
security add-generic-password -s ntu-cool-canvas -a default -w '<token>'
```

Generate the token at NTU COOL → 帳戶 → 設定 → 已核准的整合 → 新訪問令牌 — NTU's
theme hides that section by default, so the user may report not seeing it. If the
token is missing, tool calls fail with a Canvas 401 — the error message will say
so; direct the user to run the command above, not attempt to work around it.

## Read tools

| Tool | Purpose |
|------|---------|
| `list_courses` | Start here — get course ids for the tools below |
| `list_assignments` | Assignments in a course |
| `list_announcements` | Announcements posted in a course |
| `list_submissions` | Submission/grading status for every student |
| `list_files` | Files uploaded to a course |
| `list_enrollments` | Enrollment roster |

Workflow: `list_courses` to resolve the `course_id` the user means, then the
relevant `list_*` tool. If the user names a course loosely and two could match,
**ask** — do not pick one.

## Write tools — always two steps

| Step | Grades | Announcements |
|------|--------|---------------|
| 1. Preview | `preview_grade_change` | `preview_announcement` |
| 2. Write | `post_grades` | `post_announcement` |

Step 1 writes nothing. It renders exactly what would change and returns a
`confirmation_token`. **Show that rendering to the user in your reply** — it is
written for them, not for you, and it carries the current grade each student
holds so a mistake is visible before it happens.

Step 2 takes the same arguments plus the token, and the server then asks the
user to confirm in their own dialog. The write happens only if they accept.

Three things you cannot do, by construction rather than by policy:

- **Skip the preview.** The write refuses without a valid token.
- **Answer the confirmation.** The dialog does not pass through you.
- **Change the payload between preview and write.** The token is bound to the
  exact payload. Any difference is refused and the token is burned — you must
  preview again so the human sees the corrected version. If you notice a
  mistake after previewing, just re-preview; that is the intended path.

Tokens are single-use and expire in 10 minutes.

### When a write is refused

A refusal means **a human has not approved this write**. Report that plainly
and stop.

Do not suggest the user make the change by hand in NTU COOL as a way around a
refusal, and do not retry hoping for a different answer. Both convert "a human
declined" into "it happened anyway", which is the exact outcome the gate exists
to prevent. (Telling them how to do it themselves is fine when they *asked* how
— the difference is whether you are routing around a refusal or answering a
question.)

A "this client cannot show a confirmation dialog" refusal is not transient.
Retrying will refuse identically.

### Grades

Pass one entry per student: `{user_id, grade}`. `grade` is whatever the
assignment's grading type accepts — points (`"85"`), percentage (`"85%"`),
letter (`"A"`), or `"pass"`/`"fail"`.

The preview states whether the assignment posts grades automatically or
manually. On a **manual** posting policy the grades stay hidden from students
until posted in NTU COOL, so the write is recoverable; on **automatic** (the
default) students are notified immediately and it is not. Do not paraphrase
this away — it is the difference between a reversible and an irreversible act.

`post_grades` writes per student and reports partial failure honestly. If some
grades wrote and others failed, the successful ones **have already notified
those students** and are not rolled back. Re-preview only the failed entries.

### Announcements

`message` accepts HTML. The preview reports how many students would be
notified. Publishing notifies everyone immediately; deleting the announcement
afterwards does not un-send the notification.
