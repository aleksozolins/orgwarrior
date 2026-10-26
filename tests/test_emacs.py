import json
import subprocess

import pytest

from conftest import needs_emacs
from orgwarrior import emacs

TRICKY = 'quote " backslash \\ newline \n tab \t paren ) unicode é → 🦀 %s'


def run_expression(tmp_path, request, path=None):
    out = tmp_path / "reply.json"
    subprocess.run(["emacs", "-Q", "--batch", "--eval", emacs.expression(request, path, str(out))],
                   capture_output=True, text=True, check=True)
    return json.loads(out.read_text(encoding="utf-8"))


@needs_emacs
def test_expression_loads_backend_and_answers(tmp_path):
    assert run_expression(tmp_path, {"op": "bogus", "x": TRICKY}) == {"error": "Unknown op: bogus"}


@needs_emacs
def test_expression_from_a_file(tmp_path):
    """A request too big for a command line goes in a file, read as UTF-8."""
    path = tmp_path / "request.json"
    path.write_text(json.dumps({"op": "bogus", "x": TRICKY}, ensure_ascii=False), encoding="utf-8")
    assert run_expression(tmp_path, {}, str(path)) == {"error": "Unknown op: bogus"}


@needs_emacs
def test_long_reply(tmp_path):
    """A reply far longer than emacsclient's 1 KiB reads on macOS arrives whole."""
    reply = run_expression(tmp_path, {"op": "bogus" + "é" * 5000})
    assert reply == {"error": "Unknown op: bogus" + "é" * 5000}


def test_no_daemon():
    with pytest.raises(emacs.EmacsError, match="no Emacs daemon"):
        emacs.call({"op": "view"}, socket="orgwarrior-test-nonexistent-socket")
