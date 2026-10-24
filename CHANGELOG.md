# Changelog

## 0.4.0 (2026-10-24)

- **`orgwarrior --check`** checks your setup and says what to fix: whether
  Emacs's server is running (and its socket), which init file Emacs
  loaded, your agenda files, where `add` writes, your refile targets and
  your config. It catches the usual first-run traps, like an init file in
  `~/.config/emacs` that Emacs ignores because `~/.emacs.d` exists.
- An empty view with no agenda files now says why, instead of showing
  nothing.
- A path in `org-agenda-files` that doesn't exist is skipped, where before
  org stopped to ask about it and every command failed.
- **Every error message rewritten** to say plainly what went wrong and
  what to do, as whole sentences. "Can't parse date: soon" is now "Can't
  read soon as a date. Try fri, +2d, 2026-10-15 or fri 14:00".
- The README explains running Emacs's server on a Mac, or with
  `(server-start)` if you keep Emacs open as an app.

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
