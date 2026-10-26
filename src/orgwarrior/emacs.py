"""Talking to the Emacs daemon through emacsclient.

Every call sends one JSON request to `orgwarrior-call` (orgwarrior.el) and gets one
JSON reply back, written to a file.  User text only ever crosses as the
contents of an elisp string literal, never spliced into code.
"""

import json
import os
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


def expression(request: dict, path: str | None, out: str) -> str:
    """The form to evaluate: (re)load orgwarrior.el if this copy isn't loaded,
    then call it with REQUEST, or with the JSON in the file at PATH, and
    write the reply to the file OUT.  Not printed: emacsclient on macOS
    reads its socket 1 KiB at a time and garbles a message split across two
    reads, so a long reply came back cut ("Unknown message: -")."""
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
        " (let ((coding-system-for-write 'utf-8-unix))"
        f" (write-region (orgwarrior-call {arg}) nil {elisp_string(out)} nil 0))"
        " nil)"
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
    fd, out = tempfile.mkstemp(prefix="orgwarrior-reply-", suffix=".json")
    os.close(fd)
    cmd += ["--eval", expression(request, path, out)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=timeout)
    except FileNotFoundError:
        raise EmacsError("emacsclient isn't on your PATH. It comes with Emacs") from None
    except subprocess.TimeoutExpired:
        raise EmacsError(f"Emacs didn't answer within {timeout}s. It may be busy, or waiting for you to answer a question in Emacs") from None
    finally:
        if path:
            os.unlink(path)
        with open(out, encoding="utf-8") as f:
            reply = f.read()
        os.unlink(out)

    if proc.returncode != 0:
        stderr = proc.stderr.strip()
        if "*ERROR*" in stderr:
            raise EmacsError(f"Emacs error: {stderr.split('*ERROR*:', 1)[-1].strip()}")
        where = f" on socket {socket!r}" if socket else ""
        raise EmacsError(f"no Emacs daemon is running{where}. Start one with `emacs --daemon`, or add "
                         "(server-start) to your init file if you keep Emacs open. "
                         "`orgwarrior --check` checks the rest of your setup.")

    try:
        reply = json.loads(reply)
    except ValueError:
        raise EmacsError(f"Emacs sent a reply orgwarrior doesn't understand: {reply[:200]!r}") from None
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
