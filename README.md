<h1><img src="https://raw.githubusercontent.com/aleksozolins/orgwarrior/main/docs/logo.svg" alt="" width="44" align="top"> orgwarrior</h1>

[![tests](https://github.com/aleksozolins/orgwarrior/actions/workflows/ci.yml/badge.svg)](https://github.com/aleksozolins/orgwarrior/actions/workflows/ci.yml)

Your org agenda from the command line, taskwarrior-style. Every task
gets a short ID, and `orgwarrior ID VERB` acts on it.

<p align="center"><img src="https://raw.githubusercontent.com/aleksozolins/orgwarrior/main/docs/screenshots/cli-today.png" alt="orgwarrior showing today's agenda: the time grid, scheduled tasks, deadlines and habits with their consistency graphs" width="760"></p>

orgwarrior doesn't read your org files itself. It asks your running
Emacs to do the work, so your agenda files, TODO keywords, custom agenda
commands, logging, habits and refile targets behave exactly as they do in
Emacs.

- You don't need to change your Emacs config. orgwarrior loads its own
  code into Emacs when it needs to.
- IDs don't change. A task's ID comes from its file and title, so it's the
  same in every view and from one day to the next.

[orgwarrior-web](https://github.com/aleksozolins/orgwarrior-web) puts the
same agenda on a web page for your phone.
[orgwarrior-mcp](https://github.com/aleksozolins/orgwarrior-mcp) gives it
to Claude.

## Quick start

You'll need Emacs 29 or later with its server running, and your org
settings loaded in it. Any of these works:

- `emacs --daemon`, or your system's Emacs service
  (`systemctl --user enable --now emacs` on most Linux systems).
- On a Mac with Homebrew, `brew services start emacs` (or
  `brew services start emacs-plus@30` for emacs-plus).
- If you keep Emacs open as an app, add `(server-start)` to your init
  file. orgwarrior then works while Emacs is open.

Then install orgwarrior one of these ways:

```sh
brew install aleksozolins/tap/orgwarrior   # macOS or Linux
yay -S orgwarrior                          # Arch, with any AUR helper
pipx install orgwarrior                    # Python 3.11+; uv tool install works too
```

Installing orgwarrior-web or orgwarrior-mcp also installs this command, so
you only need one of them.

```sh
orgwarrior --check      # checks Emacs, your agenda files and the rest
orgwarrior              # today's agenda
orgwarrior help         # all the commands on one screen
```

`--check` says what's missing and how to fix it. Once it's happy, you'll
see what your Emacs agenda shows.

To act on a task, use the ID shown beside it:

```sh
orgwarrior c1 done -m "booked for the 20th"
orgwarrior 32 sched fri
orgwarrior add NEXT call the dentist :@phone: s:fri
```

To update, use the tool you installed with: `brew upgrade`, your AUR
helper, or `pipx upgrade orgwarrior`. `alias ow=orgwarrior` saves typing.

Homebrew and the AUR install the man page. With pipx or uv, copy it to
where `man` looks, and do it again after each upgrade:

```sh
mkdir -p ~/.local/share/man/man1
orgwarrior help --man > ~/.local/share/man/man1/orgwarrior.1
```

## Everyday use

| command | what it does |
|---|---|
| `orgwarrior` | shows the default view (today) |
| `orgwarrior week`, `orgwarrior fri`, `orgwarrior all` | this week, one day, or every open TODO |
| `orgwarrior +@phone`, `orgwarrior next +@phone` | tasks with a tag, or in a TODO state with a tag |
| `orgwarrior flu shot` | searches text; add `--archive` to search archived tasks too |
| `orgwarrior projects.org` | shows a file's outline |
| `orgwarrior c1` | shows a task: where it lives, its text, notes and child headings |
| `orgwarrior c1 done`, `orgwarrior c1 wait` | sets any of your TODO keywords, asking for a note where org would |
| `orgwarrior c1 sched fri 14:00`, `orgwarrior c1 due +2w` | sets dates, written the way org reads them |
| `orgwarrior c1 +@home -someday`, `orgwarrior c1 pri A` | changes tags and priority |
| `orgwarrior c1 refile projects` | refiles under a heading; with no target, lists them |
| `orgwarrior c1 clock in`, `orgwarrior clock out` | clocks in and out; `orgwarrior clocked week` totals the time |
| `orgwarrior c1 clocks add yesterday 14:00-15:30` | logs time already spent, without touching a running clock |
| `orgwarrior closed week` | lists what you finished, day by day, archived tasks included |
| `orgwarrior c1 edit` | opens the task in Emacs, in this terminal |
| `orgwarrior add event Dentist @fri 10:30` | adds an event (a plain timestamp, no keyword) |
| `orgwarrior c1 when sat 10:30` | moves an event to another date |

Most commands take several IDs at once: `orgwarrior c1 32 done`.
`orgwarrior help TOPIC` explains each part with examples (`help dates`,
`help refile`, `help clock`…), and `--help` works after any command.

<p align="center">
  <img src="https://raw.githubusercontent.com/aleksozolins/orgwarrior/main/docs/screenshots/cli-show.png" alt="orgwarrior showing one task: where it is, its planning line, folded drawers, its body with a table, and its notes" width="560">
  <img src="https://raw.githubusercontent.com/aleksozolins/orgwarrior/main/docs/screenshots/cli-clocked.png" alt="orgwarrior clocked week: each file, its headings and the time each holds, against their effort" width="560">
</p>

## How it works

Org is the task manager. orgwarrior is a friendlier set of commands on
top of it, the way Git's everyday commands sit on top of its internals.

```
  orgwarrior          orgwarrior-web         orgwarrior-mcp
  (a terminal)        (a browser)            (Claude, any MCP client)
          \                 |                 /
       orgwarrior.el, loaded into your running Emacs
                            |
             Org mode  ──▶  your .org files
```

Each command goes to your Emacs daemon through `emacsclient`.
orgwarrior's elisp then has Org do the work: build the agenda, change a
heading, read a date. Org writes the file just as it would from the
agenda buffer, so logging, repeaters, `[1/3]` cookies and hooks all work
as usual.

- **IDs** are short hashes of the file and the heading's title, like Git's
  commit IDs. Changing a task's keyword, tags or dates keeps its ID.
  Renaming or refiling it gives it a new one, and orgwarrior prints the
  change (`6a → 91`). An old ID stops matching instead of pointing at a
  different task. For a day afterwards, while Emacs runs, a new task that
  would get the same ID gets a longer one.
- **Notes**: where Emacs would ask for a note (`@` in `org-todo-keywords`,
  or a `LOGGING` property), orgwarrior asks in the terminal. `-m` gives it
  up front.
- **Safety**: if a file has unsaved changes in Emacs, orgwarrior refuses to
  touch it rather than save someone's half-finished edit. `kill` asks
  before deleting.
- **Read-only files**: a file that isn't writable (`chmod a-w`) is shown
  but never changed. This is meant for a calendar that a script exports
  to org, from vdirsyncer or Google for example. Every change to it is
  refused, it's never offered as a place to refile or add to, and
  orgwarrior-web's calendar feed leaves it out, since your calendar app
  already has the original.

## Configuration

Everything is optional. The config file is
`~/.config/orgwarrior/config.toml` (or under `$XDG_CONFIG_HOME`, or
wherever `ORGWARRIOR_CONFIG` points).
[`config.toml.example`](https://github.com/aleksozolins/orgwarrior/blob/main/config.toml.example)
lists every key with comments.

| key | what it does |
|---|---|
| `default_view` | the view plain `orgwarrior` shows (default `today`) |
| `socket` | the Emacs server socket, if it isn't the default (also `-s` or `ORGWARRIOR_SOCKET`) |
| `prefix_format` | an `org-agenda-prefix-format` used only by orgwarrior |
| `tags` | `inline` puts tags after the title (the default), `right` aligns them right |
| `time_grid` | `true` keeps Org's time grid |
| `color` | `auto` (color on a terminal, unless `NO_COLOR` is set), `always` or `never` |
| `[views]` | `name = "key"` makes an `org-agenda-custom-commands` entry a view; a `week` here replaces the built-in one |
| `[add]` | where `add` writes: a `file` (otherwise Emacs's `org-default-notes-file`), a `heading` to file under, and `captured = true` to stamp a `:CAPTURED:` time |
| `[add.event]` | the same, for `add event` |
| `[refile]` | `new_in` and `new_suffix` for `refile --new`; `usual`, the target a front end offers first |
| `[colors]` | colors for a role or TODO keyword: `bold cyan`, `#ff8f88`, `on-green`… (see `orgwarrior help colors`) |
| `[web]` | settings for orgwarrior-web; orgwarrior ignores them |

## Troubleshooting

Start with `orgwarrior --check`. It checks Emacs, your init file, your
agenda files, where `add` writes and your config, and says what to fix.

- **"no Emacs daemon is running"**: start Emacs as a daemon
  (`emacs --daemon`), or add `(server-start)` to your init file if you
  keep Emacs open as an app. If your daemon runs under another name
  (`emacs --daemon=work`), set `socket = "work"` in the config.
- **Every view is empty**: Emacs has no `org-agenda-files`. Set them in
  your init file (`(setq org-agenda-files '("~/org"))`; a directory works),
  or add a file with `C-c [`, as you would for Org's agenda.
- **"There's no file to add to"**: `add` writes to `org-default-notes-file`
  unless `[add] file` names another file. Point it at your inbox.
- **"… is encrypted and not open in Emacs"**: an agenda file is `.gpg`,
  and orgwarrior can't type its passphrase. Open it in Emacs once (it stays
  decrypted while Emacs runs), or take it out of `org-agenda-files`.
- **"Emacs tried to ask a question"**: something in your Emacs, such as a
  hook, wanted to ask something. orgwarrior can't answer, so it stops. Do
  the same thing in Emacs itself to see what it asks.
- **Colors look wrong**: `color = "never"` or `NO_COLOR=1` turns them off,
  and `[colors]` changes any of them.

## From Python

Other programs can use the same code through `orgwarrior.api`;
orgwarrior-web is built on it. Views, tasks and actions come back as
plain data.

```python
from orgwarrior.api import Orgwarrior

ow = Orgwarrior()             # uses your config.toml and daemon
ow.view("wait +@phone")       # [{"text", "id", "spans"}, ...]
ow.show("c1")                 # {"id", "file", "path", "lines", "children"}
ow.show("c1", html=True)      # ... plus "html": its text as org exports it
ow.act(["c1"], "done", note="booked")
```

## With Claude

[Claude Code](https://claude.com/claude-code), or any AI agent with a
shell on the machine running your Emacs, can use orgwarrior for you. A
skill file teaches it how: reading views and IDs, the verbs, adding
tasks, and asking before it deletes anything.

```sh
mkdir -p ~/.claude/skills/orgwarrior
orgwarrior help --skill > ~/.claude/skills/orgwarrior/SKILL.md
```

Then ask things like "what's due this week?" or "what did I get done
yesterday?". Run the command again after an upgrade to pick up new
features. Put your own preferences (your inbox's tags, keywords it should
leave alone) in `~/.claude/CLAUDE.md`, which the command never
overwrites.

Where Claude can't run commands on that machine (claude.ai, the phone
apps), [orgwarrior-mcp](https://github.com/aleksozolins/orgwarrior-mcp)
gives it the same agenda as MCP tools.

## Development

```sh
git clone https://github.com/aleksozolins/orgwarrior
cd orgwarrior
uv tool install --editable .   # the orgwarrior command runs this checkout
uv run pytest                  # all tests, including the ERT suite
scripts/dev-daemon             # a throwaway emacs -Q daemon on test files
scripts/dev-orgwarrior today   # orgwarrior against that daemon
scripts/dev-daemon stop
```

The dev daemon never touches your real Emacs, config or org files. It
only writes to its own copy of the test files. The scripts run on Linux
and macOS. Tested on Emacs 29.4 (Org 9.6) and 31.1 (Org 9.8).

Claude (Anthropic's AI) was used in developing orgwarrior. I review all
the code, and every behavior is covered by tests.

## Contributing

I read every issue and fix what I can, bugs first. Pull requests are
welcome. For anything big, open an issue first so we can talk it through.
`uv run pytest` runs every test ([Development](#development)).

## License

[GPL-3.0-or-later](https://github.com/aleksozolins/orgwarrior/blob/main/LICENSE), the same as Emacs and Org.
