# orgwarrior

A taskwarrior-style command line for Org mode's agenda: `orgwarrior`
shows today's agenda with a short ID on every task, `orgwarrior k3 done`
acts on one. Org stays the single source of truth: orgwarrior never
parses org files, it asks the running Emacs daemon to do the work
(`org-agenda`, `org-todo`, `org-schedule`, `org-read-date`) and only
handles the command line.

Published, so nothing of anyone's setup is hardcoded; aliases and config
belong to the user. The browser side is orgwarrior-web (`../orgwarrior-web`,
its own CLAUDE.md). A `CLAUDE.local.md` beside this file, never committed,
holds the maintainer's own setup and to-do.

For real terminals, local or over SSH; the phone has orgwarrior-web, so
the CLI makes no allowances for narrow screens. Not chosen: driving
org's agenda buffer over SSH; a Python TUI that parses org itself (it
would drift from org's real agenda logic).

## How it works
- **Python CLI + an elisp engine** (`orgwarrior.el`, one entry point
  `orgwarrior-call`). Python: arguments, config, `emacsclient --eval`,
  output, help. Elisp: only what needs org. JSON both ways; a request
  goes in as a string literal, never as user text spliced into elisp;
  one past 64 KiB as a 0600 temp file the daemon reads (Linux caps one
  argument at 128 KiB: a long details text failed).
- **The engine ships in the package** and is loaded into the daemon when
  its stamp (path, mtime, size) differs from the loaded one: nothing in
  init.el, and an edit to it takes effect at the next call. The stamp has
  the path, so a CLI and a page from two installs would make Emacs reload
  it at every switch: one install for both.
- **Encrypted agenda files** (`.gpg`) not yet open in Emacs refuse every
  request up front (`orgwarrior--check-encrypted`, in dispatch): opening
  one asks for the passphrase, an error here or a pinentry window waiting
  out the timeout. Open in Emacs, they're decrypted already.
- **Emacs must never prompt** (it would hang `emacsclient`): requests run
  with `inhibit-interaction`, a prompt is an error saying so. Where org
  would ask for a note (`orgwarrior--wants-note` mirrors `org-todo`), the
  CLI asks on the terminal (blank for none, Ctrl-C cancels, `-m` up front,
  no terminal no note); the note is stored with `org-store-log-note` from
  a note buffer, so `org-after-note-stored-hook` runs as in Emacs (a user's
  hook may email someone from it). Org queues logging on
  `post-command-hook`, which never runs under `--eval`:
  `orgwarrior--flush-log` stores it.
- **Unsaved-buffer guard**: the daemon's buffers are shared with any
  interactive session; a file with unsaved changes is refused, never
  saved. orgwarrior saves just the files it changed (Syncthing carries
  them). An unmodified buffer older than its file (Syncthing wrote it) is
  reverted first.
- **Read-only files**: one that isn't writable (`orgwarrior--read-only-p`,
  the file's mode: a calendar a script exports and would overwrite) is
  refused by the same check (`orgwarrior--check-writable`, every writer,
  before anything changes), left out of the refile targets and add
  places, and marked `read_only` in show, view lines, outlines and
  `calendar` (the feed leaves it out). The mode, not a config list: Emacs
  itself honors it, and it lives with the file the script writes.
- **All day**: a view line that's an event on a day without a time (org's
  `type` timestamp, sexp or block, no `time-of-day`, no keyword) has
  `all_day`, for a front end to put first; the CLI keeps org's order.
