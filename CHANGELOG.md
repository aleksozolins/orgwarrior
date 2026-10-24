# Changelog

## 0.3.0 (2026-10-23)

- **Read-only files**: a file that isn't writable (`chmod a-w`), such as
  a calendar a script exports to org, is shown everywhere and changed
  nowhere. Every change is refused before anything happens, it's never a
  place to refile or add to, and `orgwarrior ID` says "read only".
  `orgwarrior help read-only`.
- `show` (the API) gives a task's category, as the agenda labels it.

## 0.2.0 (2026-10-22)

- **An event's date**: `orgwarrior ID when fri 14:00` sets or changes the
  plain timestamp under an event's heading (`none` removes it), the way
  `add event` writes it. Show keeps it apart from the event's text.

## 0.1.0 (2026-10-22)

- First public release.
