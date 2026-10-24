import pytest

from orgwarrior import config


def test_missing_file_gives_defaults(tmp_path):
    c = config.load(tmp_path / "nope.toml")
    assert c.default_view == "today" and c.views == {} and c.add_file is None
    assert c.tags == "inline"
    assert c.time_grid is False and c.color == "auto" and c.colors["todo"] == "1;31"


def test_full_config(tmp_path):
    p = tmp_path / "config.toml"
    p.write_text('default_view = "d"\nprefix_format = " %-9:c"\ntime_grid = true\ncolor = "never"\n'
                 '[views]\ninbox = "i"\n'
                 '[add]\nfile = "~/org/inbox.org"\nheading = "Tasks"\ncaptured = true\n'
                 '[add.event]\nfile = "~/org/calendar.org"\nheading = "Events"\n'
                 '[refile]\nnew_in = "projects.org"\nnew_suffix = " [/]"\nusual = "tasks"\n'
                 '[colors]\nNEXT = "bold bright-yellow"\ntag = "none"\n'
                 '[web.tabs]\nnext = "next"\nhome = "+@home"\n')
    c = config.load(p)
    assert c.default_view == "d"
    assert c.views == {"inbox": "i"}
    assert c.prefix_format == " %-9:c"
    assert c.time_grid is True and c.color == "never"
    assert c.add_file.endswith("/org/inbox.org") and not c.add_file.startswith("~")
    assert c.add_heading == "Tasks" and c.add_captured is True
    assert c.event_file.endswith("/org/calendar.org") and not c.event_file.startswith("~")
    assert c.event_heading == "Events" and c.event_captured is False
    assert c.refile_new_in == "projects.org" and c.refile_new_suffix == " [/]" and c.refile_usual == "tasks"
    assert c.colors["NEXT"] == "1;93" and c.colors["tag"] == "" and c.colors["id"] == "34"
    assert list(c.web["tabs"].items()) == [("next", "next"), ("home", "+@home")]  # in order


@pytest.mark.parametrize("text, message", [
    ('bogus = 1', "no key"),
    ('default_view = 3', "must be a string"),
    ('inbox = "~/org/inbox.org"', "no key 'inbox'"),
    ('time_grid = "yes"', "true or false"),
    ('color = "sometimes"', "color must be"),
    ('[colors]\ntodo = "chartreuse"', "isn't a color"),
    ('[colors]\ntodo = "#ff00"', "#rrggbb"),
    ('tags = "left"', "tags must be"),
    ('[colors]\nnext = "red"', "uppercase TODO keyword"),
    ('[add]\nfolder = "x"', "\\[add\\] has no key"),
    ('[add]\ncaptured = 1', "true or false"),
    ('[add.event]\nfolder = "x"', "\\[add.event\\] has no key"),
    ('[refile]\nnew_in = 1', "\\[refile\\] new_in must be a string"),
    ('[views]\nx = 1', "views"),
    ('web = 1', "web must be a table"),
    ('default_view = ', "config.toml"),
])
def test_bad_config(tmp_path, text, message):
    p = tmp_path / "config.toml"
    p.write_text(text)
    with pytest.raises(config.ConfigError, match=message):
        config.load(p)


def test_xdg_path(monkeypatch, tmp_path):
    monkeypatch.delenv("ORGWARRIOR_CONFIG", raising=False)
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    assert config.config_path() == tmp_path / "orgwarrior" / "config.toml"


def test_sgr():
    assert config.sgr("bold red") == "1;31"
    assert config.sgr("bright-blue") == "94"
    assert config.sgr("bold #ff8f88") == "1;38;2;255;143;136"
    assert config.sgr("black on-#0fed00") == "30;48;2;15;237;0"
    assert config.sgr("on-bright-red") == "101"
    assert config.sgr("none") == ""
