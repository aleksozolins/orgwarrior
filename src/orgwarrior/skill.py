"""An Agent Skill (SKILL.md) that teaches an AI agent with a shell to use
orgwarrior: `orgwarrior help --skill` prints it, so it matches the version
installed.  Generic: nothing of one person's setup, which the agent reads
from the CLI and the config instead.  A test parses every command in it."""

TEXT = """\
---
name: orgwarrior
description: The user's tasks and agenda in Org mode, through the orgwarrior command. Use for any question about their tasks, agenda, schedule, deadlines or what's due ("what's due tomorrow?", "what am I waiting on?", "what did I get done this week?"), and to add, reschedule, complete, tag, note, refile, archive or delete tasks and events.
---

# orgwarrior: the user's tasks and agenda

The user keeps their tasks in Org mode, run by an Emacs daemon. `orgwarrior`
is the command line over it: it asks that daemon, so what it shows is what
Emacs's agenda shows, and what it changes is saved as Emacs would save it.
**Always go through `orgwarrior`, never read or edit the Org files directly.**
`orgwarrior help` is the summary, `orgwarrior help TOPIC` the details (views,
dates, tags, notes, refile, closed, ...).

## Reading: answer from orgwarrior's output

Each task line starts with its ID (`8a1`), then its category, the
scheduled or deadline label, keyword, title and tags.

| Asked about | Run |
|---|---|
| today, "what's on my plate" | `orgwarrior today` |
| a day ("tomorrow", "friday", a date) | `orgwarrior +1d`, `orgwarrior fri`, `orgwarrior 2026-11-03` |
| this week | `orgwarrior week` |
| everything open | `orgwarrior all` |
| by state | `orgwarrior wait`, `orgwarrior next`, `orgwarrior done` (any of their TODO keywords) |
| by tag | `orgwarrior +@phone`, `orgwarrior next +@phone` |
| a word or phrase | `orgwarrior dentist` (headings and bodies) |
| anything ever archived | `orgwarrior --archive dentist` |
| what they got done | `orgwarrior closed week` (`lastweek`, `month`, `2026-10-20`; archived tasks too) |
| time clocked | `orgwarrior clocked week` |
| one task in full | `orgwarrior ID` (its notes, and its child headings with their IDs) |
| a file's headings | `orgwarrior projects.org` |

- A day's view holds what's scheduled and what's due that day
  (`Deadline:`), plus deadlines coming up (`In 3 d.:`). For "what's due",
  read the `Deadline:` lines.
- Their own views: the `[views]` table in `~/.config/orgwarrior/config.toml`
  (`orgwarrior NAME`). Read it fresh rather than assuming.
- Summarize in plain words; mention IDs only when they'll want to act on
  something.

## Changing tasks: only when the user asks

`orgwarrior ID... VERB [args]`; several IDs at once work. Find the ID by
reading first; if a title matches more than one task, ask which.

- State: `orgwarrior ID done` (any of their keywords). Where Org would ask
  for a note, pass one with `-m "..."`; without it there's no note.
- Dates: `orgwarrior ID sched fri`, `orgwarrior ID due +2w`, `none` clears.
  Org's date syntax: `fri`, `+2w`, `2026-11-01 14:00`, `fri 14:00-15:00`,
  repeaters and warnings after (`mon +1w`, `2026-11-01 -3d`): `orgwarrior
  help dates`.
- Tags: `orgwarrior ID +tag -tag`. Use tags they already use.
- `orgwarrior ID note TEXT`, `orgwarrior ID pri A`, `orgwarrior ID rename
  NEW TITLE`, `orgwarrior ID refile TARGET` (no target lists them),
  `orgwarrior ID archive`.
- `orgwarrior ID effort 1:30` (an estimate), `orgwarrior ID prop NAME VALUE`
  (any property; `none` removes it), `orgwarrior ID nokeyword` (a plain
  heading, no TODO keyword).
- Time: `orgwarrior ID clock in` (`clock in 9:40`), `orgwarrior clock out`
  (`clock out 17:30`); time already spent, a running clock left alone:
  `orgwarrior ID clocks add yesterday 14:00-15:30`, `clocks add 9:00 1h30m`.
- Structure, each with its subtree: `up`, `down`, `demote`, `promote`
  (`orgwarrior help up`).
- **`kill` deletes for good**: only on an explicit request, after showing
  what goes (`orgwarrior ID` lists its children). Off a terminal it needs
  `--yes`. For a task they won't do, a done keyword keeps it.
- `edit` and `open` need a terminal: tell the user to run them.

Report what changed from orgwarrior's output: it prints each task's new
line, and refile and rename print `old → new` IDs.

## Adding

`add` writes where the config's `[add]` says, usually an inbox the user
triages. One command; its first line is the heading in
orgwarrior's syntax, any lines after it the body:

```bash
orgwarrior add "$(cat <<'EOF'
Call the plumber :@phone: s:fri d:2026-11-01
Optional body: plain text, lists, or checkboxes.
- [ ] ask about the boiler
EOF
)"
```

- Leave the keyword off unless they name one: it defaults to the file's
  first.
- `:a:b:` tags anywhere on the line; `s:DATE` scheduled, `d:DATE`
  deadline, only when they give dates.
- Words that look like syntax (`s:x`, `d:x`, `:word:`) are read as syntax
  anywhere on the first line: reword, or move that text to the body.
- Elsewhere, only when they say where: `--to PLACE` (a refile target or a
  file, `--to projects.org`).
- **An event** (an appointment: no keyword, a plain timestamp):
  `orgwarrior add event Dentist @fri 14:00-15:00`. To move one later,
  `orgwarrior ID when sat 10:00` (not `sched`, which would add a second date).

It prints the new ID and heading; follow-ups use that ID.

## If it fails

orgwarrior's message says what's wrong (a bad date, an unknown keyword,
unsaved changes in Emacs, which it won't save over): fix and rerun, or
ask. If no Emacs daemon answers, say so: the user starts one.

**When in doubt about which task, tags, dates or anything else, ask
rather than guess.**
"""
