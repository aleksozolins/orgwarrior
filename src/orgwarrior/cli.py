"""The `orgwarrior` command line: parse, ask Emacs, print."""

import contextlib
import datetime
import os
import re
import shutil
import subprocess
import sys
import unicodedata
from dataclasses import dataclass, field

from orgwarrior import OrgwarriorError, __version__, config as configmod, emacs, help as helpmod

BUILTIN_VIEWS = ("today", "week", "all")
ID_RE = re.compile(r"[0-9a-f]{2,40}")
RELATIVE_DATE_RE = re.compile(r"[+-]{1,2}\d+[hdwmy]?")
# An agenda file as IDs name it (projects.org, work/notes.org): its outline.
FILE_RE = re.compile(r'[^\s"]+\.org')


class UsageError(OrgwarriorError):
    pass


@dataclass
class View:
    kind: str  # today week all words tags search custom closed
    arg: str | None = None
    archive: bool = False  # --archive: the archive files too


@dataclass
class Show:
    ids: list[str]
    drawers: bool = False  # unfolded, the notes as they are in the file


@dataclass
class Outline:
    file: str


@dataclass
class Act:
    ids: list[str]
    verb: str
    args: list[str] = field(default_factory=list)
    note: str | None = None
    yes: bool = False  # kill: skip the confirmation
    new: str | None = None  # refile --new: the title of a heading to make first


@dataclass
class Add:
    text: str
    event: bool = False
    to: str | None = None  # a place, as refile names a target
    under: str | None = None  # a heading's ID


@dataclass
class Clock:
    action: str  # status in out cancel
    ids: list[str] = field(default_factory=list)
    time: str | None = None
    short: bool = False  # status as one line, for a status bar


@dataclass
class Clocks:
    id: str
    n: int | None = None  # a clock to change, else the list
    start: str | None = None
    end: str | None = None
    remove: bool = False


@dataclass
class ClockAdd:
    id: str
    start: str
    end: str | None = None
    duration: str | None = None


@dataclass
class Report:
    words: str = ""  # a span (today, week, 2026-10, a range), then a tag match
    archive: bool = False


@dataclass
class Help:
    topic: str | None = None
    man: bool = False  # help --man: the man page's roff (manpage.py)
    skill: bool = False  # help --skill: an Agent Skill's SKILL.md (skill.py)


@dataclass
class Version:
    pass


def view_for(name: str, config: configmod.Config) -> View | None:
    if name in config.views:
        return View("custom", config.views[name])
    if name in BUILTIN_VIEWS:
        return View(name)
    return None


def parse(argv: list[str], config: configmod.Config) -> tuple[object, str | None]:
    """Parse `argv` into a command, plus the --socket given (if any)."""
    args = list(argv)
    # --archive anywhere, but not inside what add takes as text.
    archive = "--archive" in args and "add" not in args[:args.index("--archive")]
    if archive:
        args.remove("--archive")
    command, socket = parse_command(args, config)
    if archive:
        if not isinstance(command, (View, Report, Show)) or getattr(command, "kind", "") == "custom":
            raise UsageError("--archive only works with a search, a tag or state match, or clocked")
        if not isinstance(command, Show):  # an archived task's ID shows it anyway
            command.archive = True
    return command, socket


