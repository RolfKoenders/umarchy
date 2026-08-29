#!/usr/bin/env python3
"""Tests for bin/umami-state.

Regression tests for HANCORE-linux/omarchy-plugin-marketplace#2459 (fourth
round): mkdir -p and chmod-by-path both follow a symlink planted at the
target path, and FileView-by-path has no defense against a swapped-in FIFO
or oversized file. Unit tests exercise the descriptor-based directory walk
directly; integration tests drive the actual bin/umami-state subprocess
through its real argv/stdin/stdout/exit-code contract against a real
scratch $HOME, planting the exact symlink/FIFO/oversized-file attacks the
review described -- not mocks, matching test_umami_api.py's precedent.
"""

import importlib.machinery
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
STATE_SCRIPT = REPO_ROOT / "bin" / "umami-state"


def load_state_module():
    # bin/umami-state has no .py extension, so importlib can't infer a
    # loader from the file suffix alone -- an explicit SourceFileLoader is
    # required, matching test_umami_api.py's load_api_module().
    loader = importlib.machinery.SourceFileLoader("umami_state", str(STATE_SCRIPT))
    spec = importlib.util.spec_from_loader("umami_state", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


umami_state = load_state_module()


def call_state(args, stdin_bytes=None, home=None, timeout=10):
    env = dict(os.environ)
    if home is not None:
        env["HOME"] = home
    return subprocess.run(
        [sys.executable, str(STATE_SCRIPT)] + list(args),
        input=stdin_bytes,
        capture_output=True,
        timeout=timeout,
        env=env,
    )


class ScratchHomeTestCase(unittest.TestCase):
    """A fresh, empty $HOME per test, cleaned up afterward."""

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="umarchy-state-test-")
        self.state_dir = os.path.join(
            self.home, ".local", "state", "omarchy", "settings", "io.github.rolfkoenders.umarchy"
        )

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)


class OpenDirComponentTests(ScratchHomeTestCase):
    """Unit tests against the real no-follow directory walk logic."""

    def test_creates_missing_directory_at_given_mode(self):
        parent_fd = os.open(self.home, os.O_RDONLY | os.O_DIRECTORY)
        try:
            fd = umami_state.open_dir_component("sub", parent_fd, 0o700)
            try:
                self.assertEqual(stat.S_IMODE(os.fstat(fd).st_mode), 0o700)
            finally:
                os.close(fd)
        finally:
            os.close(parent_fd)

    def test_refuses_a_symlink_standing_in_for_a_directory(self):
        target = os.path.join(self.home, "target")
        os.mkdir(target)
        os.symlink(target, os.path.join(self.home, "link"))
        parent_fd = os.open(self.home, os.O_RDONLY | os.O_DIRECTORY)
        try:
            with self.assertRaises(umami_state.SecurityViolation):
                umami_state.open_dir_component("link", parent_fd, 0o700)
        finally:
            os.close(parent_fd)

    def test_refuses_a_plain_file_standing_in_for_a_directory(self):
        open(os.path.join(self.home, "notadir"), "w").close()
        parent_fd = os.open(self.home, os.O_RDONLY | os.O_DIRECTORY)
        try:
            with self.assertRaises(umami_state.SecurityViolation):
                umami_state.open_dir_component("notadir", parent_fd, 0o700)
        finally:
            os.close(parent_fd)


class EnsureDirIntegrationTests(ScratchHomeTestCase):
    def test_creates_the_full_chain_at_0700(self):
        result = call_state(["ensure-dir"], home=self.home)
        self.assertEqual(result.returncode, 0, result.stderr)
        mode = stat.S_IMODE(os.stat(self.state_dir).st_mode)
        self.assertEqual(mode, 0o700)

    def test_is_idempotent_across_two_runs(self):
        self.assertEqual(call_state(["ensure-dir"], home=self.home).returncode, 0)
        self.assertEqual(call_state(["ensure-dir"], home=self.home).returncode, 0)
        mode = stat.S_IMODE(os.stat(self.state_dir).st_mode)
        self.assertEqual(mode, 0o700)

    def test_refuses_a_pre_planted_symlink_at_the_final_directory(self):
        # The exact attack the review described: something else creates a
        # symlink at our predictable path before we ever run, pointing
        # somewhere the attacker controls. mkdir -p and chmod-by-path would
        # both silently follow this and "succeed" against the wrong
        # directory; ensure-dir must instead refuse outright.
        os.makedirs(os.path.join(self.home, ".local", "state", "omarchy", "settings"))
        elsewhere = os.path.join(self.home, "elsewhere")
        os.mkdir(elsewhere)
        os.symlink(elsewhere, self.state_dir)

        result = call_state(["ensure-dir"], home=self.home)
        self.assertEqual(result.returncode, 3, result.stderr)
        # And the redirected target must never have been touched (no
        # chmod 700 leaked through the symlink onto it).
        self.assertNotEqual(stat.S_IMODE(os.stat(elsewhere).st_mode), 0o700)


