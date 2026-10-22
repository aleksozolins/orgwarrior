"""~/.config/orgwarrior/config.toml: everything optional."""

import os
import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from orgwarrior import OrgwarriorError


class ConfigError(OrgwarriorError):
    pass


# What orgwarrior colors: parts of agenda lines and of a shown task (named after
# the org faces they come from in orgwarrior.el's `orgwarrior--face-roles'), TODO
# keywords, and IDs.
DEFAULT_COLORS = {
    "id": "blue",
    "header": "bold",
    "date": "bold green",
    "today": "bold underline green",
    "time": "bold",
    "extra": "dim",  # "Scheduled:", "In 2 d.:"
    "grid": "dim",
    "now": "magenta",
    "overdue": "red",
    "deadline": "bold red",
    "upcoming": "magenta",
    "done-item": "dim",
    "priority": "bold",
    "tag": "cyan",
    "todo": "bold red",
    "done": "green",
    "heading": "bold",
    "label": "magenta",  # SCHEDULED:, :PROPERTY:
    "drawer": "dim",
    "timestamp": "green",
    "link": "underline",
    "checkbox": "bold",
}
# A habit's days, by state (org-habit's faces; "-future" for days to come):
# no default, they take the background Emacs gives them.
HABIT_ROLES = tuple(f"habit-{state}{future}" for state in ("clear", "ready", "alert", "overdue")
                    for future in ("", "-future"))
ROLES = (*DEFAULT_COLORS, *HABIT_ROLES)

_SGR = {"bold": 1, "dim": 2, "italic": 3, "underline": 4}
for _i, _name in enumerate(("black", "red", "green", "yellow", "blue", "magenta", "cyan", "white")):
    _SGR[_name] = 30 + _i
    _SGR[f"bright-{_name}"] = 90 + _i
    _SGR[f"on-{_name}"] = 40 + _i
    _SGR[f"on-bright-{_name}"] = 100 + _i

KEYWORD_RE = re.compile(r"[A-Z][A-Z0-9_-]*")
HEX_RE = re.compile(r"#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})")


def sgr(spec: str) -> str:
    """"bold red" -> the ANSI SGR parameters "1;31"; "none" -> "".
    A "#rrggbb" word is a 24-bit foreground color, "on-#rrggbb" a background."""
    words = spec.split()
    if words == ["none"]:
        return ""
    codes = []
    for w in words:
        if m := HEX_RE.fullmatch(w.removeprefix("on-")):
            codes.append(("48;2;" if w.startswith("on-") else "38;2;")
                         + ";".join(str(int(x, 16)) for x in m.groups()))
        elif w in _SGR:
            codes.append(str(_SGR[w]))
        else:
            raise ValueError(spec)
    if not codes:
        raise ValueError(spec)
    return ";".join(codes)


@dataclass
class Config:
    default_view: str = "today"
    socket: str | None = None  # emacsclient --socket-name
    prefix_format: str | None = None  # org-agenda-prefix-format, for orgwarrior only
    time_grid: bool = False
    tags: str = "inline"  # inline: right after the title; right: right-aligned
    color: str = "auto"  # auto always never
    colors: dict[str, str] = field(  # role or TODO keyword -> SGR parameters
        default_factory=lambda: {k: sgr(v) for k, v in DEFAULT_COLORS.items()})
    views: dict[str, str] = field(default_factory=dict)  # name -> agenda command key
    web: dict = field(default_factory=dict)  # [web], as is: orgwarrior-web reads it
    add_file: str | None = None  # None: org-default-notes-file
    add_heading: str | None = None  # None: top level, at the end of the file
    add_captured: bool = False
    event_file: str | None = None  # [add.event]; None: [add]'s file
    event_heading: str | None = None
    event_captured: bool = False
    refile_new_in: str | None = None  # [refile]: where refile --new makes a heading
    refile_new_suffix: str = ""  # after its title: " [/]", a count of its tasks
    refile_usual: str | None = None  # [refile]: a front end's first choice ("tasks")


def config_path() -> Path:
    if explicit := os.environ.get("ORGWARRIOR_CONFIG"):
        return Path(explicit).expanduser()
    base = os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config"
    return Path(base) / "orgwarrior" / "config.toml"


def _check(path, key, value, kind):
    if not isinstance(value, kind):
        name = {str: "a string", bool: "true or false", dict: "a table"}[kind]
        raise ConfigError(f"{path}: {key} must be {name}")
    return value


def load(path: Path | None = None) -> Config:
    path = path or config_path()
    if not path.is_file():
        return Config()
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f"{path}: {e}") from None

    config = Config()
    for key, value in data.items():
        if key in ("default_view", "socket", "prefix_format"):
            setattr(config, key, _check(path, key, value, str))
        elif key == "time_grid":
            config.time_grid = _check(path, key, value, bool)
        elif key == "tags":
            if value not in ("inline", "right"):
                raise ConfigError(f"{path}: tags must be \"inline\" or \"right\"")
            config.tags = value
        elif key == "color":
            if value not in ("auto", "always", "never"):
                raise ConfigError(f"{path}: color must be \"auto\", \"always\" or \"never\"")
            config.color = value
        elif key == "colors":
            for name, spec in _check(path, key, value, dict).items():
                if name not in ROLES and not KEYWORD_RE.fullmatch(name):
                    raise ConfigError(f"{path}: [colors] {name!r} is neither one of "
                                      f"{', '.join(ROLES)} nor an uppercase TODO keyword")
                try:
                    config.colors[name] = sgr(_check(path, f"[colors] {name}", spec, str))
                except ValueError:
                    raise ConfigError(
                        f"{path}: [colors] {name} = {spec!r}: use \"none\", #rrggbb, on-#rrggbb or words "
                        f"from {', '.join(_SGR)}") from None
        elif key == "web":
            config.web = _check(path, key, value, dict)
        elif key == "views":
            if not isinstance(value, dict) or not all(
                isinstance(v, str) for v in value.values()
            ):
                raise ConfigError(f"{path}: [views] maps names to agenda command keys (strings)")
            config.views = dict(value)
        elif key == "add":
            for name, v in _check(path, key, value, dict).items():
                if name in ("file", "heading"):
                    setattr(config, f"add_{name}", _check(path, f"[add] {name}", v, str))
                elif name == "captured":
                    config.add_captured = _check(path, "[add] captured", v, bool)
                elif name == "event":
                    for ename, ev in _check(path, "[add.event]", v, dict).items():
                        if ename in ("file", "heading"):
                            setattr(config, f"event_{ename}",
                                    _check(path, f"[add.event] {ename}", ev, str))
                        elif ename == "captured":
                            config.event_captured = _check(path, "[add.event] captured", ev, bool)
                        else:
                            raise ConfigError(f"{path}: unknown key [add.event] {ename!r}")
                else:
                    raise ConfigError(f"{path}: unknown key [add] {name!r}")
        elif key == "refile":
            for name, v in _check(path, key, value, dict).items():
                if name in ("new_in", "new_suffix", "usual"):
                    setattr(config, f"refile_{name}", _check(path, f"[refile] {name}", v, str))
                else:
                    raise ConfigError(f"{path}: unknown key [refile] {name!r}")
        else:
            raise ConfigError(f"{path}: unknown key {key!r}")

    if config.add_file:
        config.add_file = str(Path(config.add_file).expanduser())
    if config.event_file:
        config.event_file = str(Path(config.event_file).expanduser())
    return config
