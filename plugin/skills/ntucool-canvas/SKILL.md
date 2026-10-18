---
name: ntucool-canvas
description: |
  Read and build NTU COOL (Canvas LMS) courses — modules, quizzes, assignments,
  announcements, files, roster, grades. Use when the user asks about their NTU
  COOL course state, wants to add a link or quiz to a week's module, build a
  quiz from a 測驗.md file, change quiz/assignment times, post or edit an
  announcement from an announcements/*.md file, check enrollment, see who has
  submitted, or enter grades.
allowed-tools:
  - Bash(che-ntucool:*)
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

# NTU COOL (Canvas LMS)

Two front ends over one Canvas client:

- **`che-ntucool` CLI** (on PATH while this plugin is enabled) — course
  building: state, modules, quizzes from markdown, assignments, announcements,
  enrollment. Use this for anything the course repo's `scripts/cool_build.py`
  used to do.
- **MCP tools** (below) — quick reads and the two-step grade / announcement
  writes with an in-client confirmation dialog.

## Credentials — normally nothing to set up

A working keychain token (service `ntu-cool-canvas`) is used if present.
Otherwise, and whenever NTU COOL rejects it (manually issued COOL tokens die
after about an hour), requests go through **a logged-in Safari tab on
cool.ntu.edu.tw**, riding its session. On first use it logs whose session
that is (`Safari 登入者 名字（id N）`). Set `expected_user_id` in `ntucool.json`
(or `NTUCOOL_EXPECTED_USER_ID` for the MCP server) to refuse any other
account — this Mac has several Safari profiles.

If a call fails with `Safari 沒有已登入的 COOL 分頁`, ask the user to open and
log in to NTU COOL in Safari. Do not ask for a token, and never let a token be
pasted into the conversation. Safari needs 開發 → 允許 Apple Events 執行
JavaScript, once.

## CLI

Course settings come from `--config`, `$CHE_NTUCOOL_CONFIG`, or `./ntucool.json`:

```json
{
  "course_id": 64652,
  "modules": { "W01": 946894, "W02": 946895 },
  "timezone": "+08:00",
  "expected_user_id": 344929,
  "quiz_option_sets": { "nine": ["①【未引用文獻】…", "…"] }
}
```

| Task | Command |
|------|---------|
| Everything, with publish state | `che-ntucool state` (`--json` for machine output) |
| Link in a week's module | `che-ntucool module add-url --week W03 --title … --url …` |
| Publish a module / item | `che-ntucool module publish W03 [--item ID] [--off]` |
| Check a quiz file offline | `che-ntucool quiz build --file W03/測驗.md --week W03 --title … --options nine --dry-run` |
| Build the quiz (unpublished) | same without `--dry-run`, plus `--unlock/--due/--time-limit/--group` |
| Fix one question | `che-ntucool quiz update-question QUIZ N --file … --options nine` |
| Times, type, publish | `che-ntucool quiz set QUIZ --due 2026-09-30T11:55 --type practice_quiz --published false` |
| Assignments | `che-ntucool assignment groups / list / create / set` |
| Announcements | `che-ntucool announce list / post FILE.md / edit ID FILE.md` |
| Roster counts | `che-ntucool enroll [--append-csv 115-1/cool_enrollment.csv]` |

Times without an offset are read in the config's `timezone` (Taipei) and always
sent with an explicit offset.

### Anything students can see is gated

Everything the CLI creates is **unpublished**. A write counts as
student-visible when its body publishes something, when it is an
announcement (post or edit), or when its target is already published (changing
a published quiz's times or questions). Such a write prints a preview on
stderr and needs **both**:

1. `COOL_ALLOW_PUBLISH=1` in the environment — the variable the course repo's
   hook watches, so the user sees a permission prompt; and
2. `--yes`, or a `y` at the interactive prompt (there is no prompt without a
   terminal, so from the Bash tool it is `--yes`).

Before running such a command, follow the course repo's rule: paste the final
content (the announcement file's 正文, the quiz, the settings) to the user and
wait for them to say 發 — for **that** version. Only then add
`COOL_ALLOW_PUBLISH=1 … --yes`. A refusal from the gate is an answer, not an
obstacle: do not retry it another way.

`announce post` reads only the file's `# ` title and `## 正文` section. After
posting, fill in the file's `status` / `posted_at` / `cool_announcement_id`.

## MCP read tools

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

## MCP write tools — always two steps

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