class ReadWriteIntegrationTests(ScratchHomeTestCase):
    def test_read_before_any_write_reports_not_found(self):
        self.assertEqual(call_state(["ensure-dir"], home=self.home).returncode, 0)
        result = call_state(["read", "umarchy.json"], home=self.home)
        self.assertEqual(result.returncode, 5)

    def test_write_then_read_round_trips_and_is_0600(self):
        self.assertEqual(call_state(["ensure-dir"], home=self.home).returncode, 0)
        payload = b'{"host":"https://example.com"}'
        write_result = call_state(["write", "umarchy.json"], stdin_bytes=payload, home=self.home)
        self.assertEqual(write_result.returncode, 0, write_result.stderr)

        path = os.path.join(self.state_dir, "umarchy.json")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

        read_result = call_state(["read", "umarchy.json"], home=self.home)
        self.assertEqual(read_result.returncode, 0, read_result.stderr)
        self.assertEqual(read_result.stdout, payload)

    def test_write_implicitly_ensures_the_directory_first(self):
        # persist()/persistToken() in Service.qml call write() directly
        # without a preceding ensureDir() -- the directory chain must be
        # walked and secured on every call, not assumed to already exist.
        payload = b'{"token":"abc"}'
        result = call_state(["write", "umarchy-token.json"], stdin_bytes=payload, home=self.home)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(os.stat(self.state_dir).st_mode), 0o700)

    def test_unknown_file_name_is_refused(self):
        self.assertEqual(call_state(["read", "some-other-file.json"], home=self.home).returncode, 4)
        self.assertEqual(
            call_state(["write", "some-other-file.json"], stdin_bytes=b"{}", home=self.home).returncode, 4
        )

    def test_path_traversal_shaped_name_is_refused(self):
        # Rejected by the fixed-name allowlist before any filesystem call
        # is even attempted -- dir_fd-relative opens do resolve ".."
        # components relative to that directory, so the allowlist check is
        # the thing actually stopping this, not O_NOFOLLOW.
        result = call_state(["read", "../../../etc/passwd"], home=self.home)
        self.assertEqual(result.returncode, 4)

    def test_refuses_a_symlink_standing_in_for_the_config_file(self):
        self.assertEqual(call_state(["ensure-dir"], home=self.home).returncode, 0)
        secret_target = os.path.join(self.home, "unrelated-secret.txt")
        with open(secret_target, "w") as f:
            f.write("not umarchy's business\n")
        os.symlink(secret_target, os.path.join(self.state_dir, "umarchy.json"))

        read_result = call_state(["read", "umarchy.json"], home=self.home)
        self.assertEqual(read_result.returncode, 3, read_result.stderr)
        self.assertNotIn(b"not umarchy's business", read_result.stdout)

        write_result = call_state(["write", "umarchy.json"], stdin_bytes=b"{}", home=self.home)
        self.assertEqual(write_result.returncode, 3, write_result.stderr)
        with open(secret_target) as f:
            self.assertEqual(f.read(), "not umarchy's business\n")

    def test_refuses_a_fifo_standing_in_for_the_config_file_without_hanging(self):
        self.assertEqual(call_state(["ensure-dir"], home=self.home).returncode, 0)
        fifo_path = os.path.join(self.state_dir, "umarchy.json")
        os.mkfifo(fifo_path)
        # timeout=5 turns a hang (the pre-fix-equivalent failure mode: a
        # blocking open against a FIFO with no reader/writer on the other
        # end) into a clean test failure instead of stalling the suite.
        result = call_state(["read", "umarchy.json"], home=self.home, timeout=5)
        self.assertEqual(result.returncode, 3, result.stderr)

    def test_oversized_existing_file_is_rejected_on_read(self):
        self.assertEqual(call_state(["ensure-dir"], home=self.home).returncode, 0)
        big_path = os.path.join(self.state_dir, "umarchy.json")
        with open(big_path, "wb") as f:
            f.write(b"x" * (umami_state.MAX_STATE_FILE_BYTES + 1))
        result = call_state(["read", "umarchy.json"], home=self.home)
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_oversized_stdin_is_rejected_on_write(self):
        self.assertEqual(call_state(["ensure-dir"], home=self.home).returncode, 0)
        payload = b"x" * (umami_state.MAX_STATE_FILE_BYTES + 1)
        result = call_state(["write", "umarchy.json"], stdin_bytes=payload, home=self.home)
        self.assertEqual(result.returncode, 2, result.stderr)
        # Nothing should have been written at all.
        self.assertFalse(os.path.exists(os.path.join(self.state_dir, "umarchy.json")))


if __name__ == "__main__":
    unittest.main()