def parse_command(args: list[str], config: configmod.Config) -> tuple[object, str | None]:
    socket = None
    while args and args[0] in ("-s", "--socket", "-h", "--help", "--version"):
        opt = args.pop(0)
        if opt in ("-h", "--help"):
            return Help(), socket
        if opt == "--version":
            return Version(), socket
        if not args:
            raise UsageError(f"{opt} needs a socket name")
        socket = args.pop(0)

    if not args:
        return (view_for(config.default_view, config)
                or View("custom", config.default_view)), socket
    if help := help_asked(args):
        return help, socket

    first, rest = args[0], args[1:]
    if first == "help":
        if rest == ["--man"]:
            return Help(man=True), socket
        if rest == ["--skill"]:
            return Help(skill=True), socket
        if len(rest) > 1:
            raise UsageError("help takes one topic")
        return Help(rest[0] if rest else None), socket
    if first == "open":
        # `orgwarrior open ID [N]`: an N of 12 would look like an ID.
        return parse_task_command([*rest[:1], "open", *rest[1:]]), socket
    if first in ("kill", "edit", "archive"):
        # `orgwarrior kill ID...` (for an alias) is `orgwarrior ID... kill`.
        ids = [a for a in rest if ID_RE.fullmatch(a)]
        return parse_task_command([*ids, first, *(a for a in rest if a not in ids)]), socket
    if first == "clock":
        return parse_clock([], rest), socket
    if first == "clocked":
        return Report(" ".join(rest)), socket
    if first == "closed":
        return View("closed", " ".join(rest)), socket
    if first == "add":
        event = bool(rest) and rest[0] == "event"
        if event:
            rest = rest[1:]
        found = {}
        for flag, what in (("--to", "a place: a heading or file, as refile takes"),
                           ("--under", "a heading's ID")):
            if flag in rest:
                i = rest.index(flag)
                if i + 1 >= len(rest):
                    raise UsageError(f"{flag} needs {what}")
                found[flag] = rest[i + 1]
                rest = rest[:i] + rest[i + 2:]
        # A mistyped option would be part of the title.
        if bad := next((a for a in rest if re.fullmatch(r"--[a-z][a-z-]*", a)), None):
            raise UsageError(f"add has no option {bad}. Its options are --to PLACE and --under ID. "
                             f"To have {bad} in the title, quote the title")
        if len(found) > 1:
            raise UsageError("add takes --to or --under, not both")
        if not rest:
            raise UsageError(f"add {'event ' if event else ''}needs a title")
        return Add(" ".join(rest), event, found.get("--to"), found.get("--under")), socket
    # `week DATE`: the built-in week holding that day, even where [views]
    # redefines `week` (its stepping has to land on a plain week).
    if first == "week" and rest:
        return View("week", " ".join(rest)), socket
    # With arguments, a view name that's also a keyword (`orgwarrior next +@phone`) is the keyword.
    if (view := view_for(first, config)) and not (rest and view.kind == "custom"):
        if rest:
            raise UsageError(f"`orgwarrior {first}` takes nothing after it")
        return view, socket
    if ID_RE.fullmatch(first):
        return parse_task_command(args), socket
    if not rest and FILE_RE.fullmatch(first):
        return Outline(first), socket
    if first[0] in "+-" and not RELATIVE_DATE_RE.fullmatch(first):
        return View("tags", " ".join(args)), socket
    if first.startswith('"'):
        return View("search", " ".join(args).strip('"').strip()), socket
    # TODO keywords (`orgwarrior wait +@phone`), a date, else a text search: only Emacs knows the keywords.
    return View("words", " ".join(args)), socket


# Commands that come first, ahead of any ID (`add` is hex, so it would pass for one).
HELP_FIRST = ("help", "add", "open", "kill", "edit", "archive", "clock", "clocked", "closed")


def help_asked(args: list[str]) -> Help | None:
    """The help for a command line with --help (or -h) in it: its own topic,
    so `orgwarrior add --help` explains add instead of adding a task titled
    --help.  -h where a tag can go (-tag) is that tag; -m's note is a note."""
    words = [a for i, a in enumerate(args) if i == 0 or args[i - 1] not in ("-m", "--message")]
    first = args[0].lower()
    n = 0
    while n < len(args) and ID_RE.fullmatch(args[n]) and first not in HELP_FIRST:
        n += 1
    ids, rest = args[:n], [a for a in args[n:] if a != "--help"]
    tags = bool(rest) and (rest[0][0] in "+-" and len(rest[0]) > 1 or rest[0].lower() == "tag")
    if "--help" not in words and ("-h" not in words or tags):
        return None
    if first == "help":
        return Help()
    if first in HELP_FIRST:
        return Help(first)
    if not ids:
        return Help("views")
    if not rest:
        return Help("show")
    return Help("tags" if tags else rest[0].lower())


def view_request(view: View, config: configmod.Config, width: int | None) -> dict:
    return {"op": "view", "kind": view.kind, "arg": view.arg, "width": width,
            "prefix": config.prefix_format, "grid": config.time_grid, "tags": config.tags,
            "archive": view.archive}


def add_request(text: str | None, config: configmod.Config, fields: dict | None = None,
                event: bool = False) -> dict:
    if not event:
        return {"op": "add", "text": text, "fields": fields, "file": config.add_file,
                "heading": config.add_heading, "captured": config.add_captured}
    # [add.event] with a file of its own: its heading, else top level.  Without
    # one, events go where tasks do, under [add.event]'s heading if it has one.
    heading = (config.event_heading if config.event_file
               else config.event_heading or config.add_heading)
    return {"op": "add", "text": text, "fields": fields, "event": True,
            "file": config.event_file or config.add_file, "heading": heading,
            "captured": config.event_captured}


def act_request(act: Act, config: configmod.Config) -> dict:
    request = {"op": "act", "ids": act.ids, "verb": act.verb, "args": act.args, "note": act.note}
    if act.new is not None:
        request["new"] = {"title": act.new.strip() + config.refile_new_suffix,
                          "captured": config.add_captured}
        if not act.args and config.refile_new_in:
            request["args"] = [config.refile_new_in]
    return request


