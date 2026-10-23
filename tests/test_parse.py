import pytest

from orgwarrior import cli, help as h
from orgwarrior.cli import (Act, Add, Clock, ClockAdd, Clocks, Help, Outline, Report, Painter, Show, UsageError, View, act_request,
                            add_request, fit, fit_indices, heading_spans, parse, parse_task_command,
                            print_heading, print_show, print_view)
from orgwarrior.config import Config

CONFIG = Config(default_view="d", views={"inbox": "i", "today": "x"})


def p(*argv, config=Config()):
    return parse(list(argv), config)[0]


def test_default_view():
    assert p() == View("today")
    assert p(config=CONFIG) == View("custom", "d")
    assert p(config=Config(default_view="inbox", views={"inbox": "i"})) == View("custom", "i")


def test_views():
    assert p("week") == View("week")
    assert p("week", "2026-11-02") == View("week", "2026-11-02")
    # Its date even where [views] redefines week: a step lands on a plain week.
    assert p("week", "+1w", config=Config(views={"week": "w"})) == View("week", "+1w")
    assert p("all") == View("all")
    assert p("inbox", config=CONFIG) == View("custom", "i")
    assert p("today", config=CONFIG) == View("custom", "x")  # config overrides built-ins
    # A view name with arguments can only be a keyword query.
    assert p("inbox", "+@phone", config=CONFIG) == View("words", "inbox +@phone")


def test_add_to():
    assert p("add", "buy", "paint", "--to", "reno") == Add("buy paint", False, "reno")
    assert p("add", "event", "x", "@fri", "--to", "projects.org") == Add("x @fri", True, "projects.org")
    assert p("add", "x", "--under", "c1") == Add("x", under="c1")
    with pytest.raises(UsageError, match="no option --undr"):
        p("add", "x", "--undr", "c1")
    with pytest.raises(UsageError, match="not both"):
        p("add", "x", "--to", "a", "--under", "c1")
    assert p("add", "a", "--", "b") == Add("a -- b")  # a dash in a title is the title's
    with pytest.raises(UsageError):
        p("add", "x", "--to")


def test_file_outline():
    assert p("projects.org") == Outline("projects.org")
    assert p("work/notes.org") == Outline("work/notes.org")
    assert p('"projects.org"') == View("search", "projects.org")
    assert p("projects.org", "x") == View("words", "projects.org x")


def test_dates_keywords_and_tags():
    assert p("fri") == View("words", "fri")
    assert p("oct", "15") == View("words", "oct 15")
    assert p("+2d") == View("words", "+2d")
    assert p("-1d") == View("words", "-1d")
    assert p("2026-10-15") == View("words", "2026-10-15")
    assert p("wait", "next", "+@phone") == View("words", "wait next +@phone")
    assert p("+@phone") == View("tags", "+@phone")
    assert p('"flu shot"') == View("search", "flu shot")
    assert p('"flu', 'shot"') == View("search", "flu shot")  # the web box splits on spaces
    assert p("+parents-someday") == View("tags", "+parents-someday")
    assert p("-someday") == View("tags", "-someday")


def test_show_and_act():
    assert p("c1") == Show(["c1"])
    assert p("c1", "3f0") == Show(["c1", "3f0"])
    assert p("c1", "done") == Act(["c1"], "done")
    assert p("c1", "7f", "DONE", "-m", "booked it") == Act(["c1", "7f"], "done", [], "booked it")
    assert p("c1", "sched", "sat", "9am") == Act(["c1"], "sched", ["sat", "9am"])
    assert p("c1", "tag", "+x", "-mine") == Act(["c1"], "tag", ["+x", "-mine"])


def test_tag_shorthand():
    assert p("c1", "+x", "-mine") == Act(["c1"], "tag", ["+x", "-mine"])
    assert p("c1", "7f", "-m") == Act(["c1", "7f"], "tag", ["-m"])
    # Before an ID, +/- is still a query.
    assert p("+x", "-y") == View("tags", "+x -y")


def test_add():
    assert p("add", "NEXT", "call", "dentist", ":@phone:", "s:fri") == \
        Add("NEXT call dentist :@phone: s:fri")
    assert p("add", "event", "dentist", "@fri") == Add("dentist @fri", event=True)
    for argv in (("add",), ("add", "event")):
        with pytest.raises(UsageError):
            p(*argv)


