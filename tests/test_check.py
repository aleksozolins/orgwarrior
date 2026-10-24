"""orgwarrior --check against a stubbed Emacs: what it reports for a
working setup and for the usual first-run mistakes."""

import pytest

from orgwarrior import check, cli, emacs

GOOD = {"emacs": "30.1", "org": "9.7", "daemon": True, "socket": "/run/user/1000/emacs/server",
        "init": "~/.config/emacs/init.el", "agenda_setting": "list", "missing": [],
        "files": ["~/org/inbox.org", "~/org/tasks.org"], "read_only": [], "encrypted": [],
        "unsaved": [], "add": {"file": "~/org/inbox.org"}, "refile": True, "log_done": True,
        "commands": ["d"]}


@pytest.fixture
def setup(monkeypatch, tmp_path):
    """Emacs answering with GOOD, changed by the test; no config file."""
    monkeypatch.setenv("ORGWARRIOR_CONFIG", str(tmp_path / "config.toml"))
    monkeypatch.setattr(check.shutil, "which", lambda name: "/usr/bin/emacsclient")
    answer = dict(GOOD)
    monkeypatch.setattr(emacs, "call", lambda request, socket=None, timeout=None: answer)
    return answer


def statuses(socket=None):
    return {what: status for status, what, _ in check.findings(socket)}


def test_good_setup(setup):
    found = statuses()
    assert set(found.values()) == {"ok"}
    assert "2 agenda files: ~/org/inbox.org, ~/org/tasks.org" in found


def test_first_run_mistakes(setup):
    setup.update(init=None, agenda_setting="unset", files=[], refile=False, log_done=False,
                 add={"error": "There's no file to add to"})
    found = statuses()
    assert found["Emacs loaded no init file"] == "warn"
    assert found["org-agenda-files isn't set, so every view is empty"] == "fail"
    assert found["add has nowhere to write"] == "warn"
    assert any(s == "warn" and w.startswith("org-refile-targets") for w, s in found.items())
    assert any(s == "warn" and w.startswith("org-log-done") for w, s in found.items())


def test_missing_agenda_path_warns(setup):
    setup.update(missing=["~/orgg/work.org"])
    assert statuses()["org-agenda-files names something that doesn't exist: ~/orgg/work.org"] == "warn"


def test_views_checked_against_emacs(setup, tmp_path):
    (tmp_path / "config.toml").write_text('[views]\ndash = "d"\ninbox = "i"\n')
    found = statuses()
    assert found["[views] names agenda commands Emacs doesn't have: inbox = 'i'"] == "fail"


def test_broken_config_still_checks_emacs(setup, tmp_path):
    (tmp_path / "config.toml").write_text('tags = "left"\n')
    found = statuses()
    assert any(s == "fail" and w.startswith("config:") for w, s in found.items())
    assert any(w.startswith("Emacs 30.1") for w in found)


def test_no_daemon(monkeypatch, tmp_path):
    monkeypatch.setenv("ORGWARRIOR_CONFIG", str(tmp_path / "config.toml"))
    monkeypatch.setattr(check.shutil, "which", lambda name: "/usr/bin/emacsclient")

    def down(request, socket=None, timeout=None):
        raise emacs.EmacsError("no Emacs daemon is running.")
    monkeypatch.setattr(emacs, "call", down)
    found = check.findings("work")
    assert found[-1][:2] == ("fail", "no Emacs server is running on socket 'work'")


def test_main_exit_codes(setup, capsys):
    assert cli.main(["--check"]) == 0
    assert "Everything orgwarrior needs is in place." in capsys.readouterr().out
    setup.update(files=[], agenda_setting="unset")
    assert cli.main(["--check"]) == 1
    assert cli.main(["--check", "today"]) == 2
    assert cli.main(["-s", "work", "--check"]) == 1


def test_check_only_as_an_option(monkeypatch):
    # Elsewhere on the line it's text, like a note's.
    seen = []
    monkeypatch.setattr(cli, "run", lambda command, config, socket: seen.append(command))
    assert cli.main(["c1", "note", "ran", "--check", "twice"]) == 0
    assert seen[0].args == ["ran", "--check", "twice"]


def test_init_hidden_by_emacs_d(setup):
    # A native-compiling Emacs makes ~/.emacs.d on its first start, and then
    # never reads ~/.config/emacs/init.el.
    setup.update(init=None, emacs_dir="~/.emacs.d/", xdg_init="~/.config/emacs/init.el")
    assert statuses()["Emacs ignores ~/.config/emacs/init.el, because ~/.emacs.d/ exists"] == "fail"
    setup.update(emacs_dir="~/.config/emacs/", xdg_init="~/.config/emacs/init.el")
    assert statuses()["Emacs loaded no init file"] == "warn"
