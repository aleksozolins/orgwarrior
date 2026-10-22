<h1><img src="https://raw.githubusercontent.com/aleksozolins/orgwarrior/main/docs/logo.svg" alt="" width="44" align="top"> orgwarrior</h1>

[![tests](https://github.com/aleksozolins/orgwarrior/actions/workflows/ci.yml/badge.svg)](https://github.com/aleksozolins/orgwarrior/actions/workflows/ci.yml)

**A porcelain for Org's agenda.** Your tasks from the command line, with
the Emacs you already run doing all the Org work: a
[taskwarrior](https://taskwarrior.org)-style CLI where every task gets a
short ID, and `orgwarrior ID VERB` acts on it.

<p align="center"><img src="https://raw.githubusercontent.com/aleksozolins/orgwarrior/main/docs/screenshots/cli-today.png" alt="orgwarrior showing today's agenda: the time grid, scheduled tasks, deadlines and habits with their consistency graphs" width="760"></p>

- **Org does the work.** orgwarrior never parses your files: it asks your
  running Emacs (`org-agenda`, `org-todo`, `org-schedule`,
  `org-read-date`). Your agenda files, TODO keywords, custom agenda
  commands, logging, habits and refile targets all apply as in Emacs.
- **Nothing to set up in Emacs.** It loads its own elisp into the daemon
  when it needs to; your `init.el` stays as it is.
- **IDs that stay put.** A task's ID comes from its file and title, so it's
  the same in every view and from one day to the next.

Want it on your phone too? [orgwarrior-web](https://github.com/aleksozolins/orgwarrior-web)
is a web page over the same engine, and [orgwarrior-mcp](https://github.com/aleksozolins/orgwarrior-mcp)
gives it to Claude.

## Quick start

You need **Emacs 29 or later running as a daemon** (`emacs --daemon`, or
your system's Emacs service). Then one of:

```sh
brew install aleksozolins/tap/orgwarrior   # macOS or Linux, with Homebrew
yay -S orgwarrior                          # Arch, from the AUR (any AUR helper)
pipx install orgwarrior                    # anywhere with Python 3.11+ (or: uv tool install orgwarrior)
```

Want the web page or Claude too? Install
[orgwarrior-web](https://github.com/aleksozolins/orgwarrior-web) or
[orgwarrior-mcp](https://github.com/aleksozolins/orgwarrior-mcp) instead:
each brings this command along, sharing one copy of the engine.

```sh
orgwarrior              # today's agenda
orgwarrior help         # everything on one screen
```

It shows what Emacs's agenda shows, from your `org-agenda-files`: if every
view is empty, Emacs has none set. Then act on a task by the ID beside it:

```sh
orgwarrior c1 done -m "booked for the 20th"
orgwarrior 32 sched fri
orgwarrior add NEXT call the dentist :@phone: s:fri
```

Update as you installed it (`brew upgrade`, your AUR helper, `pipx upgrade
orgwarrior`). An alias saves typing: `alias ow=orgwarrior`. Homebrew and
the AUR install the man page; with pipx or uv, put it where `man` looks
(again after an upgrade):

```sh
mkdir -p ~/.local/share/man/man1
orgwarrior help --man > ~/.local/share/man/man1/orgwarrior.1
```

## Everyday use

| | |
|---|---|
| `orgwarrior` | the default view (today) |
| `orgwarrior week`, `orgwarrior fri`, `orgwarrior all` | this week, one day, every open TODO |
| `orgwarrior +@phone`, `orgwarrior next +@phone` | a tag search, a TODO state with one |
| `orgwarrior flu shot` | a text search; `--archive` searches the archives too |
| `orgwarrior projects.org` | an agenda file's outline |
| `orgwarrior c1` | show a task: its path, body, notes and children |
| `orgwarrior c1 done`, `orgwarrior c1 wait` | any of your TODO keywords (asks for a note where org would) |
| `orgwarrior c1 sched fri 14:00`, `orgwarrior c1 due +2w` | dates, as `org-read-date` reads them |
| `orgwarrior c1 +@home -someday`, `orgwarrior c1 pri A` | tags, priority |
| `orgwarrior c1 refile projects` | refile under a heading (alone, it lists the targets) |
| `orgwarrior c1 clock in`, `orgwarrior clock out` | clocking; `orgwarrior clocked week` totals it |
| `orgwarrior c1 clocks add yesterday 14:00-15:30` | time already spent, a running clock left alone |
| `orgwarrior closed week` | what was done, day by day, archived tasks too |
| `orgwarrior c1 edit` | the task in Emacs, in this terminal |
| `orgwarrior add event Dentist @fri 10:30` | an event: a plain timestamp, no keyword |

`orgwarrior help TOPIC` covers each part in full, with examples (`help
dates`, `help refile`, `help clock`…), and so does `--help` after any
command. Several IDs at once work too: `orgwarrior c1 32 done`.

<p align="center">
  <img src="https://raw.githubusercontent.com/aleksozolins/orgwarrior/main/docs/screenshots/cli-show.png" alt="orgwarrior showing one task: where it is, its planning line, folded drawers, its body with a table, and its notes" width="560">
  <img src="https://raw.githubusercontent.com/aleksozolins/orgwarrior/main/docs/screenshots/cli-clocked.png" alt="orgwarrior clocked week: each file, its headings and the time each holds, against their effort" width="560">
</p>

## How it works

orgwarrior isn't a task manager: Org is. In Git's terms Org is the
plumbing, and orgwarrior a porcelain: friendlier commands over machinery
that already works.

```
  porcelain    orgwarrior       orgwarrior-web       orgwarrior-mcp
               a terminal       a browser            Claude, any MCP client
                       \             |              /
  engine          orgwarrior.el, loaded into your running Emacs
                                 |
  plumbing        Org mode  ──▶  your .org files
```

A small Python program sends each command to your Emacs daemon with
`emacsclient`, where its elisp drives Org: building the agenda, changing a
heading, reading a date. Org writes the file, as it would from the agenda
buffer, so logging, repeaters, `[1/3]` cookies and hooks behave as in
Emacs.

- **IDs** are short hashes of the file and the heading's title, git-style.
  Changing a task's keyword, tags or dates keeps its ID; renaming or
  refiling it changes it, and the new one is printed (`6a → 91`). A task
  that's gone simply stops matching, and its ID stays its own for a day
  while Emacs runs (a new task that would share it gets a longer one), so
  a stale ID can't act on the wrong task.
- **Notes**: where Emacs would ask for one (`@` in `org-todo-keywords`, a
  `LOGGING` property), orgwarrior asks on the terminal. `-m` answers up
  front.
- **Safety**: if a file has unsaved changes in Emacs, orgwarrior refuses
  rather than save someone's half-finished edit. `kill` asks first.

## Configuration

All optional: `~/.config/orgwarrior/config.toml` (or `$XDG_CONFIG_HOME`,
or `ORGWARRIOR_CONFIG`). [`config.toml.example`](https://github.com/aleksozolins/orgwarrior/blob/main/config.toml.example) has
every key, commented.

| key | what it does |
|---|---|
| `default_view` | the view for bare `orgwarrior` (default `today`) |
| `socket` | the Emacs server socket, if not the default (also `-s` or `ORGWARRIOR_SOCKET`) |
| `prefix_format` | `org-agenda-prefix-format`, for orgwarrior only |
| `tags` | `inline` (after the title, the default) or `right` |
| `time_grid` | `true` to keep Org's time grid |
| `color` | `auto` (on a terminal, unless `NO_COLOR`), `always`, `never` |
| `[views]` | `name = "key"`: an `org-agenda-custom-commands` entry as a view; a `week` here replaces the built-in one |
| `[add]` | where `add` writes: `file` (else Emacs's `org-default-notes-file`), a `heading` to file under, `captured = true` for a `:CAPTURED:` time |
| `[add.event]` | the same for `add event` |
| `[refile]` | `new_in` and `new_suffix` for `refile --new`; `usual`, a front end's first choice |
| `[colors]` | a role or TODO keyword → `bold cyan`, `#ff8f88`, `on-green`… (`orgwarrior help colors`) |
| `[web]` | orgwarrior-web's settings; orgwarrior itself ignores them |

## If something's wrong

- **"no Emacs daemon running on socket 'server'"**: start Emacs as a
  daemon (`emacs --daemon`). If yours runs under another name
  (`emacs --daemon=work`), set `socket = "work"` in the config.
- **An empty agenda**: Emacs has no `org-agenda-files`. Set them in your
  init (`(setq org-agenda-files '("~/org"))`, a directory works), or with
  `C-c [` in a file, as for Org's agenda.
- **"File to add to not found"**: `add` writes to `org-default-notes-file`
  unless `[add] file` says otherwise; point it at your inbox.
- **"… is encrypted and not open in Emacs"**: an agenda file is `.gpg`, and
  orgwarrior can't type its passphrase. Open it in Emacs once (it stays
  decrypted while Emacs runs), or leave it out of `org-agenda-files`.
- **"Emacs tried to prompt"**: something in your Emacs wanted to ask a
  question (a hook, an unsaved-file prompt). orgwarrior can't answer
  prompts, so it stops; the message says which one.
- **Odd colors**: `color = "never"`, or `NO_COLOR=1`, turns them off;
  `[colors]` changes any of them.

## From Python

`orgwarrior.api` is the same engine for other programs (orgwarrior-web is
built on it): views, tasks and actions as plain data.

```python
from orgwarrior.api import Orgwarrior

ow = Orgwarrior()             # your config.toml and daemon
ow.view("wait +@phone")       # [{"text", "id", "spans"}, ...]
ow.show("c1")                 # {"id", "file", "path", "lines", "children"}
ow.show("c1", html=True)      # ... plus "html": its text as org exports it
ow.act(["c1"], "done", note="booked")
```

## With Claude

[Claude Code](https://claude.com/claude-code), or any AI agent with a
shell on the machine with your Emacs, can run orgwarrior for you. A skill
teaches it how: reading views and IDs, the verbs, adding, asking before
it deletes anything.

```sh
mkdir -p ~/.claude/skills/orgwarrior
orgwarrior help --skill > ~/.claude/skills/orgwarrior/SKILL.md
```

Then ask "what's due this week?" or "what did I get done yesterday?".
Write it again after an upgrade, for what's new. Your own habits (your
inbox's tags, keywords you'd rather it left alone) go in your
`~/.claude/CLAUDE.md`, which a rewrite leaves alone.
Where Claude can't run commands on that machine (claude.ai, the phone
apps), [orgwarrior-mcp](https://github.com/aleksozolins/orgwarrior-mcp)
gives it the same agenda as MCP tools.

## Development

```sh
git clone https://github.com/aleksozolins/orgwarrior
cd orgwarrior
uv tool install --editable .   # the orgwarrior command runs this checkout
uv run pytest                  # everything, the ERT suite included
scripts/dev-daemon             # a throwaway emacs -Q daemon on test fixtures
scripts/dev-orgwarrior today   # orgwarrior against it
scripts/dev-daemon stop
```

The dev daemon never touches your real Emacs, config or Org files: it
writes Org files only in its own copy, whatever config talks to it. The
scripts run on Linux and macOS. Tested on Emacs 29.4 (its Org 9.6) and
31.1 (Org 9.8).

Claude (Anthropic's AI) was used in developing orgwarrior. All code is reviewed
by me, and every behavior is covered by real tests.

## Contributing

I read every issue and fix what I can, bugs first. Pull requests are
welcome; for anything big, open an issue first so we can talk it through.
`uv run pytest` runs every test ([Development](#development)).

## License

[GPL-3.0-or-later](https://github.com/aleksozolins/orgwarrior/blob/main/LICENSE), as Emacs and Org are.