def test_add_event_target():
    # Its own file: its heading or top level.  Else [add]'s file, and heading unless it has one.
    tasks = dict(add_file="/i.org", add_heading="Tasks", add_captured=True)
    r = add_request("x", Config(**tasks, event_file="/c.org"), event=True)
    assert (r["file"], r["heading"], r["captured"], r["event"]) == ("/c.org", None, False, True)
    r = add_request("x", Config(**tasks, event_heading="Events"), event=True)
    assert (r["file"], r["heading"]) == ("/i.org", "Events")
    assert add_request("x", Config(**tasks), event=True)["heading"] == "Tasks"


def test_options():
    assert parse(["-s", "dev", "week"], Config()) == (View("week"), "dev")
    assert p("--help") == Help()
    with pytest.raises(UsageError):
        p("today", "extra")
    with pytest.raises(UsageError):
        p("c1", "done", "-m")


def test_fit_keeps_tags_whole():
    line = "  tasks:      TODO Take out the trash and the recycling :@home:recurring:"
    out = fit(line, 50)
    assert len(out) == 50 and out.endswith("… :@home:recurring:")
    assert fit("short :x:", 50) == "short :x:"
    assert fit("=" * 79, 40) == "=" * 39 + "…"
    # Tags too long to keep: the whole line is cut instead.
    assert len(fit("TODO x :" + "a" * 60 + ":", 40)) == 40


def test_print_view_fits_to_columns(capsys):
    print_view([{"id": "c1", "text": "  tasks: TODO " + "word " * 20 + ":@phone:"},
                {"id": None, "text": "=" * 79}], columns=40)
    out = capsys.readouterr().out.splitlines()
    assert all(len(l) <= 40 for l in out)
    assert out[0].startswith("c1 ") and out[0].endswith(":@phone:")


def test_print_view_alignment(capsys):
    print_view([{"id": None, "text": "Day-agenda (W41):"},
                {"id": "c1f", "text": "  tasks: TODO x"},
                {"id": None, "text": "  diary: 9:00 sexp entry"},
                {"id": None, "text": ""}])
    assert capsys.readouterr().out.splitlines() == [
        "Day-agenda (W41):", "c1f   tasks: TODO x", "      diary: 9:00 sexp entry", ""]


def test_print_view_habit(capsys):
    habit = {"text": "**!  ", "spans": [[0, 2, "habit-ready", None], [2, 3, "habit-alert", None],
                                       [3, 5, "habit-overdue-future", None]],
             "colors": {"habit-ready": "#00ff00", "habit-alert": "#ffff00"}}
    line = {"id": "c1", "text": "  tasks: TODO water :@home:", "spans": [[9, 13, "todo", "TODO"]],
            "habit": habit}
    # Under the keyword; the oldest days go first when it doesn't fit.
    print_view([line])
    assert capsys.readouterr().out.splitlines()[1] == " " * 12 + "**!  "
    print_view([line], columns=15)
    assert capsys.readouterr().out.splitlines()[1] == " " * 12 + "!  "
    # Emacs's background unless the config colors the role, the glyph
    # black or white, whichever reads on it.
    print_view([line], painter=Painter({"habit-alert": "41"}))
    assert capsys.readouterr().out.splitlines()[1] == (
        " " * 12 + "\x1b[38;2;0;0;0;48;2;0;255;0m**\x1b[0m\x1b[41m!\x1b[0m  ")
    assert cli.readable_on("#0fed00") == "#000000" and cli.readable_on("#1f2f8f") == "#ffffff"


def test_painter():
    paint = Painter({"todo": "1;31", "NEXT": "33", "tag": "36", "WAIT": ""})
    assert Painter(None).line("TODO x", [[0, 4, "todo", "TODO"]]) == "TODO x"
    assert paint.line("TODO x", [[0, 4, "todo", "TODO"]]) == "\x1b[1;31mTODO\x1b[0m x"
    assert paint.line("NEXT x", [[0, 4, "todo", "NEXT"]]) == "\x1b[33mNEXT\x1b[0m x"
    assert paint.line("WAIT x", [[0, 4, "todo", "WAIT"]]) == "WAIT x"  # "none" wins over todo
    # Colors survive fitting; the tags are kept whole.
    text = "TODO a long title here :t:"
    out = paint.line(text, [[0, 4, "todo", None], [23, 26, "tag", None]], fit_indices(text, 16))
    assert out == "\x1b[1;31mTODO\x1b[0m a long… \x1b[36m:t:\x1b[0m"


