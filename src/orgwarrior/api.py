"""orgwarrior's engine for other programs: the command line's views and
actions, as plain data.

    from orgwarrior.api import Orgwarrior
    ow = Orgwarrior()                 # the user's config.toml and daemon
    ow.view("wait +@phone")           # the same words `orgwarrior` takes

A view is a list of lines, each {"text", "id", "spans"}: `id` is null on
headers and separators; a date header also has "date" ("2026-10-12"); `spans` are [start, end, role, keyword] for
coloring, with roles as in config.ROLES.  A habit's line also has "habit":
org-habit's consistency graph, {"text", "spans", "colors"}, a day per
character ("*" done, "!" today), its roles the days' states, "colors" each
role's background as Emacs draws it (#rrggbb), for when the config sets none.  Every failure is an
OrgwarriorError whose message is fit to show the user.
"""

import os

from orgwarrior import OrgwarriorError, cli, config as configmod, emacs

__all__ = ["Orgwarrior", "OrgwarriorError"]


class Orgwarrior:
    def __init__(self, config: configmod.Config | None = None, socket: str | None = None):
        self.config = config or configmod.load()
        self.socket = socket or os.environ.get("ORGWARRIOR_SOCKET") or self.config.socket

    def _call(self, request: dict, **kw):
        return emacs.call(request, self.socket, **kw)

    def views(self) -> list[str]:
        """View names to offer: the built-ins, then the config's [views]."""
        return [*cli.BUILTIN_VIEWS, *(v for v in self.config.views if v not in cli.BUILTIN_VIEWS)]

    def view(self, query: str = "", width: int | None = None, archive: bool = False) -> list[dict]:
        """The view `orgwarrior QUERY` shows ("" is the default view).  What the
        CLI would take as a task ID or a command (`bed`, `add`) is a text
        search here: a front end's query box only shows views.  WIDTH is
        what org right-aligns tags to with tags = "right".  ARCHIVE (or
        --archive in QUERY) takes in the archive files too.  A line of a
        task in a read-only file (see show) has "read_only": true; an event
        on a day without a time (a plain timestamp, a diary sexp, a day of a
        range, no keyword) "all_day": true."""
        try:
            command, _ = cli.parse(query.split(), self.config)
        except cli.UsageError:
            command = None
        if not isinstance(command, cli.View):
            command = cli.View("search", query.replace("--archive", "").strip().strip('"'),
                               archive="--archive" in query.split())
        command.archive = command.archive or archive
        return self._call(cli.view_request(command, self.config, width))

    def show(self, task_id: str, html: bool = False) -> dict:
        """{"id", "file", "read_only", "category", "path", "parents", "prev", "next", "heading", "title",
        "tags", "inherited", "scheduled", "deadline", "when", "when_line",
        "keyword", "done", "body",
        "lines", "links", "checkboxes", "notes", "priority", "from", "keywords",
        "keyword_keys", "done_keywords", "children", "clocks", "history",
        "log_drawers"}: `orgwarrior ID`'s
        content.  read_only: its file isn't writable, and every change
        to it is refused.  category as the agenda labels it (the file's
        name, unless #+category: or a CATEGORY property says otherwise).  parents are the headings above it, {"id", "title"},
        outermost first; prev and next its siblings' titles, or null.  `tags` are the heading's own;
        `inherited` come from the file's #+filetags and parent headings;
        scheduled and deadline are org's timestamps ("<2026-10-16 Fri
        +1w>"), or null, closed the CLOSED one ("[2026-10-20 Tue 09:16]");
        when an event's date: the plain timestamp alone on the line after
        the planning line and drawers, where add_event writes it (the when
        verb sets it), or null, when_line that line's index into lines
        (html leaves it out); lines are {"text", "spans", "links"}, the text as
        Emacs shows it, its links {"start", "end", "url"} being what each
        covers of it; links are {"type", "url", "text"}; checkboxes are {"line", "text", "state"}, line an index into
        lines, state "on", "off" or "trans" (see check); children are
        the direct child headings, {"id", "heading", "text", "tags",
        "keyword", "done"}, text being the heading without keyword and
        tags; notes are the log items with text, newest first, {"time"
        ("[2026-10-15 Thu 14:02]"), "state" (a state change's new
        keyword, or null), "kind" (org's purpose: "note", "state",
        "done", ...), "text"}; priority is the cookie's value ("A"), or
        null; from is the FROM property (who added it, someone else), or
        null; keywords and done_keywords are its file's (a #+TODO line
        makes them differ from file to file); clocks its own, as clocks()
        has them; with HTML, "html": its text as org exports it (body only,
        drawers, planning and the when line left out, source blocks colored by face name:
        `org-keyword`...); untrusted where others wrote it, so sanitize it
        before a page shows it; history every log item, notes or not, newest first, {"n"
        (as note_edit takes it), "time", "state", "from" (a state change's
        old keyword), "kind", "heading" (its first line), "text", "raw"};
        log_drawers the log and clock drawers holding only those and
        CLOCK lines, which a page showing history and clocks can leave out;
        properties its own, {"name", "value"}, in its drawer's order;
        effort its Effort, effort_minutes that in minutes (null: none, or
        not a duration)."""
        return self._call({"op": "show", "id": task_id, "html": html} if html else {"op": "show", "id": task_id})

    def keywords(self, file: str | None = None) -> dict:
        """{"keywords": [...], "done": [...], "keys": [...], "priorities": [...],
        "warning_days"}: the TODO keywords, done ones too, their fast keys (C-c
        C-t's: `TODO(t)`, else org's choice; null for none), the priorities,
        highest first, and org-deadline-warning-days (a deadline without a -3d
        of its own shows that many days ahead).
        Org's own, or FILE's (its #+TODO line, if it has one); show's
        keyword_keys are its file's."""
        return self._call({"op": "keywords", "file": file} if file else {"op": "keywords"})

    def files(self) -> list[str]:
        """The agenda files, as IDs and the other calls name them
        ("projects.org": relative to org-directory)."""
        return self._call({"op": "files"})

    def ping(self, timeout: float = 3) -> None:
        """Raise OrgwarriorError unless the daemon answers within TIMEOUT
        seconds with orgwarrior.el loaded: a health check's question."""
        self._call({"op": "keywords"}, timeout=timeout)

    def tags(self) -> dict:
        """For a tag picker: {"groups": [{"exclusive", "tags"}], "other": [...],
        "keys": [[tag, key], ...]}, keys being C-c C-q's (#+TAGS: @home(h), the
        rest as org assigns them).
        Groups are as the agenda files' #+TAGS declare them (an exclusive one
        is a { } group: setting one of its tags removes the others); "other"
        are tags in use but not declared, filetags left out."""
        return self._call({"op": "tags"})

    def calendar(self, days: int = 365) -> list[dict]:
        """Every dated entry, for a calendar: {"id" (the whole hash, which
        any ID taking command takes), "title" (as the agenda shows it, no
        keyword, tags or timestamps), "keyword", "done", "habit", "tags",
        "inherited" (as show has them), "category", "read_only" (as show
        has it: likely a copy of another calendar), "stamps"}.  A stamp is {"kind":
        "scheduled", "deadline" or "timestamp", "start", "start_time",
        "end", "end_time", "repeat", "warning"}, dates "2026-10-14",
        times "14:00" or null, end being the range's end or the start
        again; repeat {"type": "+", "++" or ".+", "value", "unit": "h", "d",
        "w", "m" or "y"} and warning {"value", "unit"} as org parsed them,
        or null.  Diary sexps (`%%(...)` lines, kind "sexp", and `<%%(...)>`
        timestamps) are evaluated for each of the next DAYS days instead:
        {"kind", "dates": [{"date", "text"}]}, text being what the sexp
        returned ("Robin is 46"), or null.  Done tasks and habits are
        included: what to show is the caller's to decide."""
        return self._call({"op": "calendar", "days": days})

    def refile_targets(self, ids: list[str]) -> list[str]:
        """Where IDS can be refiled, as labels ("tasks.org › Tasks") that
        act(ids, "refile", [label]) takes as is."""
        return self._call({"op": "refile-targets", "ids": list(ids)})

    def refile_places(self, ids: list[str]) -> list[str]:
        """Where a new heading for IDS can go (act's NEW): the top level of
        each file in org-refile-targets ("projects.org"), then under each
        target, as labels act takes as is."""
        return self._call({"op": "refile-places", "ids": list(ids)})

    def outline(self, file: str) -> dict:
        """{"file", "children"}: FILE's (an agenda file as show names it,
        "projects.org") top-level headings, in file order, each as show's
        children are, with its own "children" the same way, all the way
        down (a foldable tree), "read_only": true on each in a read-only
        file."""
        return self._call({"op": "outline", "file": file})

    def reorder(self, ids: list[str], parent: str | None = None, file: str | None = None) -> list[dict]:
        """Put the children of PARENT (a task ID), or FILE's top-level
        headings, in the order of IDS, which must be all of them (else
        they changed since they were shown: refused).  Each moves with its
        subtree.  Returns the children as they now are."""
        return self._call({"op": "reorder", "ids": list(ids), "parent": parent, "file": file})

    def wants_note(self, ids: list[str], verb: str) -> bool:
        """Whether org would ask for a note when VERB (a keyword) is applied to IDS."""
        return self._call({"op": "wants-note", "ids": ids, "verb": verb})

    def check(self, task_id: str, n: int, text: str) -> dict:
        """Toggle checkbox N (from 1, as show lists them), as C-c C-c does:
        cookies follow.  TEXT is the item's text as shown, and must still
        match, so a list that changed underneath is refused.  For a front
        end that shows boxes in place; the CLI has no such verb."""
        return self._call({"op": "check", "id": task_id, "n": n, "text": text})

    def set_entry(self, task_id: str, text: str, old: str) -> dict:
        """Replace the task's text below its heading (show's "body":
        planning line, drawers, body; children stay) with TEXT, saved
        with one blank line after the planning line and drawers.  OLD is
        the body as shown, and must still match, so an entry that changed
        underneath is refused.  A line org would read as a heading is
        refused too."""
        return self._call({"op": "set-entry", "id": task_id, "text": text, "old": old})

    def act(self, ids: list[str], verb: str, args: list[str] = (), note: str | None = None,
            new: str | None = None) -> list[dict]:
        """Apply VERB (a keyword or nokeyword, sched, due, when (an event's
        date, its plain timestamp: see show), tag, pri, note, prop (ARGS: name, value; value "none" removes it), effort (a
        duration, one of Effort_ALL's where set, or "none"), rename, refile,
        up, down, promote, demote, archive, kill) to IDS.
        No confirmation here: kill deletes at once.  Results
        of refile and rename carry "old", the ID before.  NEW (refile only)
        is the title of a plain heading to make and refile into, as the
        last child of the place ARGS names (one of refile_places, default
        config's [refile] new_in)."""
        return self._call(cli.act_request(cli.Act(list(ids), verb, list(args), note, new=new),
                                          self.config))

    def add(self, text: str | None = None, *, title: str | None = None,
            keyword: str | None = None, priority: str | None = None,
            tags: list[str] = (), scheduled: str | None = None,
            deadline: str | None = None, body: str | None = None,
            properties: dict[str, str] | None = None, where: str | None = None,
            captured: bool | None = None, to: str | None = None,
            under: str | None = None, effort: str | None = None,
            closed: str | None = None) -> dict:
        """Add a task where config's [add] says: from `orgwarrior add` syntax
        (TEXT), or from fields (TITLE etc.), where nothing in the title is
        read as syntax.  KEYWORD "" adds a plain heading; PRIORITY is one
        of keywords()'s priorities; EFFORT a duration, as the effort verb takes
        it.  Dates are org-read-date strings; BODY goes below
        the drawer, as set_entry lays it out; PROPERTIES go in the drawer
        (beside :CAPTURED:).  WHERE ("task" or "event") files it where
        config says that kind goes; CAPTURED, if given, overrides config's
        :CAPTURED: stamp.  TO puts it elsewhere, a place from add_places
        (or any name refile takes); UNDER under a heading, by its ID."""
        if title is None:
            return self._call(self._placed(cli.add_request(text, self.config), where, captured, to, under))
        return self._call(self._placed(cli.add_request(None, self.config, {
            "title": title, "keyword": keyword, "priority": priority, "tags": list(tags),
            "scheduled": scheduled, "deadline": deadline, "body": body, "effort": effort,
            "closed": closed, "properties": properties or {}}), where, captured, to, under))

    def _placed(self, request: dict, where: str | None, captured: bool | None = None,
                to: str | None = None, under: str | None = None) -> dict:
        """REQUEST filed where config puts a task (WHERE "task") or an event
        ("event") instead of where its own kind goes; CAPTURED overriding
        whether it's stamped."""
        if where not in (None, "task", "event"):
            raise ValueError(f"where is task or event, not {where!r}")
        if where:
            place = cli.add_request(None, self.config, event=where == "event")
            request.update({k: place[k] for k in ("file", "heading", "captured")})
        if captured is not None:
            request["captured"] = captured
        return {**request, "to": to, "under": under}

    def usual_target(self, labels: list[str]) -> str | None:
        """Which of LABELS (refile targets) config's [refile] usual names:
        a heading of that name in a file of it (`tasks` is tasks.org › Tasks,
        not inbox.org › Tasks), then in any file (as refile matches), then a
        file of it, else a heading containing it.  None without one, or no
        match."""
        want = (self.config.refile_usual or "").strip().lower()
        if not want:
            return None
        last = lambda l: l.split(" › ")[-1].lower()
        for test in (lambda l: l.lower().startswith(f"{want}.org › ") and last(l) == want,
                     lambda l: " › " in l and last(l) == want,
                     lambda l: l.lower() in (want, f"{want}.org"),
                     lambda l: " › " in l and want in last(l)):
            if hit := next((l for l in labels if test(l)), None):
                return hit
        return None

    def add_places(self, event: bool = False) -> dict:
        """Where add (add_event, with EVENT) can put something:
        {"places": [{"label", "file"}], "keywords": {file: [open keywords]}}.
        A label is what TO takes: where config says first, then the
        refile targets as seen from that file, each file's top level
        included.  The keywords are those files' and the agenda files'
        (a #+TODO line makes a file's its own)."""
        place = cli.add_request(None, self.config, event=event)
        r = self._call({"op": "add-places", "file": place["file"], "heading": place["heading"]})
        return {"places": r["places"], "keywords": {k["file"]: k["open"] for k in r["keywords"]}}

    def add_event(self, text: str | None = None, *, title: str | None = None,
                  tags: list[str] = (), when: str | None = None, body: str | None = None,
                  properties: dict[str, str] | None = None, where: str | None = None,
                  captured: bool | None = None, to: str | None = None,
                  under: str | None = None) -> dict:
        """Add an event (no keyword, a plain timestamp) where config's
        [add.event] says: from `orgwarrior add event` syntax (TEXT, the date
        as @DATE), or from fields.  WHEN is a date as sched takes it,
        ranges and repeaters too.  PROPERTIES and WHERE as for add: WHERE
        "task" files it with the tasks (an inbox to triage); TO and UNDER
        as for add."""
        if title is None:
            return self._call(self._placed(cli.add_request(text, self.config, event=True), where,
                                           captured, to, under))
        return self._call(self._placed(cli.add_request(None, self.config, {
            "title": title, "tags": list(tags), "when": when, "body": body,
            "properties": properties or {}}, event=True), where, captured, to, under))

    def clock(self) -> list[dict]:
        """The clocks running: the open CLOCK lines in the agenda files, not
        Emacs's memory, oldest first.  Usually one; two when two machines
        clocked in.  Each {"id", "heading", "title", "file", "start"
        ("2026-10-20 14:05"), "end" (null), "minutes", "stale" (running past
        4 hours: likely forgotten)}."""
        return self._call({"op": "clock"})

    def clock_in(self, task_id: str, time: str | None = None) -> dict:
        """Clock in on the task, as org-clock-in does, at TIME (None: now):
        "17:30", "5pm", "-15m", "yesterday 17:30", never later than now.
        Whatever clock is running is closed at the same time.  {"clock": as
        clock() gives it, "closed": those closed, as clock_out gives them}."""
        return self._call({"op": "clock-in", "id": task_id, "time": time})

    def clock_out(self, task_id: str | None = None, time: str | None = None) -> dict:
        """Clock out at TIME (as clock_in takes it, later than now too:
        "+10m"; None: now): the task's
        clock, else the one running (several: refused, they're listed).  As
        clock() gives it, with "end" and "minutes", and "removed" when org
        removed a zero-time line (org-clock-out-remove-zero-time-clocks)."""
        return self._call({"op": "clock-out", "id": task_id, "time": time})

    def clock_cancel(self, task_id: str | None = None) -> dict:
        """Remove the running clock's line, as org-clock-cancel does: the
        task's, else the one running."""
        return self._call({"op": "clock-cancel", "id": task_id})

    def clocks(self, task_id: str) -> dict:
        """The task's own clocks, newest first: {"id", "heading", "minutes"
        (all of them), "clocks": [{"n" (from 1), "start", "end" (null while
        running), "minutes", "text" (the line, for clock_edit's OLD)}]}."""
        return self._call({"op": "clocks", "id": task_id})

    def clock_edit(self, task_id: str, n: int, start: str | None = None,
                   end: str | None = None, old: str | None = None) -> dict:
        """Change clock N's START and/or END (as clock_in and clock_out take
        them, so an end may be later than now; a
        time of day is on the clock's own date, an end before the start
        the next day's).  OLD, the clock's text as shown, must still match.
        Org recomputes its total.  The task's clocks, as clocks() gives them."""
        return self._call({"op": "clock-edit", "id": task_id, "n": n, "start": start,
                           "end": end, "old": old})

    def clock_add(self, task_id: str, start: str, end: str | None = None,
                  duration: str | None = None) -> dict:
        """Log time already spent: a finished clock from START (as clock_in
        takes it) to END (a time of day on START's date) or for DURATION
        ("1h30m", "45m", "1:30"), not later than now.  A running clock is
        left alone.  The task's clocks after, as clocks() gives them."""
        return self._call({"op": "clock-add", "id": task_id, "start": start, "end": end,
                           "duration": duration})

    def clock_remove(self, task_id: str, n: int, old: str | None = None) -> dict:
        """Remove clock N (a running one too: as clock_cancel).  OLD as for
        clock_edit.  The task's clocks after."""
        return self._call({"op": "clock-edit", "id": task_id, "n": n, "old": old, "remove": True})

    def note_edit(self, task_id: str, n: int, text: str, old: str | None = None) -> list[dict]:
        """Set log item N's text (as show's history numbers them; "" leaves
        just its first line, which a plain note can't do).  OLD, its "raw" as
        shown, must still match.  The task's history after."""
        return self._call({"op": "note-edit", "id": task_id, "n": n, "text": text, "old": old})

    def note_remove(self, task_id: str, n: int, old: str | None = None) -> list[dict]:
        """Remove log item N, as note_edit numbers and guards it; an emptied
        log drawer goes too.  The task's history after."""
        return self._call({"op": "note-edit", "id": task_id, "n": n, "old": old, "remove": True})

    def report(self, words: str = "", archive: bool = False) -> dict:
        """Time clocked, as org's clocktable counts it, over the agenda files:
        `orgwarrior clocked WORDS` (a span: today, yesterday, week, lastweek,
        month, lastmonth, year, 2026-10-20, 2026-W43, 2026-10, 2026, or
        2026-10-01..2026-10-15; default today; then a tag match).  {"label",
        "kind" (day, week, month, year, range), "start", "end" (its last day),
        "prev", "next" (the spans either side, null for a range), "match",
        "minutes", "files": [{"file", "minutes", "rows": [{"depth", "id",
        "title", "minutes", "effort_minutes"}]}]}: every heading holding
        time, by depth, in file order.  ARCHIVE counts the archive files too."""
        return self._call({"op": "report", "words": words, "archive": archive})

    def props(self, task_id: str | None = None, name: str | None = None) -> dict:
        """For a property editor: {"names": the property names in use in the
        agenda files, "values": NAME's allowed values for the task (its
        NAME_ALL, a #+PROPERTY line or a parent's), or null}."""
        return self._call({"op": "props", "id": task_id, "name": name})

    def entries_with(self, prop: str, value: str) -> list[dict]:
        """The entries whose own PROP is VALUE (FROM = robin: what someone
        added), archived and commented ones left out: {"title", "keyword",
        "done", "scheduled", "deadline", "timestamp" (the first plain one,
        an event's), "closed", "captured"}, the dates as org writes them,
        or null."""
        return self._call({"op": "entries", "property": prop, "value": value})