def parse_task_command(args: list[str]) -> Show | Act:
    ids = []
    while args and ID_RE.fullmatch(args[0]):
        ids.append(args.pop(0))
    if not args:
        return Show(ids)
    # Never tags: a tag can't start with "-", so "--drawers" can't be "-" one.
    if args == ["--drawers"] and ids:
        return Show(ids, drawers=True)
    # `orgwarrior k3 +x -y`: a filter can't follow an ID, so +/- here means tags.
    # All of it, so `-m...` is a tag too, never a note.
    if args[0][0] in "+-" and len(args[0]) > 1:
        return Act(ids, "tag", args)

    verb, rest = args[0].lower(), args[1:]
    if verb == "clock":
        return parse_clock(ids, rest)
    if not ids:
        raise UsageError(f"{verb} needs a task ID")
    if verb == "clocks":
        return parse_clocks(ids, rest)
    note, verb_args, yes, new = None, [], False, None
    if verb == "rename":  # all of it is the title, -m too
        if len(ids) > 1 or not rest:
            raise UsageError("rename takes one task's ID, then the new title")
        return Act(ids, verb, rest)
    while rest:
        arg = rest.pop(0)
        if verb == "kill" and arg in ("-y", "--yes"):
            yes = True
        elif verb == "refile" and arg in ("-n", "--new"):
            if not rest:
                raise UsageError(f"{arg} needs the new heading's title")
            new = rest.pop(0)
        elif arg in ("-m", "--message"):
            if not rest:
                raise UsageError(f"{arg} needs the note text")
            note = rest.pop(0)
        elif arg.startswith("-m") and len(arg) > 2 and verb != "tag":
            note = arg[2:]
        else:
            verb_args.append(arg)
    if verb == "edit" and (len(ids) > 1 or verb_args or note):
        raise UsageError("edit takes one task's ID and nothing else")
    if verb == "open" and (len(ids) > 1 or note or len(verb_args) > 1
                           or (verb_args and not verb_args[0].isdigit())):
        raise UsageError("open takes one task's ID, and a link's number if you want a particular one")
    return Act(ids, verb, verb_args, note, yes, new)


def parse_clock(ids: list[str], args: list[str]) -> Clock:
    """`clock [--short]`, `ID clock in [TIME]`, `[ID] clock out [TIME]`,
    `[ID] clock cancel`."""
    if not args or args == ["--short"]:
        if ids:
            raise UsageError("After an ID, clock takes in, out or cancel")
        return Clock("status", short=bool(args))
    action, time = args[0].lower(), " ".join(args[1:]) or None
    if action not in ("in", "out", "cancel"):
        raise UsageError(f"clock takes in, out or cancel, not {args[0]!r}")
    if len(ids) > 1:
        raise UsageError("clock takes one task's ID")
    if action == "in" and not ids:
        raise UsageError("clock in needs the task: orgwarrior ID clock in")
    if action == "cancel" and time:
        raise UsageError("clock cancel doesn't take a time")
    return Clock(action, ids, time)


DURATION_RE = re.compile(r"\d+h(\d+m)?|\d+m", re.I)


def parse_clocks(ids: list[str], args: list[str]) -> Clocks | ClockAdd:
    """`ID clocks`, `ID clocks N START-END` (or START-, -END, a date first
    for both), `ID clocks N rm`, `ID clocks add START-END` (or START
    DURATION, a date first)."""
    if len(ids) > 1:
        raise UsageError("clocks takes one task's ID")
    if not args:
        return Clocks(ids[0])
    if args[0].lower() == "add":
        rest = args[1:]
        if len(rest) > 1 and DURATION_RE.fullmatch(rest[-1]):
            return ClockAdd(ids[0], " ".join(rest[:-1]), duration=rest[-1])
        if rest and "-" in rest[-1].strip("-"):
            start, _, end = rest[-1].partition("-")
            return ClockAdd(ids[0], " ".join(rest[:-1] + [start]), end)
        raise UsageError("clocks add takes START-END or START DURATION, like 14:00-15:30 or 14:00 1h30m, with a date first for another day")
    if not args[0].isdigit():
        raise UsageError(f"clocks takes a clock's number, which orgwarrior {ids[0]} clocks lists, not {args[0]!r}")
    n, rest = int(args[0]), args[1:]
    if [a.lower() for a in rest] == ["rm"]:
        return Clocks(ids[0], n, remove=True)
    if not rest or "-" not in rest[-1] or rest[-1] == "-":
        raise UsageError("clocks N takes a new START-END, START- or -END (like 9:30-12:20), or rm to delete it")
    start, _, end = rest[-1].partition("-")
    date = " ".join(rest[:-1])
    on = lambda t: f"{date} {t}".strip() if t else None
    return Clocks(ids[0], n, on(start), on(end))


TAGS_AT_END_RE = re.compile(r"(.*?\S)( +)(:\S+:)")


def display_width(s: str) -> int:
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def truncate_indices(s: str, width: int) -> list[int | None]:
    """Indices of the characters of `s` kept to fit `width`; None is "…"."""
    if display_width(s) <= width:
        return list(range(len(s)))
    n = len(s)
    while n and display_width(s[:n]) > width - 1:
        n -= 1
    while n and s[n - 1].isspace():
        n -= 1
    return [*range(n), None]