def test_heading_spans():
    assert heading_spans("** NEXT Call :@phone:", "NEXT", False) == \
        [[3, 7, "todo", "NEXT"], [13, 21, "tag", None]]
    assert heading_spans("DONE x", "DONE", True) == [[0, 4, "done", "DONE"]]
    assert heading_spans("TODOS list", "TODO", False) == []


def test_print_show(capsys):
    kids = [{"id": "ec", "heading": "TODO Pick a license", "keyword": "TODO", "done": False},
            {"id": "41", "heading": "DONE Write it :x:", "keyword": "DONE", "done": True}]
    task = {"id": "32", "file": "tasks.org", "path": ["Tasks"], "children": kids,
            "lines": [{"text": "** TODO Pay rent", "spans": [[3, 7, "todo", "TODO"]]},
                      {"text": "DEADLINE: <2026-10-12 Mon>",
                       "spans": [[0, 9, "label", None], [10, 26, "timestamp", None]]},
                      *({"text": t, "spans": []} for t in
                        (":LOGBOOK:", '- State "DONE" from "TODO" [2026-10-14 Wed 09:00] \\\\',
                         "  paid", ":END:", "Transfer from checking."))],
            "notes": [{"time": "[2026-10-14 Wed 09:00]", "state": "DONE", "kind": "state",
                       "text": "paid\n\nlate"}]}
    print_show(task, Painter({"todo": "31", "timestamp": "32", "id": "34"}))
    assert capsys.readouterr().out.splitlines() == [
        "\x1b[34m32\x1b[0m  tasks.org › Tasks",
        "** \x1b[31mTODO\x1b[0m Pay rent",
        "DEADLINE: \x1b[32m<2026-10-12 Mon>\x1b[0m",
        ":LOGBOOK: (2 lines)",
        "Transfer from checking.",
        "",
        "Notes",
        "  2026-10-14 Wed 09:00  \x1b[31mDONE\x1b[0m",
        "    paid",
        "",
        "    late",
        "",
        "Outline",
        "  \x1b[34mec\x1b[0m  \x1b[31mTODO\x1b[0m Pick a license",
        "  \x1b[34m41\x1b[0m  DONE Write it :x:"]


def test_print_heading_refiled(capsys):
    print_heading({"old": "6a", "id": "91", "heading": "TODO x", "keyword": "TODO",
                   "done": False, "target": "tasks.org › Tasks"}, Painter(None))
    assert capsys.readouterr().out == "6a → 91  TODO x  → tasks.org › Tasks\n"


def test_print_heading_renamed(capsys):
    print_heading({"old": "6a", "id": "91", "heading": "TODO y", "keyword": "TODO",
                   "done": False}, Painter(None))
    assert capsys.readouterr().out == "6a → 91  TODO y\n"


def test_rename():
    # All of it is the title: -m and +x included.
    assert p("c1", "rename", "call", "-m", "+x") == Act(["c1"], "rename", ["call", "-m", "+x"])
    for argv in (("c1", "rename"), ("c1", "7f", "rename", "x")):
        with pytest.raises(UsageError):
            p(*argv)


def test_open_parse():
    assert p("c1", "open") == Act(["c1"], "open")
    assert p("c1", "open", "2") == Act(["c1"], "open", ["2"])
    assert p("open", "c1", "12") == Act(["c1"], "open", ["12"])  # 12, not a second ID
    for argv in (("open",), ("c1", "7f", "open"), ("c1", "open", "x"), ("c1", "open", "1", "2")):
        with pytest.raises(UsageError):
            p(*argv)


LINKS = [{"type": "https", "url": "https://a.example", "text": "A"},
         {"type": "file", "url": "file:n.org", "text": None}]