- No daemon: one line ("no Emacs daemon running on socket … start one
  with `emacs --daemon`"), exit 1. `ALTERNATE_EDITOR` is stripped for
  `emacsclient` (set to an editor like nvim, with no daemon it launches and hangs).
  Exit 2 for a command line it can't read.
- A request binds `gc-cons-threshold` to 64 MB (if Emacs's is lower):
  with large agenda buffers live each collection costs ~0.1 s, and at the
  default 800 KB a big view spent most of its time collecting.
- **Config**: `$XDG_CONFIG_HOME/orgwarrior/config.toml` or
  `ORGWARRIOR_CONFIG`, all optional (`config.toml.example`; `help
  config`). `[web]` is orgwarrior-web's: kept as is, only checked to be a
  table.

## IDs
- Hash of the file (relative to `org-directory`) and the heading's
  **title only**: keyword, tags, priority and cookies change without
  changing the ID. Shortest unique prefix, 2 chars at least.
- No state file: an ID resolves against every heading in the agenda
  files, whatever view was shown. Each file's hashes are cached in the
  daemon (`orgwarrior--files`) until its text changes
  (`buffer-chars-modified-tick`, plus the file, `org-directory` and its
  keywords: what a hash is made of); a view's lines take their IDs from
  it by heading position. Actions work on **copies** of the entries
  (`orgwarrior--entries`): they move positions onto markers, which a
  cached entry must never keep. 20,000 extra headings: `today` 0.23 s,
  `show` 0.06 s; the first request after a change to the big file 0.6 s.
- A renamed, refiled or archived task stops matching ("no task k3"), and
  rename and refile print `old → new`. An ID is a prefix, so a new task's
  hash could start with a gone one's: each ID given out
  (`orgwarrior--given`, the daemon's memory) is reserved for a day after
  it was last shown; a new task gets a longer one, and the old one is
  refused, naming what it would have matched. Not chosen: per-client
  memory (no client identity; the page redraws every 5 minutes).
- A request that fails reverts each file buffer it changed and left
  unsaved (`orgwarrior--undo-failed`; the user's own unsaved ones left
  alone): a save that failed left the change in memory, shown in views,
  never synced, and the file refused until someone reverted it in Emacs.
- **Twins** (one title twice in a file; an archive collects them): the
  first keeps its title's hash, each later one is hashed with its number
  (2, 3, ...), so a title once in its file keeps its ID and each twin has
  one of its own (refusing them was a dead end for Claude and for
  someone who never opens Emacs). Accepted: a twin deleted, moved or renamed out, the next one
  takes its ID, so an old ID can reach the other twin. So a hash is found
  by position (`orgwarrior--hash-at-point`, the file's index), never
  remade from a title: refile reports where each landed (point in
  `org-after-refile-insert-hook`), and a clocked report's row for a twin
  (the clocktable gives titles only) has no ID.

## Views
- Built in: `today`, `week` (`week DATE`), `all`, a date (`fri`, `+2d`),
  a tag/property match (`+@phone`, `org-tags-view`), TODO states (`next
  active`, any of the user's keywords, any case, a match after: `next
  +@phone` → `+@phone/NEXT`), a text search (`org-search-view`), a file's
  outline (one word ending in `.org`), `clocked SPAN`, `closed SPAN`
  (what was done: org's agenda in log mode, only log items and only
  CLOSED ones, C-u C-u l; empty days and the diary left out). Only Emacs knows
  the keywords, so unknown words go as kind `words` and the elisp tries
  keywords, then a date, then a search; quoted, always a search. A
  `[views]` name runs that custom command and wins over a keyword unless
  arguments follow; a `week` there replaces the built-in.
- **Archives** (`--archive`, a request's `archive`): the archive files
  join the agenda files for that request (`org-agenda-archives-mode` t,
  org's `v A`), so a view, a report and the ID index take them in;
  `closed` always does (done tasks get archived). Org's agenda sets
  that mode globally from its start-with: bound per view, or it leaked
  into the next search. An archived task's ID is the archive file's
  (the file is in the hash) and only shows it: `show` looks in the
  archives when the agenda files have no match, actions never. An ID
  from an archive view can't name a live task: its prefix was unique
  among both.
- **Rendering**: org builds the agenda buffer as usual, then the engine
  walks its lines: a line with `org-hd-marker`/`org-marker` is a task and
  gets its ID; the rest print as they are. It must look like the real
  agenda plus an ID column, not a re-rendering. Date lines carry their
  ISO `date` (org's `day`) for front ends.
- **Colors**: faces map to roles (`orgwarrior--face-roles`; keywords are
  `todo`/`done` plus the name), roles and keywords to SGR in the CLI
  (defaults in `config.py`). 16 ANSI colors by default, following the
  terminal's theme; `#rrggbb`, `on-…` in `[colors]`.
- **Habits**: org-habit draws its graph at `org-habit-graph-column`, over
  the heading on a narrow prefix, so views bind the column to 1000 (only
  with org-habit loaded: binding it first leaves it void once it loads)
  and `orgwarrior--habit-graph` takes the graph off into the line's
  `habit` (text, spans with roles `habit-STATE`/`-future`, and `colors`).
  Colors through `orgwarrior--rgb` (hex parsed, names looked up), never
  `color-values`: it answers for the selected frame, and a daemon that
  never had a graphical frame (a second user's, started for them) has only a colorless one that
  rounds every color to a few. The CLI uses them unless `[colors]` sets
  the role, each glyph black or white by contrast (`cli.readable_on`);
  the page uses its theme's own.

## An Agent Skill
- `orgwarrior help --skill` prints a generic SKILL.md (`skill.py`) for an
  AI agent with a shell: the reading table, the verbs, adding, kill's
  care. Generated, so it matches the installed version; nothing of one
  person's setup (the agent reads the config). A test parses every
  command in it. A user's own habits go in their own CLAUDE.md, not the skill.

## Show
- `orgwarrior k3`: file › path, heading, planning line, body with drawers
  folded (`--drawers` unfolds and drops the notes block, which would
  repeat the LOGBOOK; a tag can't start with `-`), notes newest first,
  the direct children with their IDs.
- For front ends `show` also returns: raw `heading`/`title`/`body`,
  timestamps, `links` (and each line's by position), `priority` (the
  cookie's, not `org-entry-get`'s default), `notes`, `history`,
  `log_drawers`, `checkboxes`, `clocks`, `closed`, `properties`,
  `effort`, `from` (the `FROM` property), `parents`, each child's
  `child_count` (a front end shows there's more below), `prev`/`next`
  (siblings' titles, for Move's buttons), its file's `keywords` with fast
  keys. Notes are matched by a regexp built from `org-log-note-headings`,
  as `org-skip-over-state-notes` does, so custom templates read too.
- Text is what Emacs shows: a link reads as its description everywhere
  (org's `invisible` `org-link`), other invisible text kept (dropping it
  all would drop folded subtrees).
- `show` with `html`: the body as `ox-html` exports it, drawers and
  planning left out (planning by hand: alone, org reads it as a
  paragraph), babel off (a block never runs), source blocks colored by
  face name through `htmlize`.

## Verbs (`orgwarrior ID... VERB`)
What org already does, as org does it: a verb and a field each. Not what
needs state or logic of our own (comprehensive without being
crazy), nothing speculative. Several IDs per command work.
- **Dates** (`sched`, `due`): every word must be a date or time on its
  own (`orgwarrior--parse-date`): org skips words it doesn't know, so
  `dentist fri` read as Friday and `call 3 people` as the 3rd. A repeater
  or warning after the date needs a whole timestamp, so orgwarrior builds
  one; plain words keep an existing repeater, as org does; a whole
  `<...>` timestamp is exact (its cookies, or none, replace what was
  there): how a front end saves what its fields show.
- **An event's date** (`when`): the plain timestamp alone on the line
  under the planning line and drawers, where add event writes it
  (`orgwarrior--when-line`; one further down is the text's). Its own
  verb, as `sched` would add a second date; the same dates and repeater
  rule as `sched`, written by orgwarrior (org has no command for it).
  show's `when` and `when_line`; `html` leaves the line out, so a front
  end shows it as a field.
- **Keywords**: any of the task's file's (`#+TODO`), any case, written as
  the file spells it; any heading takes one, `nokeyword` removes it. A
  change org blocks (`org-enforce-todo-dependencies`, ORDERED, checkbox
  dependencies) is refused naming the blocker (`orgwarrior--check-unblocked`,
  org's `org-blocker-hook` asked as `org-todo` asks it): from code,
  `org-todo` only leaves it as it was, which read as done. Asked task by
  task, so a project's tasks and the project done in one request work.
- **Tags**: `+x -y` after an ID changes, first on the line searches. A
  tag from an exclusive `#+tags: { }` group replaces the others in it
  (org enforces that only in its menu), groups collected across the
  agenda files. No bulk action on a query (`+@phone done`), on purpose.
- **Refile**: targets are `org-refile-targets` plus each named file's
  top level. Matched by exact `file › path`, then a file's bare name
  (`todo.org` for `gtd/todo.org`: a setup in a folder of `org-directory`;
  `orgwarrior--agenda-file` the same for outlines and add's `--to`), then
  exact name, then a
  unique substring of the name, then of the path; ties go to the file the
  query names, then to one the tasks aren't all in; still several or
  none: listed. A task already there is reported, the rest move.
  `org-refile` itself, so filetags drop as in Emacs, with
  `org-after-refile-insert-hook` bound to nil (a user's may save every buffer,
  bypassing the guard). `--new TITLE [WHERE]` makes a plain heading first
  (`[refile] new_in`, `new_suffix`); `[refile] usual` is a front end's
  first choice (`api.usual_target`).
- **Structure**: `up`/`down` among siblings with the subtree; `demote`
  under the sibling above; `promote` right after its parent, moved below
  its later siblings first (org's M-S-left in place would make them its
  children). Op `reorder`: all of a parent's children in a new order, any
  other set refused as changed. Op `outline`: a file's whole tree in one
  request. `[/]` cookies follow every structural change
  (`orgwarrior--update-cookies`): org leaves them stale there.
- **kill** shows what goes (with a child count) and asks; no terminal
  refuses without `--yes`. **archive**: `org-archive-subtree`, so
  `org-archive-location` and ARCHIVE properties apply; the archive file is
  guarded and saved too. Both also as `orgwarrior kill|archive ID...` for
  aliases (`ow$` isn't a legal alias).
- **edit**: `emacsclient -t` on an indirect buffer narrowed to the
  subtree (other frames aren't narrowed); closing the frame reverts a
  still-modified file ("no" to saving means discard), safe because edit
  refuses an already-modified file.
- **rename**: the title only (`org-edit-headline`); refuses a title org
  would read as a keyword or tags. **open**: the entry's links (org's
  parser); one opens at once, else a list, `open N` picks; `http(s)` and
  `mailto` with `open`/`xdg-open`, the rest listed; no browser to be seen
  (SSH, no DISPLAY/WAYLAND_DISPLAY): the list, for the terminal to make
  clickable. **note**: org's `note` purpose (C-c C-z). **pri**: a value,
  `none`, or `up`/`down` as S-up/S-down step it (org decides: from none,
  up gives the lowest; past either end, removed).
- **prop NAME VALUE | none**, org's special properties refused; **effort
  DURATION | none** (`org-duration-p`, one of `Effort_ALL`'s where set).
  Op `props`: names in use and a name's `_ALL` values, for an editor.
- **Overnight** clocks (an end before the start) end the next day at the
  time given (`orgwarrior--next-day`, by the calendar, not 24 hours: a
  day with a clock change has 23 or 25, and 23:00-03:30 ended at 04:30).
- **Clocking**: org writes the lines (`org-clock-in`, `-out`,
  `org-clock-update-time-maybe`). The truth is the open CLOCK lines
  (`org-find-open-clocks`), not the daemon's memory: a restart loses
  nothing, another machine's clock shows once synced. The daemon forgets
  a clock whose line was closed elsewhere (`orgwarrior--clock-sync-memory`)
  or org, clocking in, would close it again over that end. Clocking in
  closes every open clock; two running makes `clock out` ask for an ID.
  Org's dangling-clock resolution and "start from the last clock out?"
  are bound off (they prompt). TIME: `17:30`, `5pm`, `-15m`, `+10m`,
  `yesterday 17:30` (not `parse-date`: org reads a bare time as no date).
  An end may be later than now, a start not (it would count down). In an
  edit a time is on that clock's date; an end before the start is the
  next day's only when that makes it under 12 h, else a typo. Past 4 h a
  clock is `stale` (org's idle detection needs a frame a phone never
  has).
- **Logged time** (op `clock-add`, `ID clocks add START-END` or `START
  DURATION`): a finished CLOCK line written where `org-clock-in` writes
  one (`org-clock-find-position`), its total by org, any running clock
  left alone: clocking in at a past time would close it then, and is
  refused before its start. Its end not later than now (time spent, not
  planned). For "log an hour on it yesterday", Claude's commonest ask.
- **History** (op `note-edit`): every log item numbered, rewritten under
  its first line as org wrote it, or removed (an emptied drawer too).
- **Not verbs, ops for front ends**: `check` (the Nth box in org's parse
  order, `org-toggle-checkbox`, so cookies follow), `set-entry` (all below
  the heading up to the first child, raw). Both take the text the front
  end showed and refuse if it changed underneath (Syncthing). A numbered
  list of boxes in the CLI would lose what makes them readable; `edit`
  has it all. Entry layout (`orgwarrior--entry-text`, set-entry and add):
  planning and drawers, one blank line, the body.
- **Headings in an entry's text** (set-entry, add's body) become its
  children (`orgwarrior--split-outline`, `--add-outline`): the text before
  the first heading is the body, the rest inserted after its existing
  children (they reorder as any), the shallowest typed heading one level
  below it and the rest as deep below that as typed (not
  `org-paste-subtree`: it takes the first heading's level and refuses text
  whose first isn't its shallowest). A heading line inside a
  `#+begin_`/`#+end_` block is escaped with a comma, as org escapes it. A
  heading with no title is refused. The answer's `new_children` counts
  them. The heading's cookie is recounted as C-c # does
  (`org-update-statistics-cookies`: `org-update-checkbox-count` alone
  zeroed a parent's `[1/3]`).
- **Reports** (`clocked [SPAN] [MATCH]`, op `report`): org's clocktable
  data (`org-clock-get-table-data`) over the agenda files, so totals
  agree with C-c C-x C-r. SPAN onto org's blocks (today, week, lastweek,
  month, 2026-W43, 2026-10…) or `A..B`, end included; the rest a tag
  match. Returns the label, `prev`/`next` spans for stepping, and per file
  rows `{depth, id, title, minutes, effort_minutes}`. A query, so tabs,
  `[views]` and MCP take it as is.
- **Calendar data** (op `calendar`, for orgwarrior-web's feed): every
  dated entry, the whole hash as `id` (stable: events update in place),
  each stamp parsed; diary sexps evaluated for the next DAYS days with
  `calendar-debug-sexp` bound (org otherwise beeps and sleeps 2 s a day on
  a broken one). Not `ox-icalendar`: it crashed on
  `%%(org-contacts-anniversaries)`, makes random UIDs unless it writes an
  `:ID:` into every entry, and has no keywords or alarms. A walk of the
  headings is milliseconds; a year of agenda was 10 s of frozen Emacs.

## Add
- `add [KEYWORD] title :tag: s:DATE d:DATE`: tokens anywhere; the keyword
  defaults to the file's first open one (done ones refused); a time,
  range, repeater or warning right after `s:`/`d:` belongs to it (a time
  needs a colon or am/pm, so a bare number stays in the title); lines
  after the first are the body. Never adds an `inbox` tag (the file's
  filetags do). Target `[add]` (file, heading, `captured`), else the end
  of `org-default-notes-file`.
- `add event TITLE @DATE`: no keyword, a plain timestamp under the
  heading (after any `:CAPTURED:` drawer: org finds a drawer only right
  below the heading); `[add.event]`, else `[add]`'s file. Events take the
  verbs that make sense; diary lines show without IDs.
- Elsewhere: `to` (`--to`, a place named as refile names one, from
  `add_places`, or any agenda file) or `under` (a heading's ID). The entry
  is that place's last child, keyword from its file; `""` adds a plain
  heading. Not org-capture templates: they prompt (`%^{...}`), which hangs
  the daemon.
- For front ends adding for someone else: `properties` (`:FROM: sam`),
  `where="task"` (an event filed with the tasks: one inbox to triage),
  `captured`; op `entries` (`api.entries_with`): what someone sent, as
  data.
- A form's title is one line, and a trailing `:word:` is refused unless
  tags follow it (org would read it as the tags): a newline in one wrote a
  heading of the sender's choosing, an add token's included. A property's
  value is one line too, from `prop` as from add.
- A done keyword only from fields (an import, orgwarrior-mcp): CLOSED
  from `closed` (not later than now), else now where `org-log-done` would
  stamp one. The add syntax still refuses `add DONE x`: typed, it's a
  slip.

## Supported, published
- **Emacs 29 and later**, tested on 29.4 (Org 9.6.15) and 31.1 (Org
  9.8). Org 9.7's element accessors are the engine's own `orgwarrior--el-*`
  over `org-element-property`; Org 9.6 has no
  `org-after-note-stored-hook`, so its test skips there. To recheck: build
  Emacs 29 from GNU's signed tarball with libjansson (before 30,
  `json-parse-string` needs it) and run the ERT suite with it.
- **GPL-3.0-or-later** (`LICENSE`, the SPDX line in `orgwarrior.el`).
- **Installed** with Homebrew (the tap's `orgwarrior` formula, with
  orgwarrior-web), from the AUR, or with pipx or uv from PyPI, published
  by `publish.yml` on a `v*` tag (trusted publishing; by hand with `gh
  workflow run publish.yml --ref vX.Y.Z` too). CI (`ci.yml`): ERT and
  pytest on Emacs 29.4 and 31.1; it caught a 9.7-only variable that broke
  every view on 29. README in Markdown; its
  screenshots come from orgwarrior-web's `scripts/screenshots` (made-up
  demo files, never real ones).

## Development
- `src/orgwarrior/`: `cli.py` (parse and print), `help.py`, `manpage.py`,
  `emacs.py` (the bridge), `config.py`, `api.py` (the engine for other
  programs; failures are `OrgwarriorError`), `orgwarrior.el` (byte-compiles
  without warnings: `emacs -Q --batch -f batch-byte-compile` on a copy).
- **Help**: every line within 78 columns; the main page is examples, one
  aligned line each, and every example parses (tests check both); topics
  hold the detail. `--help` (or `-h` where it can't be a `-tag`) anywhere
  gives that command's topic and never runs it (`cli.help_asked`: `add
  --help` once added a task). orgwarrior(1) is made from the help
  (`orgwarrior help --man`), committed as `docs/orgwarrior.1`; tests keep
  it the same and groff warning-free. uv links executables only, so the
  README writes it to `~/.local/share/man/man1`, which man-db finds from
  `~/.local/bin` on the PATH.
- **Tests**: `uv run pytest` runs everything. The elisp for real in ERT
  (`orgwarrior-test.el`, `emacs --batch`) on `tests/fixtures/org`
  (`{{+N}}`: N days from today, filled in by `fixture-init.el`), a second
  suite on a setup unlike the first (`orgwarrior-alt-test.el`, its own
  Emacs: mixed-case keywords and no TODO, a file's own `#+TODO`, numeric
  priorities, logging in the body), pytest for Python, including end to
  end against a throwaway daemon.
- **Sandbox**: `scripts/dev-daemon` (an `emacs -Q` daemon `orgwarrior-dev`
  on a fresh fixture copy, its config beside it), `scripts/dev-orgwarrior
  ...`, `scripts/dev-daemon stop`. It writes `.org` files only under its
  copy (`fixture-init.el`'s `orgwarrior-fixture--guard` on `write-region`;
  the tests load it too), so a client with the real config, a Python
  shell's `Orgwarrior(socket="orgwarrior-dev")`, gets an error, not a
  write to `~/org/inbox.org`. Linux and macOS, bash 3.2 up; the copy under
  `$XDG_RUNTIME_DIR`, else `$TMPDIR`. A socket path has ~104 characters
  at most, so a long `$TMPDIR` stops Emacs; `dev-daemon` shows its error.
- Out of scope: editing beyond the title in the CLI (`edit` hands it to
  Emacs), projects as a concept (org's refile setup is the structure),
  undo (kill confirms instead), a full-screen TUI, any network part
  (orgwarrior-web is its own package). What a front end needs goes into
  `api.py` only if it's generic.
- Commit messages: no AI-attribution footers.