def fit_indices(text: str, width: int) -> list[int | None]:
    """Make `text` fit in `width` columns so the terminal never wraps it.

    Org right-aligns tags but can't when the title is long; then shorten
    the title and keep the tags whole.  Anything else is cut at the edge.
    Returns indices into `text` (None for "…"), so colors survive the cut.
    """
    if display_width(text) <= width:
        return list(range(len(text)))
    if m := TAGS_AT_END_RE.fullmatch(text):
        head, _, tags = m.groups()
        room = width - display_width(tags) - 1
        if room >= width // 2:
            return [*truncate_indices(head, room), m.start(2), *range(m.start(3), m.end(3))]
    return truncate_indices(text, width)


def fit(text: str, width: int) -> str:
    return "".join("…" if i is None else text[i] for i in fit_indices(text, width))


class Painter:
    """ANSI colors from the config's role -> SGR map, or none at all."""

    def __init__(self, colors: dict[str, str] | None):
        self.colors = colors

    def style(self, role: str, keyword: str | None = None) -> str:
        if not self.colors:
            return ""
        if keyword and keyword in self.colors:
            return self.colors[keyword]
        return self.colors.get(role, "")

    def wrap(self, text: str, role: str) -> str:
        style = self.style(role)
        return f"\x1b[{style}m{text}\x1b[0m" if style and text else text

    def line(self, text: str, spans, indices=None, fallback=None) -> str:
        """`text` with each [start, end, role, keyword] span colored,
        keeping only the characters at `indices` (None for "…").
        `fallback`: role -> SGR for roles the config leaves uncolored."""
        if indices is None:
            indices = range(len(text))
        styles = [""] * len(text)
        for start, end, role, keyword in spans if self.colors else ():
            if style := self.style(role, keyword) or (fallback or {}).get(role, ""):
                styles[start:end] = [style] * (end - start)
        out, current = [], ""
        for i in indices:
            style = "" if i is None else styles[i]
            if style != current:
                out.append("\x1b[0m" if current else "")
                out.append(f"\x1b[{style}m" if style else "")
                current = style
            out.append("…" if i is None else text[i])
        if current:
            out.append("\x1b[0m")
        return "".join(out)


def use_color(config: configmod.Config) -> bool:
    if config.color != "auto":
        return config.color == "always"
    return (sys.stdout.isatty() and not os.environ.get("NO_COLOR")
            and os.environ.get("TERM") != "dumb")


def heading_spans(heading: str, keyword: str | None, done: bool) -> list:
    """Spans for a heading line from show/act/add: its keyword and tags."""
    spans = []
    if keyword and (m := re.match(r"\**\s*(" + re.escape(keyword) + r")(?!\S)", heading)):
        spans.append([m.start(1), m.end(1), "done" if done else "todo", keyword])
    if m := re.search(r"\s(:\S+:)\s*$", heading):
        spans.append([m.start(1), m.end(1), "tag", None])
    return spans


def print_view(lines: list[dict], columns: int | None = None,
               painter: Painter = Painter(None)) -> None:
    """Print agenda lines behind an ID column; with `columns`, fit each line to it.

    Lines org starts at the margin (headers, dates, separators) stay there;
    indented ones without an ID line up with the tasks.
    """
    id_width = max([len(l["id"]) for l in lines if l["id"]] + [2])
    for line in lines:
        text, task_id = line["text"].rstrip(), line["id"]
        indent = bool(task_id) or text[:1].isspace()
        room = columns - (id_width + 1 if indent else 0) if columns else None
        body = painter.line(text, line.get("spans", ()),
                            fit_indices(text, room) if room else None)
        if task_id:
            pad = " " * (id_width - len(task_id) + 1)
            print(painter.wrap(task_id, "id") + (pad + body if text else ""))
        elif indent:
            print(" " * (id_width + 1) + body)
        else:
            print(body)
        if habit := line.get("habit"):
            print_habit(habit, text, line.get("spans", ()), id_width + 1 if indent else 0, columns, painter)


def readable_on(color: str) -> str:
    """#000000 or #ffffff, whichever reads better on COLOR (#rrggbb): the
    higher WCAG contrast ratio."""
    lin = [(c / 255) / 12.92 if c <= 10 else (((c / 255) + 0.055) / 1.055) ** 2.4
           for c in (int(color[i:i + 2], 16) for i in (1, 3, 5))]
    lum = 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    return "#000000" if (lum + 0.05) / 0.05 >= 1.05 / (lum + 0.05) else "#ffffff"