@pytest.fixture
def links(monkeypatch):
    """open_links against fake links and a fake browser; returns what was opened."""
    opened = []
    state = {"links": LINKS}
    monkeypatch.setattr(cli.emacs, "call", lambda req, socket: {"links": state["links"]})
    monkeypatch.setattr(cli, "open_url", opened.append)
    monkeypatch.setattr(cli, "browser_reachable", lambda: True)
    return cli, opened, state


def test_open_links(links, capsys, monkeypatch):
    cli, opened, state = links
    painter = cli.Painter(None)
    cli.open_links("c1", ["1"], None, painter)
    assert opened == ["https://a.example"]
    # Several, picked from the list; a file: link is listed, never opened.
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    monkeypatch.setattr("builtins.input", lambda prompt: "2")
    cli.open_links("c1", [], None, painter)
    assert opened == ["https://a.example"]
    assert "[2] file:n.org  (orgwarrior c1 edit opens it in Emacs)" in capsys.readouterr().out
    # The only link opens without asking.
    state["links"] = LINKS[:1]
    cli.open_links("c1", [], None, painter)
    assert opened == ["https://a.example"] * 2
    # No browser to be seen: printed, not opened.
    monkeypatch.setattr(cli, "browser_reachable", lambda: False)
    capsys.readouterr()
    cli.open_links("c1", [], None, painter)
    assert opened == ["https://a.example"] * 2
    assert capsys.readouterr().out == "[1] A  https://a.example\n"
    with pytest.raises(UsageError, match="no link 3; there is 1"):
        cli.open_links("c1", ["3"], None, painter)


