"""`orgwarrior --check`: what a first run needs, each thing found or what
to do about it.  Runs without a config that loads, since a broken one is
one of the things it reports."""

import os
import shutil
import textwrap
from pathlib import Path

from orgwarrior import OrgwarriorError, __version__
from orgwarrior import config as configmod
from orgwarrior import emacs

OK, WARN, FAIL = "ok", "warn", "fail"
ROLE = {OK: "done", WARN: "upcoming", FAIL: "todo"}


def findings(socket: str | None) -> list[tuple[str, str, list[str]]]:
    """Each check as (status, what was found, lines on what to do)."""
    out = []
    path = configmod.config_path()
    config = None
    if not path.exists():
        out.append((OK, f"no config file ({_home(path)}); the defaults apply", []))
        config = configmod.Config()
    else:
        try:
            config = configmod.load(path)
            out.append((OK, f"config: {_home(path)}", []))
        except OrgwarriorError as e:
            out.append((FAIL, f"config: {_home(path)} has a problem", [str(e)]))
    socket = socket or os.environ.get("ORGWARRIOR_SOCKET") or (config.socket if config else None)

    client = shutil.which("emacsclient")
    if not client:
        out.append((FAIL, "emacsclient isn't on your PATH", [
            "It comes with Emacs. Install Emacs 29 or later, or add the folder",
            "that has emacsclient to PATH."]))
        return out
    out.append((OK, f"emacsclient: {_home(Path(client))}", []))

    try:
        s = emacs.call({"op": "setup", "file": config.add_file if config else None,
                        "heading": config.add_heading if config else None}, socket, timeout=10)
    except OrgwarriorError as e:
        if "no Emacs daemon" not in str(e):
            out.append((FAIL, "Emacs couldn't run the check", [str(e)]))
            return out
        out.append((FAIL, f"no Emacs server is running{f' on socket {socket!r}' if socket else ''}", [
            "Start one with `emacs --daemon` (or your system's Emacs service). If",
            "you keep Emacs open as an app instead, add (server-start) to your",
            "init file. If your daemon has a name (emacs --daemon=work), set",
            'socket = "work" in the config.']))
        return out

    major = int(s["emacs"].split(".")[0])
    how = "running as a daemon" if s["daemon"] else "running a server but not as a daemon, so orgwarrior stops working when you close it"
    out.append((OK if major >= 29 else FAIL, f"Emacs {s['emacs']} with Org {s['org']}, {how}",
                ([f"socket: {s['socket']}"] if s["socket"] else [])
                + ([] if major >= 29 else ["orgwarrior needs Emacs 29 or later."])))

    if s["init"]:
        out.append((OK, f"init file: {s['init']}", []))
    elif s.get("xdg_init") and s["emacs_dir"].rstrip("/") != s["xdg_init"].rsplit("/", 1)[0]:
        out.append((FAIL, f"Emacs ignores {s['xdg_init']}, because {s['emacs_dir']} exists", [
            f"Emacs reads {s['emacs_dir']} when it's there (it often makes that folder",
            "itself, for its own files). Move init.el into it, or delete it, then",
            "restart Emacs."]))
    else:
        out.append((WARN, "Emacs loaded no init file", [
            "So none of your org settings are loaded. Put them in",
            "~/.emacs.d/init.el, which Emacs always reads, then restart Emacs.",
            "(~/.config/emacs/init.el works only while there's no ~/.emacs.d,",
            "and Emacs often makes that folder itself.)"]))

    files = s["files"]
    if s["agenda_setting"] == "unset":
        out.append((FAIL, "org-agenda-files isn't set, so every view is empty", [
            "Set it in your init file, then restart Emacs. A folder works:",
            "  (setq org-agenda-files '(\"~/org\"))"]))
    elif not files:
        out.append((FAIL, "org-agenda-files names no file that exists, so every view is empty",
                    [f"Missing: {', '.join(s['missing'])}"] if s["missing"] else []))
    else:
        out.append((OK, f"{len(files)} agenda file{'s' if len(files) != 1 else ''}: {_list(files)}", []))
        if s["missing"]:
            out.append((WARN, f"org-agenda-files names something that doesn't exist: {', '.join(s['missing'])}",
                        ["orgwarrior skips it, and Emacs's agenda stops to ask about it.",
                         "Fix the path or remove it."]))
    if s["read_only"]:
        out.append((OK, f"read only (not writable, so never changed): {_list(s['read_only'])}", []))
    if s["encrypted"]:
        out.append((FAIL, f"encrypted and not open in Emacs: {_list(s['encrypted'])}", [
            "orgwarrior can't type a passphrase, so it refuses to run. Open the",
            "file in Emacs once (it stays decrypted while Emacs runs), or take it",
            "out of org-agenda-files."]))
    if s["unsaved"]:
        out.append((WARN, f"unsaved changes in Emacs: {_list(s['unsaved'])}", [
            "orgwarrior won't change these files until they're saved."]))

    if "file" in s["add"]:
        out.append((OK, f"add writes to {s['add']['file']}", []))
    else:
        out.append((WARN, "add has nowhere to write", [s["add"]["error"]]))
    if config:
        missing = [f"{name} = {key!r}" for name, key in config.views.items() if key not in s["commands"]]
        if missing:
            out.append((FAIL, f"[views] names agenda commands Emacs doesn't have: {', '.join(missing)}", [
                "Each value has to be a key from your org-agenda-custom-commands."]))

    if not s.get("log_done", True):
        out.append((WARN, "org-log-done isn't set, so finished tasks get no CLOSED time", [
            "orgwarrior closed lists tasks by that time, so it stays empty. Add",
            "this to your init file to have org stamp it:",
            "  (setq org-log-done 'time)"]))
    if not s["refile"]:
        out.append((WARN, "org-refile-targets isn't set, so refile only offers headings in the task's own file", [
            "To refile anywhere in your agenda files, add this to your init file:",
            "  (setq org-refile-targets '((org-agenda-files :maxlevel . 2)))"]))
    return out


def _home(path: Path) -> str:
    try:
        return "~/" + str(path.relative_to(Path.home()))
    except ValueError:
        return str(path)


def _list(items: list[str], n: int = 3) -> str:
    return ", ".join(items[:n]) + (f" and {len(items) - n} more" if len(items) > n else "")


def report(socket: str | None, painter) -> int:
    """Print the findings; 1 if anything has to be fixed."""
    found = findings(socket)
    print(f"orgwarrior {__version__}, checking your setup\n")
    for status, what, lines in found:
        print(f"  {painter.wrap(status.ljust(4), ROLE[status])}  {what}")
        for line in lines:
            # Messages from Emacs come as one long line; the advice written here
            # is wrapped already, and its code lines keep their indent.
            for part in textwrap.wrap(line, 70, break_on_hyphens=False, break_long_words=False) if len(line) > 70 else [line]:
                print(f"        {part}")
    fails = sum(status == FAIL for status, _, _ in found)
    warns = sum(status == WARN for status, _, _ in found)
    print()
    if fails:
        print(f"{fails} thing{'s' if fails > 1 else ''} to fix before orgwarrior can work.")
    elif warns:
        print("orgwarrior can work. The warnings above are worth a look.")
    else:
        print("Everything orgwarrior needs is in place.")
    return 1 if fails else 0
