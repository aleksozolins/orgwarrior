"""orgwarrior.api against a real (throwaway) daemon: what orgwarrior-web builds on."""

import pytest

from orgwarrior.api import Orgwarrior, OrgwarriorError
from orgwarrior.config import Config


def test_views_and_tasks(daemon):
    socket, org = daemon
    ow = Orgwarrior(Config(views={"inbox": "i", "today": "x"}), socket)
    assert ow.views() == ["today", "week", "all", "inbox"]

    ow = Orgwarrior(Config(add_file=str(org / "inbox.org"), add_heading="Tasks"), socket)
    lines = ow.view()
    dentist = next(l for l in lines if "Call dentist" in l["text"])
    assert dentist["id"] and any(s[2] == "todo" for s in dentist["spans"])
    assert lines[0]["id"] is None  # the day header
    assert [l["text"].split()[-2:] for l in ow.view("wait") if l["id"]] == [["mom", ":parents:"]]

    task = ow.show(dentist["id"])
    assert task["file"] == "tasks.org" and task["id"] == dentist["id"]
    assert task["title"] == "Call dentist" and task["tags"] == ["@phone"] and task["keyword"] == "NEXT"
    batteries = next(l for l in ow.view("+inbox") if l["id"])  # inbox.org's #+filetags: inbox
    assert ow.show(batteries["id"])["inherited"] == ["inbox"]
    assert "DONE" in ow.keywords()["done"]
    assert ow.wants_note([dentist["id"]], "done") is True

    assert ow.tags()["groups"][0] == {"exclusive": True, "tags": ["@home", "@phone", "@computer"]}
    assert ow.refile_targets([dentist["id"]]) == ["tasks.org", "projects.org", "projects.org › Orgwarrior"]
    ow.config.refile_usual = "tasks"
    assert ow.usual_target(["tasks.org", "tasks.org › Tasks"]) == "tasks.org › Tasks"  # a heading wins
    assert ow.usual_target(["inbox.org › Tasks", "tasks.org", "tasks.org › Tasks"]) == "tasks.org › Tasks"
    ow.config.refile_usual = "warr"
    assert ow.usual_target(ow.refile_targets([dentist["id"]])) == "projects.org › Orgwarrior"
    ow.config.refile_usual = None

    added = ow.add(title="buy s:3 stamps", keyword="NEXT", tags=["@out"], scheduled="fri@10:00",
                   body="forever ones")
    assert added["heading"] == "NEXT buy s:3 stamps :@out:"
    assert ow.show(added["id"])["body"].endswith("\n\nforever ones")
    plain = ow.add(title="Garage", keyword="")
    assert plain["heading"] == "Garage" and plain["keyword"] is None
    places = ow.add_places()
    assert all(p["file"] in places["keywords"] for p in places["places"])
    assert places["keywords"]["tasks.org"][:2] == ["TODO", "NEXT"]
    ow.config.event_file = str(org / "calendar.org")
    event = ow.add_event(title="dinner @ 7", when="fri 19:00-21:00", tags=["@out"])
    assert event["heading"] == "dinner @ 7 :@out:" and event["keyword"] is None
    assert ow.show(event["id"])["body"].startswith("<")

    rent = next(l for l in lines if "Pay rent" in l["text"])["id"]
    box = ow.show(rent)["checkboxes"][0]
    assert box["state"] == "off" and box["text"] == "remember the memo line"
    assert "[1/1]" in ow.check(rent, 1, box["text"])["heading"]
    with pytest.raises(OrgwarriorError, match="changed"):
        ow.check(rent, 1, "not what's there")

    body = ow.show(rent)["body"]
    ow.set_entry(rent, body + "\n\nmailed early", body)
    assert ow.show(rent)["body"].endswith("\n\nmailed early")
    with pytest.raises(OrgwarriorError, match="changed"):
        ow.set_entry(rent, "x", body)

    done = ow.act([dentist["id"]], "done", note="booked")[0]
    assert done["heading"].startswith("DONE Call dentist") and done["done"] is True
    assert "booked" in (org / "tasks.org").read_text()


def test_errors(daemon):
    socket, _ = daemon
    ow = Orgwarrior(Config(), socket)
    # Not a view (an ID, a command): searched for.
    assert ow.view("add")[0]["text"] == "Search words: add"
    assert ow.view("c1 done")[0]["text"] == "Search words: c1 done"
    with pytest.raises(OrgwarriorError, match="No task ff00ff"):
        ow.show("ff00ff")
    ow.ping()
    with pytest.raises(OrgwarriorError, match="no Emacs daemon"):
        Orgwarrior(Config(), "orgwarrior-test-no-such-daemon").view()
    with pytest.raises(OrgwarriorError, match="no Emacs daemon"):
        Orgwarrior(Config(), "orgwarrior-test-no-such-daemon").ping()


def test_add_placed_where_asked():
    ow = Orgwarrior(Config(add_file="/i.org", add_heading="Tasks", add_captured=True,
                           event_file="/c.org"))
    sent = []
    ow._call = lambda req, **kw: sent.append(req) or {}
    ow.add_event(title="Dinner", when="fri", properties={"FROM": "robin"}, where="task")
    ow.add_event(title="Dinner", when="fri")
    ow.add(title="x", where="event")
    assert [(r["file"], r["heading"], r["captured"]) for r in sent] == [
        ("/i.org", "Tasks", True), ("/c.org", None, False), ("/c.org", None, False)]
    assert sent[0]["event"] and sent[0]["fields"]["properties"] == {"FROM": "robin"}
    assert "event" not in sent[2]  # still a task, only filed elsewhere
    with pytest.raises(ValueError):
        ow.add(title="x", where="inbox")


def test_add_captured_override():
    ow = Orgwarrior(Config(add_file="/i.org", add_captured=False))
    sent = []
    ow._call = lambda req, **kw: sent.append(req) or {}
    ow.add(title="x", captured=True)
    ow.add(title="x")
    assert [r["captured"] for r in sent] == [True, False]


def test_clock(daemon):
    socket, _ = daemon
    ow = Orgwarrior(Config(), socket)
    juggle = next(l["id"] for l in ow.view("all") if "juggle" in l["text"])
    assert ow.clock() == []
    started = ow.clock_in(juggle, "-1h")
    assert started["clock"]["id"] == juggle and started["clock"]["minutes"] == 60 and started["closed"] == []
    assert [c["title"] for c in ow.clock()] == ["Learn to juggle"]
    stopped = ow.clock_out(time="-20m")
    assert stopped["minutes"] == 40 and stopped["removed"] is False
    clock = ow.clocks(juggle)["clocks"][0]
    edited = ow.clock_edit(juggle, 1, end=clock["end"][11:], start=None, old=clock["text"])
    assert edited["minutes"] == 40
    with pytest.raises(OrgwarriorError, match="changed since"):
        ow.clock_remove(juggle, 1, old="CLOCK: nope")
    assert ow.clock_remove(juggle, 1, old=edited["clocks"][0]["text"])["clocks"] == []
    with pytest.raises(OrgwarriorError, match="No clock running"):
        ow.clock_cancel()


def test_big_request(daemon):
    """Details past a command line's 128 KiB, sent through a file, arrive whole."""
    socket, org = daemon
    ow = Orgwarrior(Config(), socket)
    task = next(l for l in ow.view("all") if l["id"] and "Pay rent" in l["text"])
    old = ow.show(task["id"])["body"]
    text = "\n".join(f"line {i}: quote \" backslash \\ é → 🦀" for i in range(6000))
    ow.set_entry(task["id"], text, old)
    assert text in ow.show(task["id"])["body"]