def test_browser_reachable(monkeypatch):
    for var in ("SSH_CONNECTION", "SSH_TTY", "DISPLAY", "WAYLAND_DISPLAY"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setattr(cli.sys, "platform", "darwin")
    assert cli.browser_reachable()
    monkeypatch.setenv("SSH_TTY", "/dev/pts/1")
    assert not cli.browser_reachable()
    monkeypatch.delenv("SSH_TTY")
    monkeypatch.setattr(cli.sys, "platform", "linux")
    assert not cli.browser_reachable()  # no graphical session
    monkeypatch.setenv("WAYLAND_DISPLAY", "wayland-1")
    monkeypatch.setattr(cli.shutil, "which", lambda name: "/usr/bin/xdg-open")
    assert cli.browser_reachable()


def test_archive():
    assert p("c1", "7f", "archive") == Act(["c1", "7f"], "archive")
    assert p("archive", "c1", "7f") == Act(["c1", "7f"], "archive")


def test_kill():
    assert p("c1", "7f", "kill") == Act(["c1", "7f"], "kill")
    assert p("c1", "kill", "--yes") == Act(["c1"], "kill", yes=True)
    assert p("kill", "c1", "7f") == Act(["c1", "7f"], "kill")
    assert p("kill", "-y", "c1") == Act(["c1"], "kill", yes=True)
    # --yes means nothing to other verbs.
    assert p("c1", "done", "--yes") == Act(["c1"], "done", ["--yes"])
    with pytest.raises(UsageError):
        p("kill")


def test_refile_new():
    assert p("c1", "refile", "--new", "Kitchen reno", "projects") == \
        Act(["c1"], "refile", ["projects"], new="Kitchen reno")
    with pytest.raises(UsageError):
        p("c1", "refile", "--new")
    config = Config(add_captured=True, refile_new_in="projects.org", refile_new_suffix=" [/]")
    request = act_request(Act(["c1"], "refile", [], new=" Kitchen reno "), config)
    assert request["args"] == ["projects.org"]
    assert request["new"] == {"title": "Kitchen reno [/]", "captured": True}
    # A place given wins; no new, no "new" key.
    assert act_request(Act(["c1"], "refile", ["tasks"], new="X"), config)["args"] == ["tasks"]
    assert "new" not in act_request(Act(["c1"], "refile", ["tasks"]), config)


def test_edit():
    assert p("c1", "edit") == Act(["c1"], "edit")
    assert p("edit", "c1") == Act(["c1"], "edit")
    for argv in (("edit",), ("edit", "c1", "7f"), ("c1", "7f", "edit"), ("c1", "edit", "x"), ("c1", "edit", "-m", "n")):
        with pytest.raises(UsageError):
            p(*argv)


def test_help_parse():
    assert p("help") == Help()
    assert p("help", "refile") == Help("refile")
    # --help anywhere: that command's help, never the command (add --help added a task).
    assert p("add", "--help") == Help("add")
    assert p("add", "event", "x", "-h") == Help("add")
    assert p("c1", "sched", "--help") == Help("sched")
    assert p("c1", "7f", "done", "-h") == Help("done")
    assert p("c1", "--help") == Help("show")
    assert p("kill", "c1", "--help") == Help("kill")
    assert p("wait", "+@phone", "--help") == Help("views")
    assert p("help", "--help") == Help()
    assert p("c1", "+x", "--help") == Help("tags")
    # -h where a tag goes is the tag; a note is a note.
    assert p("c1", "+x", "-h") == Act(["c1"], "tag", ["+x", "-h"])
    assert p("c1", "done", "-m", "--help") == Act(["c1"], "done", [], "--help")
    with pytest.raises(UsageError):
        p("help", "a", "b")


def test_help_fits_80_columns():
    texts = [h.main(Painter(None)), *h.TOPICS.values()]
    for text in texts:
        for line in text.splitlines():
            assert len(line) <= h.WIDTH, line


def test_help_topics():
    # Every topic the main page names exists, and every topic is named there.
    named = h.MAIN.split("or --help after a command\n")[1].split("options:")[0].split()
    assert sorted(named) == sorted(h.TOPICS)
    assert h.topic("sched") == h.TOPICS["dates"]
    assert h.topic("Refile") == h.TOPICS["refile"]
    assert h.topic("wait", ["todo", "wait"]) == h.TOPICS["keywords"]
    assert h.topic("nope") is None


def test_help_colors():
    colors = Config().colors | {"NEXT": "1;36"}
    text = h.main(Painter(colors))
    assert f"\x1b[{colors['header']}mviews\x1b[0m" in text
    topic = h.paint_topic(h.TOPICS["kill"], Painter(colors))
    assert topic.startswith(f"\x1b[{colors['header']}morgwarrior ID... kill [--yes]\x1b[0m\n")


def test_print_show_from(capsys):
    task = {"id": "32", "file": "inbox.org", "path": ["Tasks"], "children": [], "notes": [],
            "from": "robin", "lines": [{"text": "** TODO x", "spans": []}]}
    print_show(task, Painter(None))
    assert capsys.readouterr().out.splitlines()[0] == "32  inbox.org › Tasks  from robin"


def test_print_show_drawers(capsys):
    task = {"id": "32", "file": "tasks.org", "path": [], "children": [],
            "lines": [{"text": t, "spans": []} for t in ("* TODO x", ":LOGBOOK:", "- Note", ":END:")],
            "notes": [{"time": "[2026-10-14 Wed 09:00]", "state": None, "kind": "note", "text": "y"}]}
    print_show(task, Painter(None), drawers=True)
    assert capsys.readouterr().out.splitlines()[1:] == ["* TODO x", ":LOGBOOK:", "- Note", ":END:"]


def test_parse_show_drawers_note_pri():
    assert parse_task_command(["32", "--drawers"]) == Show(["32"], drawers=True)
    assert parse_task_command(["32", "note", "called", "back"]) == Act(["32"], "note", ["called", "back"])
    assert parse_task_command(["32", "7a", "pri", "A"]) == Act(["32", "7a"], "pri", ["A"])



def test_prop_and_effort_parse():
    assert p("c1", "prop", "LOCATION", "the", "bank") == Act(["c1"], "prop", ["LOCATION", "the", "bank"])
    assert p("c1", "effort", "0:30") == Act(["c1"], "effort", ["0:30"])
    assert h.topic("effort") == h.TOPICS["properties"]


def test_when_parse():
    assert p("c1", "when", "fri", "14:00") == Act(["c1"], "when", ["fri", "14:00"])
    assert h.topic("when") == h.TOPICS["dates"]


def test_clock_parse():
    assert p("clock") == Clock("status")
    assert p("clock", "--short") == Clock("status", short=True)
    assert p("clock", "out") == Clock("out")
    assert p("clock", "out", "yesterday", "17:30") == Clock("out", [], "yesterday 17:30")
    assert p("clock", "cancel") == Clock("cancel")
    assert p("c1", "clock", "in") == Clock("in", ["c1"])
    assert p("c1", "clock", "IN", "-15m") == Clock("in", ["c1"], "-15m")
    assert p("c1", "clock", "out", "17:30") == Clock("out", ["c1"], "17:30")
    for bad in (["clock", "in"], ["c1", "clock"], ["c1", "7f", "clock", "in"], ["clock", "start"],
                ["clock", "cancel", "9:00"]):
        with pytest.raises(UsageError):
            p(*bad)
    assert p("clock", "--help") == Help("clock")
    assert p("c1", "clock", "in", "--help") == Help("clock")
    assert h.topic("clocks") == h.TOPICS["clock"]


def test_clocks_parse():
    assert p("c1", "clocks") == Clocks("c1")
    assert p("c1", "clocks", "2", "9:30-12:20") == Clocks("c1", 2, "9:30", "12:20")
    assert p("c1", "clocks", "1", "-17:45") == Clocks("c1", 1, None, "17:45")
    assert p("c1", "clocks", "1", "9:30-") == Clocks("c1", 1, "9:30", None)
    assert p("c1", "clocks", "2", "2026-10-19", "9:30-12:20") == \
        Clocks("c1", 2, "2026-10-19 9:30", "2026-10-19 12:20")
    assert p("c1", "clocks", "2", "rm") == Clocks("c1", 2, remove=True)
    assert p("c1", "clocks", "add", "yesterday", "14:00-15:30") == ClockAdd("c1", "yesterday 14:00", "15:30")
    assert p("c1", "clocks", "add", "9:00", "1h30m") == ClockAdd("c1", "9:00", duration="1h30m")
    assert p("c1", "clocks", "add", "2026-10-19", "9:00", "45m") == ClockAdd("c1", "2026-10-19 9:00", duration="45m")
    for bad in (["c1", "7f", "clocks"], ["c1", "clocks", "x"], ["c1", "clocks", "2"],
                ["c1", "clocks", "2", "9:30"], ["c1", "clocks", "2", "-"],
                ["c1", "clocks", "add"], ["c1", "clocks", "add", "9:00"], ["c1", "clocks", "add", "1h"]):
        with pytest.raises(UsageError):
            p(*bad)


CLOCK = {"id": "e4", "heading": "TODO Learn to juggle :someday:", "title": "Learn to juggle",
         "keyword": "TODO", "done": False, "start": "2026-10-20 14:05", "end": None,
         "minutes": 42, "stale": False}


def test_clock_short():
    assert cli.clock_short([]) == ""
    assert cli.clock_short([CLOCK]) == "⏱ Learn to juggle 0:42"
    long = CLOCK | {"title": "Call the dentist about the crown and the bill", "minutes": 370, "stale": True}
    assert cli.clock_short([CLOCK, long]) == "⏱ Call the dentist about the cr… 6:10 · still on it? +1"


def test_print_clock(capsys):
    cli.print_clock(CLOCK | {"stale": True}, "⏱ 0:42 since 14:05", Painter(None))
    assert capsys.readouterr().out == "e4  TODO Learn to juggle :someday:  ⏱ 0:42 since 14:05  still on it?\n"


def test_print_clocks(capsys):
    cli.print_clocks({"id": "e4", "heading": "TODO Learn to juggle", "keyword": "TODO", "minutes": 655, "clocks": [
        {"n": 1, "start": "2026-10-20 14:05", "end": None, "minutes": 12},
        {"n": 2, "start": "2026-10-06 14:05", "end": "2026-10-07 00:15", "minutes": 610},
        {"n": 3, "start": "2026-10-05 09:40", "end": "2026-10-05 10:13", "minutes": 33}]}, Painter(None))
    assert capsys.readouterr().out == (
        "e4  TODO Learn to juggle\n"
        "  1  Tue Oct 20  14:05–  0:12  running\n"
        "  2  Tue Oct 06  14:05–Wed Oct 07 00:15  10:10\n"
        "  3  Mon Oct 05  09:40–10:13  0:33\n"
        "     Total 10:55\n")
    cli.print_clocks({"id": "e4", "heading": "x", "minutes": 0, "clocks": []}, Painter(None))
    assert capsys.readouterr().out == "e4  x\n  No clocks.\n"


def test_report(capsys):
    assert p("clocked") == Report("")
    assert p("clocked", "week", "+@phone") == Report("week +@phone")
    assert p("clocked", "--help") == Help("clocked")
    assert p("clocked", "--archive", "week") == Report("week", archive=True)

    cli.print_report({"label": "week 2026-W43", "match": None, "minutes": 205, "files": [
        {"file": "tasks.org", "minutes": 205, "rows": [
            {"depth": 1, "id": "74", "title": "Tasks", "minutes": 205, "effort_minutes": None},
            {"depth": 2, "id": "e4", "title": "Learn to juggle", "minutes": 163, "effort_minutes": 120},
            {"depth": 2, "id": "c1", "title": "Call dentist", "minutes": 42, "effort_minutes": None}]}]}, Painter(None))
    assert capsys.readouterr().out == (
        "Clocked · week 2026-W43           3:25\n"
        "    tasks.org                     3:25\n"
        "74    Tasks                       3:25\n"
        "e4      Learn to juggle    2:43 / 2:00\n"
        "c1      Call dentist              0:42\n")
    cli.print_report({"label": "today", "match": None, "minutes": 0, "files": []}, Painter(None))
    assert capsys.readouterr().out.endswith("Nothing clocked.\n")


def test_help_examples_parse():
    """Every command the main help shows is one orgwarrior takes (a | b is two)."""
    import shlex
    for line in h.MAIN.splitlines():
        if not line.startswith("  orgwarrior"):
            continue
        command = line.split("   ")[0].strip()  # before the description's column
        variants = [command] if " | " not in command else \
            [command.split(" | ")[0]] + [command.split(" | ")[0].rsplit(" ", 1)[0] + " " + alt
                                         for alt in command.split(" | ")[1:]]
        for v in variants:
            p(*shlex.split(v)[1:])  # raises UsageError if it isn't


def test_man_page():
    """docs/orgwarrior.1 is manpage.render()'s, every topic in it, and groff
    reads it without a warning."""
    import shutil
    import subprocess
    from pathlib import Path
    from orgwarrior import manpage
    roff = manpage.render()
    committed = (Path(__file__).parents[1] / "docs/orgwarrior.1").read_text()
    assert committed == roff, "run: orgwarrior help --man > docs/orgwarrior.1"
    assert roff.isascii()
    for name in h.TOPICS:
        assert f"\n.SS {name}\n" in roff, name
    assert p("help", "--man") == Help(man=True)
    if shutil.which("groff"):
        r = subprocess.run(["groff", "-man", "-Tutf8", "-ww", "-z"], input=roff, capture_output=True, text=True)
        assert r.returncode == 0 and not r.stderr, r.stderr


def test_archive_and_closed():
    assert p("closed", "week") == View("closed", "week")
    assert p("closed", "--help") == Help("closed")
    assert p("--archive", "flu", "shot") == View("words", "flu shot", archive=True)
    assert p("+@phone", "--archive") == View("tags", "+@phone", archive=True)
    with pytest.raises(UsageError, match="no option --archive"):  # a typo'd option, never the title
        p("add", "read", "about", "--archive")
    assert p("add", "read about --archive") == Add("read about --archive")  # quoted: the title's
    with pytest.raises(UsageError, match="--archive"):
        p("abc1", "done", "--archive")


def test_skill_commands_parse(capsys):
    """Every orgwarrior command the skill shows is one orgwarrior takes, so
    it can't drift; help --skill prints it, front matter first."""
    import re
    import shlex
    from orgwarrior import skill
    commands = re.findall(r"`(orgwarrior [^`]+)`", skill.TEXT)
    assert len(commands) > 30
    for c in commands:
        p(*shlex.split(c.replace("ID", "ab12").replace("...", "").replace("TEXT", "x")
                       .replace("NEW TITLE", "x").replace("TARGET", "x").replace("PLACE", "x")
                       .replace("TOPIC", "dates").replace("NAME", "today"))[1:])
    assert p("help", "--skill") == Help(skill=True)
    cli.run(Help(skill=True), Config(), None)
    out = capsys.readouterr().out
    assert out.startswith("---\nname: orgwarrior\ndescription: ") and out == skill.TEXT
