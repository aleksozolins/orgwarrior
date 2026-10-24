"""Talking to the Emacs daemon through emacsclient.

Every call sends one JSON request to `orgwarrior-call` (orgwarrior.el) and gets one
JSON reply back.  User text only ever crosses as the contents of an elisp
string literal, never spliced into code.
"""

import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

from orgwarrior import OrgwarriorError

ELISP = Path(__file__).with_name("orgwarrior.el")
TIMEOUT = 60
# Linux caps one command-line argument at 128 KiB: a request bigger than this
# (a long details text) goes in a file the daemon reads instead.
INLINE_MAX = 64 * 1024


class EmacsError(OrgwarriorError):
    pass


def elisp_string(s: str) -> str:
    """`s` as an elisp string literal."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def read_elisp_string(printed: str) -> str:
    """Undo emacsclient's printing of a string result.

    `prin1` escapes only backslash and double quote; orgwarrior.el keeps its
    replies ASCII with no control characters, so nothing else appears.
    """
    printed = printed.strip()
    if len(printed) < 2 or printed[0] != '"' or printed[-1] != '"':
        raise EmacsError(f"Emacs sent a reply orgwarrior doesn't understand: {printed[:200]}")
    return re.sub(r"\\(.)", r"\1", printed[1:-1], flags=re.DOTALL)


def expression(request: dict, path: str | None = None) -> str:
    """The form to evaluate: (re)load orgwarrior.el if this copy isn't loaded,
    then call it with REQUEST, or with the JSON in the file at PATH."""
    st = ELISP.stat()
    stamp = elisp_string(f"{ELISP}:{st.st_mtime_ns}:{st.st_size}")
    arg = (elisp_string(json.dumps(request, ensure_ascii=False)) if path is None else
           "(with-temp-buffer (let ((coding-system-for-read 'utf-8))"
           f" (insert-file-contents {elisp_string(path)})) (buffer-string))")
    return (
        "(progn"
        f" (unless (equal (bound-and-true-p orgwarrior--stamp) {stamp})"
        f" (load {elisp_string(str(ELISP))} nil t t)"
        f" (setq orgwarrior--stamp {stamp}))"
        f" (orgwarrior-call {arg}))"
    )


def _emacsclient(socket: str | None) -> tuple[list[str], dict]:
    cmd = ["emacsclient"]
    if socket:
        cmd += ["--socket-name", socket]
    # Never let emacsclient start an editor or daemon of its own.
    env = {k: v for k, v in os.environ.items() if k != "ALTERNATE_EDITOR"}
    return cmd, env


def call(request: dict, socket: str | None = None, timeout: float = TIMEOUT):
    """Run `request` in the daemon and return the `ok` part of the reply."""
    cmd, env = _emacsclient(socket)
    encoded = json.dumps(request, ensure_ascii=False).encode()
    path = None
    if len(encoded) > INLINE_MAX:
        fd, path = tempfile.mkstemp(prefix="orgwarrior-", suffix=".json")  # 0600
        with os.fdopen(fd, "wb") as f:
            f.write(encoded)
    cmd += ["--eval", expression(request, path)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=timeout)
    except FileNotFoundError:
        raise EmacsError("emacsclient isn't on your PATH. It comes with Emacs") from None
    except subprocess.TimeoutExpired:
        raise EmacsError(f"Emacs didn't answer within {timeout}s. It may be busy, or waiting for you to answer a question in Emacs") from None
    finally:
        if path:
            os.unlink(path)

    if proc.returncode != 0:
        stderr = proc.stderr.strip()
        if "*ERROR*" in stderr:
            raise EmacsError(f"Emacs error: {stderr.split('*ERROR*:', 1)[-1].strip()}")
        where = f" on socket {socket!r}" if socket else ""
        raise EmacsError(f"no Emacs daemon is running{where}. Start one with `emacs --daemon`, or add "
                         "(server-start) to your init file if you keep Emacs open. "
                         "`orgwarrior --check` checks the rest of your setup.")

    reply = json.loads(read_elisp_string(proc.stdout))
    if "error" in reply:
        raise EmacsError(reply["error"])
    return reply["ok"]


def edit(task_id: str, socket: str | None = None) -> bool:
    """Open the task in a terminal frame of the daemon; when it's closed,
    return whether unsaved changes were discarded."""
    buffer = call({"op": "edit", "id": task_id}, socket)["buffer"]
    cmd, env = _emacsclient(socket)
    cmd += ["-t", "--eval", f"(orgwarrior-edit-frame {elisp_string(buffer)})"]
    if subprocess.run(cmd, env=env).returncode != 0:
        raise EmacsError("emacsclient couldn't open a terminal frame")
    return call({"op": "edit-done", "buffer": buffer}, socket)["discarded"]
