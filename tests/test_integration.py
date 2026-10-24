"""The whole thing: CLI -> emacsclient -> a real (throwaway) daemon -> org files."""

import re

from conftest import fresh_minute
from orgwarrior.cli import main


def run(capsys, *argv):
    code = main(list(argv))
    out = capsys.readouterr()
    return code, out.out, out.err


def task_id(out, title):
    line = next(l for l in out.splitlines() if title in l)
    return line.split()[0]


def test_view_show_act_add(daemon, capsys):
    socket, org = daemon
    code, out, _ = run(capsys, "-s", socket)
    assert code == 0
    assert "Call dentist" in out and "juggle" not in out
    dentist = task_id(out, "Call dentist")
    assert re.fullmatch(r"[0-9a-f]{2,}", dentist)

    code, out, _ = run(capsys, "-s", socket, dentist)
    assert code == 0 and "tasks.org › Tasks" in out and "SCHEDULED:" in out

    code, out, _ = run(capsys, "-s", socket, dentist, "+urgent", "-@phone")
    assert code == 0 and out == f"{dentist}  NEXT Call dentist :urgent:\n"

    code, out, _ = run(capsys, "-s", socket, dentist, "done", "-m", "booked")
    assert code == 0 and out.startswith(f"{dentist}  DONE Call dentist")
    assert "booked" in (org / "tasks.org").read_text()

    code, out, _ = run(capsys, "-s", socket, "add", "NEXT", "buy", "stamps", ":@out:", "s:tomorrow")
    assert code == 0 and "NEXT buy stamps :@out:" in out
    assert "** NEXT buy stamps :@out:\nSCHEDULED: <" in (org / "inbox.org").read_text()

    code, out, _ = run(capsys, "-s", socket, "all")
    assert "buy stamps" in out and "DONE Call dentist" not in out

    # Headings in the body: its children, said so.
    code, out, _ = run(capsys, "-s", socket, "add", "Plan the trip\n* TODO Book flights\n** Window seat")
    assert code == 0 and "+ 2 headings under it" in out
    assert "** TODO Plan the trip" in (org / "inbox.org").read_text()
    assert "*** TODO Book flights\n**** Window seat" in (org / "inbox.org").read_text()


def test_errors(daemon, capsys):
    socket, _ = daemon
    assert run(capsys, "-s", socket, "ff00ff", "done")[2] == "orgwarrior: No task ff00ff\n"
    code, _, err = run(capsys, "-s", socket, '""')
    assert code == 1 and "needs some words" in err
    assert run(capsys, "-s", "orgwarrior-test-no-such-daemon")[2].startswith("orgwarrior: no Emacs daemon")


def test_kill(daemon, capsys):
    socket, org = daemon
    juggle = task_id(run(capsys, "-s", socket, "all")[1], "juggle")
    # pytest's stdin isn't a terminal: no confirmation possible, so no --yes, no kill.
    code, _, err = run(capsys, "-s", socket, juggle, "kill")
    assert code == 2 and "--yes" in err
    assert "juggle" in (org / "tasks.org").read_text()
    code, out, _ = run(capsys, "-s", socket, "kill", juggle, "--yes")
    assert code == 0 and out == f"{juggle}  TODO Learn to juggle :someday:  (deleted)\n"
    assert "juggle" not in (org / "tasks.org").read_text()


def test_clock(daemon, capsys):
    fresh_minute()
    socket, org = daemon
    juggle = task_id(run(capsys, "-s", socket, "all")[1], "juggle")
    assert run(capsys, "-s", socket, "clock") == (0, "No clock running.\n", "")
    assert run(capsys, "-s", socket, "clock", "--short") == (0, "", "")
    code, out, _ = run(capsys, "-s", socket, juggle, "clock", "in", "-30m")
    assert code == 0 and out.startswith(f"{juggle}  TODO Learn to juggle :someday:  clocked in at ")
    code, out, _ = run(capsys, "-s", socket, "clock", "--short")
    assert out == "⏱ Learn to juggle 0:30\n"
    code, out, _ = run(capsys, "-s", socket, "clock", "out", "-10m")
    assert code == 0 and out.endswith(" · 0:20\n")
    code, out, _ = run(capsys, "-s", socket, juggle, "clocks")
    assert code == 0 and "  0:20\n" in out and out.endswith("Total 0:20\n")
    code, out, _ = run(capsys, "-s", socket, juggle, "clocks", "1", "rm")
    assert code == 0 and "No clocks." in out
    assert "CLOCK" not in (org / "tasks.org").read_text()
    code, _, err = run(capsys, "-s", socket, "clock", "out")
    assert code == 1 and err == "orgwarrior: There's no clock running\n"


def test_report(daemon, capsys):
    socket, _ = daemon
    juggle = task_id(run(capsys, "-s", socket, "all")[1], "juggle")
    # 30 minutes in one call: clocking in and out apart, a minute could pass between.
    run(capsys, "-s", socket, juggle, "clocks", "add", "-40m", "30m")
    code, out, _ = run(capsys, "-s", socket, "clocked")
    assert code == 0 and out.splitlines()[0].startswith("Clocked · ") and f"{juggle}      Learn to juggle" in out
    assert out.rstrip().endswith("0:30")
    code, out, _ = run(capsys, "-s", socket, "clocked", "lastyear")
    assert code == 0 and "Nothing clocked." in out


def test_closed_and_archives(daemon, capsys):
    socket, _ = daemon
    juggle = task_id(run(capsys, "-s", socket, "all")[1], "juggle")
    run(capsys, "-s", socket, juggle, "done", "-m", "Did it")
    run(capsys, "-s", socket, juggle, "archive")
    code, out, _ = run(capsys, "-s", socket, "closed", "week")
    assert code == 0 and re.search(r"Closed: +DONE Learn to juggle", out)
    archived = task_id(out, "juggle")
    code, out, _ = run(capsys, "-s", socket, archived)
    assert code == 0 and "tasks.org_archive" in out
    assert "juggle" not in run(capsys, "-s", socket, "juggle")[1].split("\n", 1)[1]
    assert "Learn to juggle" in run(capsys, "-s", socket, "--archive", "juggle")[1]