def print_habit(habit: dict, text: str, spans, margin: int, columns: int | None,
                painter: Painter) -> None:
    """A habit's consistency graph on a line of its own, under the heading
    (its keyword, else the text): org's days and glyphs, each day colored as
    the config says, else as Emacs draws it, its glyph (* done, ! today) black
    or white, whichever reads on it.  The oldest days go first when it
    doesn't fit."""
    start = next((s for s, _, role, _ in spans if role in ("todo", "done")),
                 len(text) - len(text.lstrip()))
    indent = margin + display_width(text[:start])
    graph = habit["text"]
    keep = len(graph) if columns is None else max(columns - indent, 0)
    fallback = {role: configmod.sgr(f"{readable_on(color)} on-{color}") for role, color in habit["colors"].items()}
    print(" " * indent + painter.line(graph, habit["spans"],
                                      range(max(len(graph) - keep, 0), len(graph)), fallback))


def confirm_kill(ids: list[str], socket: str | None, painter: Painter) -> bool:
    """Show what `kill` would delete and ask.  Asked here, not in Emacs: a
    prompt there would hang emacsclient."""
    if not sys.stdin.isatty():
        raise UsageError("kill asks before deleting. When it isn't run in a terminal, add --yes")
    tasks = [emacs.call({"op": "show", "id": task_id}, socket) for task_id in ids]
    for task in tasks:
        heading = task["lines"][0]
        n = len(task["children"])
        extra = f"  (+{n} child heading{'s' if n != 1 else ''})" if n else ""
        print(f"{painter.wrap(task['id'], 'id')}  {painter.line(heading['text'], heading['spans'])}"
              + painter.wrap(extra, "deadline"))
    n = len(tasks)
    try:
        answer = input(f"Delete {'this entry' if n == 1 else f'these {n} entries'}? [y/N] ")
    except (EOFError, KeyboardInterrupt):
        print()
        return False
    return answer.strip().lower() in ("y", "yes")


# Verbs that aren't TODO keywords, so never want a state-change note.
NOT_KEYWORDS = ("sched", "due", "when", "tag", "refile", "kill", "edit", "archive", "rename", "open",
                "note", "pri", "up", "down", "promote", "demote", "nokeyword", "prop", "effort")
OPENABLE = ("http", "https", "mailto")


def ask_note(ids: list[str], verb: str, socket: str | None) -> str | None:
    """Ask for the note org would prompt for in Emacs (blank: none).  Asked
    here, not in Emacs: a prompt there would hang emacsclient."""
    if not emacs.call({"op": "wants-note", "ids": ids, "verb": verb}, socket):
        return None
    try:
        return input("Note (blank for none): ").strip() or None
    except EOFError:
        print()
        return None


def print_heading(result: dict, painter: Painter, suffix: str = "") -> None:
    """One line for a task that was just changed or added."""
    heading = result["heading"]
    body = painter.line(heading, heading_spans(heading, result.get("keyword"),
                                               result.get("done", False)))
    task_id = painter.wrap(result["id"], "id") if result["id"] else None
    if "old" in result:  # refiled or renamed: the ID changed with the file or title
        target = f"  {painter.wrap('→ ' + result['target'], 'extra')}" if "target" in result else ""
        print(f"{painter.wrap(result['old'], 'id')} → {task_id or '?'}  {body}{target}")
    elif "already" in result:
        print(f"{task_id}  {body}  {painter.wrap('already in ' + result['already'], 'extra')}")
    elif task_id:
        print(f"{task_id}  {body}" + (f"  {suffix}" if suffix else ""))
    else:
        print(f"{body}  (not in org-agenda-files, so no ID)")


def browser_reachable() -> bool:
    """Whether a browser here would be seen: not over SSH, and on Linux a
    graphical session with xdg-open."""
    if os.environ.get("SSH_CONNECTION") or os.environ.get("SSH_TTY"):
        return False
    if sys.platform == "darwin":
        return True
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")) \
        and shutil.which("xdg-open") is not None


