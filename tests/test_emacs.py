import json
import subprocess

import pytest

from conftest import needs_emacs
from orgwarrior import emacs

TRICKY = 'quote " backslash \\ newline \n tab \t paren ) unicode é → 🦀 %s'


@needs_emacs
def test_string_round_trip_through_real_emacs():
    """What we send is read back exactly, and what Emacs prints we decode exactly."""
    out = subprocess.run(
        ["emacs", "-Q", "--batch", "--eval",
         f"(princ (prin1-to-string {emacs.elisp_string(TRICKY)}))"],
        capture_output=True, text=True, check=True).stdout
    assert emacs.read_elisp_string(out) == TRICKY


@needs_emacs
def test_expression_loads_backend_and_answers():
    out = subprocess.run(
        ["emacs", "-Q", "--batch", "--eval",
         f"(princ (prin1-to-string {emacs.expression({'op': 'bogus', 'x': TRICKY})}))"],
        capture_output=True, text=True, check=True).stdout
    assert json.loads(emacs.read_elisp_string(out)) == {"error": "Unknown op: bogus"}


@needs_emacs
def test_expression_from_a_file(tmp_path):
    """A request too big for a command line goes in a file, read as UTF-8."""
    path = tmp_path / "request.json"
    path.write_text(json.dumps({"op": "bogus", "x": TRICKY}, ensure_ascii=False), encoding="utf-8")
    out = subprocess.run(
        ["emacs", "-Q", "--batch", "--eval",
         f"(princ (prin1-to-string {emacs.expression({}, str(path))}))"],
        capture_output=True, text=True, check=True).stdout
    assert json.loads(emacs.read_elisp_string(out)) == {"error": "Unknown op: bogus"}


def test_unexpected_reply():
    with pytest.raises(emacs.EmacsError):
        emacs.read_elisp_string("nil")


def test_no_daemon():
    with pytest.raises(emacs.EmacsError, match="no Emacs daemon"):
        emacs.call({"op": "view"}, socket="orgwarrior-test-nonexistent-socket")
