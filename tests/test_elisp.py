import subprocess
from pathlib import Path

import pytest

from conftest import needs_emacs


@needs_emacs
@pytest.mark.parametrize("suite", ["orgwarrior-test.el", "orgwarrior-alt-test.el"])
def test_ert_suite(suite):
    """The backend against real org and real files: GTD-like keywords and
    logging (orgwarrior-test.el), and a setup unlike his (-alt)."""
    proc = subprocess.run(
        ["emacs", "-Q", "--batch", "-l", str(Path(__file__).with_name(suite)),
         "-f", "ert-run-tests-batch-and-exit"],
        capture_output=True, text=True, timeout=120)
    summary = [l for l in proc.stderr.splitlines() if l.startswith(("Ran ", "   FAILED"))]
    assert proc.returncode == 0, "\n".join(summary) or proc.stderr[-3000:]
