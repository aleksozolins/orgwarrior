# Changelog

## 0.5.1 (2026-10-26)

- On a Mac, a long view (a busy day's agenda, say) could fail with "Emacs
  sent a reply orgwarrior doesn't understand". emacsclient on macOS garbles
  long results, so Emacs now writes its reply to a private temporary file
  instead of printing it.

## 0.5.0 (2026-10-25)

- `entries_with(prop, None)` in the Python API finds every entry with the
  property set, whatever its value, and each entry now comes with its ID
  and the property's value. orgwarrior-web uses it for its notifications.
- The README opens with a list of what orgwarrior does.

## 0.4.4 (2026-10-25)

- The tests pass on a system that isn't in English. Org writes weekday
  names in the system's language, and the tests expected English ones, so
  the AUR package failed to build there (#1).

## 0.4.3 (2026-10-24)

From a newcomer's second run through the quick start:

- When `org-default-notes-file` is set but the file doesn't exist yet, the
  message just says to create it (it can be empty). Only org's own default,
  `~/.notes`, still gets the advice on where to point it.
- `--check` wraps a long message from Emacs instead of printing it on one
  line.

## 0.4.2 (2026-10-24)

From a newcomer's run through the quick start:

- **The quick start has a starter init file**: `org-agenda-files`,
  `org-default-notes-file`, `org-refile-targets` and `org-log-done`, in
  `~/.emacs.d/init.el`. It also says up front to install orgwarrior-web or
  orgwarrior-mcp instead if you'll want them, since installing more than
  one with pipx or uv fails.
- **`--check` points at `~/.emacs.d/init.el`**, which Emacs always reads.
  Pointing at `~/.config/emacs/init.el` led straight to the next problem,
  since Emacs makes `~/.emacs.d` on its first start.
- **`--check` warns when `org-log-done` is off**: without it, finished
  tasks get no CLOSED time and `orgwarrior closed` stays empty.
- When there's no file to add to, the message shows the setting to fix,
  in the init file or in the config.
- The examples no longer assume a NEXT keyword, and the README says that
  a word that isn't one of your keywords stays part of the title.
- The README spells out the uv commands and what refile does with a file's
  name.

## 0.4.1 (2026-10-24)

- The README's section on read-only files links to orgwarrior-web's guide
  for showing a Google or other calendar in your agenda.

## 0.4.0 (2026-10-24)

Getting set up is the theme of this release: a new user should be able to
go from install to a working agenda without guessing.

### Checking your setup

- **`orgwarrior --check`** looks at everything orgwarrior depends on and
  says what to fix. It reports:
  - your config file, and any problem in it (it still runs when the config
    doesn't load);
  - `emacsclient`, and whether an Emacs server is running, with the
    socket's full path (handy for a desktop app's MCP config);
  - the Emacs and Org versions, and whether Emacs is a daemon or an app
    running `(server-start)`, which stops when you close it;
  - which init file Emacs loaded. It catches the common trap where Emacs
    ignores `~/.config/emacs/init.el` because `~/.emacs.d` exists (a
    native-compiling Emacs makes that folder on its first start);
  - your agenda files, any that are read only, encrypted and not open, or
    have unsaved changes, and any path in `org-agenda-files` that doesn't
    exist;
  - where `add` writes, and whether that file and heading exist;
  - whether `org-refile-targets` is set, with a line to add if it isn't;
  - whether each `[views]` entry names an agenda command Emacs has.

  It exits 1 if anything has to be fixed. It's an option rather than a
  command, so `orgwarrior doctor` is still a search for "doctor".
- **An empty view says why.** When there are no agenda files Emacs can
  find, a view says so and points to `--check`, instead of showing a bare
  date.
- **A missing agenda file no longer breaks everything.** A path in
  `org-agenda-files` that doesn't exist used to make org stop and ask
  "Remove from list?", which orgwarrior can't answer, so every command
  failed. It's now skipped (`--check` names it).

### Clearer messages

- **Every error message is rewritten** to say what went wrong and what to
  do, in whole sentences. Some examples:
  - "Can't parse date: soon" is now "Can't read soon as a date. Try fri,
    +2d, 2026-10-15 or fri 14:00".
  - "Unknown verb: frob" is now "There's no command frob", followed by your
    keywords.
  - "no Emacs daemon running" now also mentions `(server-start)` and
    `--check`.
  - Config mistakes say which table has no such key, and point to
    `orgwarrior help config`.
- A timeout says Emacs may be waiting for you to answer something in
  Emacs, and "Emacs tried to prompt" now reads "Emacs tried to ask a
  question" and says how to find out what.

### Docs

- The README explains running Emacs's server three ways: `emacs --daemon`
  or your system's service, `brew services start emacs` on a Mac, or
  `(server-start)` if you keep Emacs open as an app.
- The quick start begins with `orgwarrior --check`, and so does
  Troubleshooting.
- The help, man page and Claude skill mention `--check`.

## 0.3.1 (2026-10-24)

- Views now mark events that have no time (a plain date, a diary sexp, or
  one day of a date range) as `all_day` in the API, so a front end can
  list them first. The command line keeps org's order.
- The help, the man page and the README are rewritten to be shorter and
  clearer.

## 0.3.0 (2026-10-23)

- **Read-only files**: a file that isn't writable (`chmod a-w`), like a
  calendar a script exports to org, shows up everywhere but can't be
  changed. Every change is refused before anything happens, and it's
  never offered as a place to refile or add to. `orgwarrior ID` says
  "read only". See `orgwarrior help read-only`.
- `show` (in the API) now includes a task's category, as the agenda shows
  it.

## 0.2.0 (2026-10-22)

- **An event's date**: `orgwarrior ID when fri 14:00` sets or changes the
  plain timestamp under an event's heading, the way `add event` writes it
  (`none` removes it). `show` keeps it separate from the event's text.

## 0.1.0 (2026-10-22)

- First public release.
