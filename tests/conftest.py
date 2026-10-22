import os
import shutil
import subprocess
import time
import uuid
from pathlib import Path

import pytest

TESTS = Path(__file__).parent
needs_emacs = pytest.mark.skipif(not shutil.which("emacs"), reason="emacs not installed")


@pytest.fixture
def daemon(tmp_path, monkeypatch):
    """A throwaway `emacs -Q` daemon set up on a fresh copy of the fixtures.

    Yields (socket name, org dir).  The real daemon and org files are never touched.
    """
    if not shutil.which("emacsclient"):
        pytest.skip("emacsclient not installed")
    name = f"orgwarrior-test-{uuid.uuid4().hex[:8]}"
    org = tmp_path / "org"
    env = {**os.environ, "ORGWARRIOR_FIXTURE_DEST": str(org)}
    subprocess.run(["emacs", "-Q", f"--daemon={name}", "-l", str(TESTS / "fixture-init.el")],
                   env=env, check=True, capture_output=True, timeout=30)
    config = tmp_path / "config.toml"
    config.write_text(f'[add]\nfile = "{org / "inbox.org"}"\nheading = "Tasks"\ncaptured = true\n')
    monkeypatch.setenv("ORGWARRIOR_CONFIG", str(config))
    monkeypatch.delenv("ORGWARRIOR_SOCKET", raising=False)
    try:
        yield name, org
    finally:
        env.pop("ALTERNATE_EDITOR", None)  # no daemon -> emacsclient would launch it
        subprocess.run(["emacsclient", "--socket-name", name, "--eval", "(kill-emacs)"],
                       env=env, capture_output=True, timeout=10)
        time.sleep(0.05)