def open_url(url: str) -> None:
    """In the default browser (or mail client, for mailto:), detached."""
    subprocess.Popen(["open" if sys.platform == "darwin" else "xdg-open", url],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


def link_line(n: int, link: dict, task_id: str, painter: Painter) -> str:
    text = f"{link['text']}  " if link["text"] else ""
    note = "" if link["type"] in OPENABLE else "  " + painter.wrap(f"(orgwarrior {task_id} edit opens it in Emacs)", "extra")
    return f"{painter.wrap(f'[{n}]', 'id')} {text}{painter.wrap(link['url'], 'link')}{note}"


def open_links(task_id: str, args: list[str], socket: str | None, painter: Painter) -> None:
    """Open link ARGS[0] of the task, its only link, or the one picked from
    a list.  Where no browser would be seen, print instead: over SSH, a
    terminal makes the URLs clickable."""
    links = emacs.call({"op": "show", "id": task_id}, socket)["links"]
    if not links:
        print("No links.")
        return

    def pick(answer: str) -> int:
        if not answer.isdigit() or not 1 <= int(answer) <= len(links):
            raise UsageError(f"there's no link {answer}. There {'is 1' if len(links) == 1 else f'are {len(links)}'}")
        return int(answer)

    def go(n: int) -> None:
        link = links[n - 1]
        if not can_open or link["type"] not in OPENABLE:
            print(link_line(n, link, task_id, painter))
        else:
            open_url(link["url"])
            print(f"Opening {painter.wrap(link['url'], 'link')}")

    can_open = browser_reachable()
    if args:
        return go(pick(args[0]))
    if len(links) == 1:
        return go(1)
    for n, link in enumerate(links, 1):
        print(link_line(n, link, task_id, painter))
    if not can_open or not sys.stdin.isatty():
        return
    try:
        answer = input(f"Open which (1-{len(links)}, blank for none): ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return
    if answer:
        go(pick(answer))


DRAWER_RE = re.compile(r"\s*:([\w-]+):\s*")


def print_show(task: dict, painter: Painter = Painter(None), drawers: bool = False) -> None:
    """The task as org opens it: drawers folded to one line each, then its
    notes, newest first.  DRAWERS: unfolded, and the notes only there."""
    where = " › ".join([task["file"], *task["path"]])
    from_ = f"  {painter.wrap('from ' + task['from'], 'extra')}" if task.get("from") else ""
    read_only = f"  {painter.wrap('read only', 'extra')}" if task.get("read_only") else ""
    print(f"{painter.wrap(task['id'], 'id')}  {painter.wrap(where, 'header')}{from_}{read_only}")
    lines, i = task["lines"], 0
    while i < len(lines):
        line = lines[i]
        m = DRAWER_RE.fullmatch(line["text"])
        if not drawers and m and m[1] != "END":
            end = next((j for j in range(i + 1, len(lines))
                        if lines[j]["text"].strip() == ":END:"), None)
            if end is not None:
                n = end - i - 1
                print(painter.wrap(f"{line['text'].rstrip()} ({n} line{'s' if n != 1 else ''})", "extra"))
                i = end + 1
                continue
        print(painter.line(line["text"], line["spans"]))
        i += 1
    if task["notes"] and not drawers:
        print()
        print(painter.wrap("Notes", "header"))
        for note in task["notes"]:
            when = (note["time"] or "").strip("[]<>")
            state = note["state"] or ""
            if state and (style := painter.style("todo", state)):
                state = f"\x1b[{style}m{state}\x1b[0m"
            print("  " + "  ".join(x for x in (painter.wrap(when, "extra"), state) if x))
            for line in note["text"].split("\n"):
                print(f"    {line}" if line else "")
    if task["children"]:
        print()
        print(painter.wrap("Outline", "header"))
        print_children(task["children"], painter)


def print_children(children: list[dict], painter: Painter) -> None:
    for child in children:
        heading = child["heading"]
        body = painter.line(heading, heading_spans(heading, child["keyword"], child["done"]))
        print(f"  {painter.wrap(child['id'] or '--', 'id')}  {body}")


def duration(minutes: int) -> str:
    return f"{minutes // 60}:{minutes % 60:02d}"


def clock_time(stamp: str) -> datetime.datetime:
    return datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M")


def print_clock(c: dict, what: str, painter: Painter) -> None:
    """One line for a clock: its task, then WHAT happened (or how long it's run)."""
    heading = painter.line(c["heading"], heading_spans(c["heading"], c.get("keyword"), c.get("done", False)))
    stale = "  " + painter.wrap("still on it?", "deadline") if c.get("stale") else ""
    print(f"{painter.wrap(c['id'], 'id')}  {heading}  {painter.wrap(what, 'extra')}{stale}")


def clock_short(clocks: list[dict]) -> str:
    """The newest clock as one line for a status bar (tmux), "" for none."""
    if not clocks:
        return ""
    c = clocks[-1]
    more = f" +{len(clocks) - 1}" if len(clocks) > 1 else ""
    stale = " · still on it?" if c["stale"] else ""
    return f"⏱ {fit(c['title'], 30)} {duration(c['minutes'])}{stale}{more}"


def print_clocks(r: dict, painter: Painter) -> None:
    """A task's clocks, newest first, numbered as `clocks N` takes them."""
    heading = painter.line(r["heading"], heading_spans(r["heading"], r.get("keyword"), r.get("done", False)))
    print(f"{painter.wrap(r['id'], 'id')}  {heading}")
    if not r["clocks"]:
        print("  No clocks.")
        return
    width = len(str(len(r["clocks"])))
    for c in r["clocks"]:
        start = clock_time(c["start"])
        if c["end"] is None:
            end, note = "", "  " + painter.wrap("running", "extra")
        else:
            e = clock_time(c["end"])
            end, note = e.strftime("%H:%M" if e.date() == start.date() else "%a %b %d %H:%M"), ""
        print(f"  {painter.wrap(str(c['n']).rjust(width), 'id')}  {start:%a %b %d}  "
              f"{start:%H:%M}–{end}  {duration(c['minutes'])}{note}")
    print(f"  {' ' * width}  {painter.wrap('Total ' + duration(r['minutes']), 'header')}")


def against(minutes: int, effort: int | None) -> tuple[str, bool]:
    """MINUTES as h:mm, against EFFORT where there is one; whether it's past it."""
    if effort is None:
        return duration(minutes), False
    return f"{duration(minutes)} / {duration(effort)}", minutes > effort


def print_report(r: dict, painter: Painter) -> None:
    """A clock report as a tree: each file, its headings by depth, the time
    each holds, an ID column; clocked against effort where it has one."""
    title = f"Clocked · {r['label']}" + (f" · {r['match']}" if r["match"] else "")
    lines = []  # (id, text, time, past effort, a file's line)
    for f in r["files"]:
        lines.append(("", f["file"], duration(f["minutes"]), False, True))
        for row in f["rows"]:
            lines.append((row["id"] or "", "  " * row["depth"] + row["title"],
                          *against(row["minutes"], row["effort_minutes"]), False))
    id_width = max([len(i) for i, *_ in lines] + [2])
    total = duration(r["minutes"])
    time_width = max([len(t) for _, _, t, *_ in lines] + [len(total)])
    col = max([display_width(title)] + [id_width + 2 + display_width(t) for _, t, *_ in lines]) + 4
    print(painter.wrap(title, "header") + " " * (col - display_width(title)) + painter.wrap(total.rjust(time_width), "header"))
    for task_id, text, time, over, is_file in lines:
        left = " " * (id_width + 2) if not task_id else painter.wrap(task_id.ljust(id_width), "id") + "  "
        pad = " " * (col - id_width - 2 - display_width(text))
        time = time.rjust(time_width)
        print(left + (painter.wrap(text, "header") if is_file else text) + pad
              + (painter.wrap(time, "deadline") if over else time))
    if not lines:
        print("Nothing clocked.")


def page(text: str) -> None:
    """Print `text`, through a pager if it's taller than the terminal."""
    if sys.stdout.isatty() and text.count("\n") + 3 > shutil.get_terminal_size().lines:
        env = dict(os.environ)
        env.setdefault("LESS", "FRX")
        try:
            if subprocess.run(env.get("PAGER") or "less", shell=True, input=text + "\n",
                              text=True, env=env).returncode != 127:
                return
        except OSError:
            pass
    with spaced():
        print(text)


@contextlib.contextmanager
def spaced():
    """A blank line before and after, on a terminal, to set a report off from the prompt."""
    pad = sys.stdout.isatty()
    if pad:
        print()
    yield
    if pad:
        print()


def run(command, config: configmod.Config, socket: str | None) -> None:
    painter = Painter(config.colors if use_color(config) else None)
    match command:
        case Help(man=True):
            from orgwarrior import manpage
            print(manpage.render(), end="")
        case Help(skill=True):
            from orgwarrior import skill
            print(skill.TEXT, end="")
        case Help(topic):
            # Keywords come from Emacs; help still works without a daemon.
            try:
                kw = emacs.call({"op": "keywords"}, socket, timeout=3)
            except emacs.EmacsError:
                kw = {"keywords": [], "done": []}
            if topic is None:
                page(helpmod.main(painter))
            elif text := helpmod.topic(topic, [k.lower() for k in kw["keywords"]]):
                page(helpmod.paint_topic(text, painter))
            else:
                raise UsageError(f"there's no help on {topic!r}. The topics are: {' '.join(helpmod.TOPICS)}")
        case Version():
            print(f"orgwarrior {__version__}")
        case View() as view:
            # With tags = "right", org aligns them to `width`; leave room for a 2-char ID column.
            # Fitting only on a terminal: piped output keeps whole lines.
            columns = shutil.get_terminal_size().columns
            width = max(columns - 3, 20)
            lines = emacs.call(view_request(view, config, width), socket)
            with spaced():
                print_view(lines, columns if sys.stdout.isatty() else None, painter)
            # An empty view on a first run: say why, rather than show nothing.
            if not any(l.get("id") for l in lines) and not emacs.call({"op": "files"}, socket):
                print("orgwarrior: Emacs has no agenda files it can find (org-agenda-files), so every "
                      "view is empty. `orgwarrior --check` says what to fix.", file=sys.stderr)
        case Outline(file):
            outline = emacs.call({"op": "outline", "file": file}, socket)
            with spaced():
                print(painter.wrap(outline["file"], "header"))
                print_children(outline["children"], painter)
                if not outline["children"]:
                    print("  No headings.")
        case Show(ids, drawers):
            tasks = [emacs.call({"op": "show", "id": task_id}, socket) for task_id in ids]
            with spaced():
                for i, task in enumerate(tasks):
                    if i:
                        print()
                    print_show(task, painter, drawers)
        case Clock("status", short=True):
            if clocks := emacs.call({"op": "clock"}, socket):
                print(clock_short(clocks))
        case Clock("status"):
            clocks = emacs.call({"op": "clock"}, socket)
            if not clocks:
                print("No clock running.")
            for c in clocks:
                print_clock(c, f"⏱ {duration(c['minutes'])} since {c['start'][11:]}", painter)
        case Clock("in", ids, time):
            r = emacs.call({"op": "clock-in", "id": ids[0], "time": time}, socket)
            for c in r["closed"]:
                print_clock(c, f"clocked out at {c['end'][11:]} · {duration(c['minutes'])}", painter)
            print_clock(r["clock"], f"clocked in at {r['clock']['start'][11:]}", painter)
        case Clock("out", ids, time):
            c = emacs.call({"op": "clock-out", "id": ids[0] if ids else None, "time": time}, socket)
            print_clock(c, f"clocked out at {c['end'][11:]} · {duration(c['minutes'])}"
                        + (" (zero, so org removed the line)" if c["removed"] else ""), painter)
        case Clock("cancel", ids):
            c = emacs.call({"op": "clock-cancel", "id": ids[0] if ids else None}, socket)
            print_clock(c, f"clock canceled (started {c['start'][11:]})", painter)
        case Report(words, archive):
            with spaced():
                print_report(emacs.call({"op": "report", "words": words, "archive": archive}, socket), painter)
        case ClockAdd(task_id, start, end, spent):
            print_clocks(emacs.call({"op": "clock-add", "id": task_id, "start": start, "end": end,
                                     "duration": spent}, socket), painter)
        case Clocks(task_id, None):
            print_clocks(emacs.call({"op": "clocks", "id": task_id}, socket), painter)
        case Clocks(task_id, n, start, end, remove):
            print_clocks(emacs.call({"op": "clock-edit", "id": task_id, "n": n, "start": start,
                                     "end": end, "remove": remove}, socket), painter)
        case Act(ids, "kill", yes=yes) as act:
            if not yes and not confirm_kill(ids, socket, painter):
                print("Nothing deleted.")
                return
            for r in emacs.call(act_request(act, config), socket):
                print_heading(r, painter, suffix=painter.wrap("(deleted)", "extra"))
        case Act(_, "archive") as act:
            for r in emacs.call(act_request(act, config), socket):
                print_heading(r, painter, suffix=painter.wrap("→ " + r["target"], "extra"))
        case Act(_, "promote" | "demote") as act:
            for r in emacs.call(act_request(act, config), socket):
                print_heading(r, painter, suffix=painter.wrap(
                    "→ under " + r["parent"] if r["parent"] else "→ top level", "extra"))
        case Act(ids, "open", args):
            open_links(ids[0], args, socket, painter)
        case Act(ids, "edit"):
            if not (sys.stdin.isatty() and sys.stdout.isatty()):
                raise UsageError("edit opens Emacs in this terminal, so it has to run in one")
            if emacs.edit(ids[0], socket):
                print("Not saved; changes discarded.")
        case Act(ids, "note", args, note) if not args and note is None:
            if not sys.stdin.isatty():
                raise UsageError("note needs the note's text")
            try:
                note = input("Note: ").strip()
            except (EOFError, KeyboardInterrupt):
                print("\nNothing changed.")
                return
            if not note:
                print("Nothing changed.")
                return
            for r in emacs.call(act_request(Act(ids, "note", [], note), config), socket):
                print_heading(r, painter)
        case Act(ids, verb, args, note) as act:
            if note is None and verb not in NOT_KEYWORDS and sys.stdin.isatty():
                try:
                    act.note = ask_note(ids, verb, socket)
                except KeyboardInterrupt:
                    print("\nNothing changed.")
                    return
            results = emacs.call(act_request(act, config), socket)
            for r in results:
                print_heading(r, painter)
        case Add(text, event, to, under):
            result = emacs.call({**add_request(text, config, event=event), "to": to, "under": under}, socket)
            print_heading(result, painter)
            # Headings in the body became its children.
            if n := result.get("new_children"):
                print(f"  + {n} heading{'s' if n > 1 else ''} under it: orgwarrior {result['id']} shows them")


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    # Before the config loads: a config that doesn't is one of the things it reports.
    if "--check" in argv:
        from orgwarrior import check
        rest = [a for a in argv if a != "--check"]
        if rest and not (len(rest) == 2 and rest[0] in ("-s", "--socket")):
            print("orgwarrior: --check takes only -s SOCKET", file=sys.stderr)
            return 2
        painter = Painter(configmod.Config().colors if sys.stdout.isatty() and not os.environ.get("NO_COLOR") else None)
        return check.report(rest[1] if rest else None, painter)
    try:
        config = configmod.load()
        command, socket = parse(argv, config)
        socket = socket or os.environ.get("ORGWARRIOR_SOCKET") or config.socket
        run(command, config, socket)
    except UsageError as e:
        print(f"orgwarrior: {e}\n(orgwarrior help lists the commands)", file=sys.stderr)
        return 2
    except OrgwarriorError as e:
        print(f"orgwarrior: {e}", file=sys.stderr)
        return 1
    return 0
