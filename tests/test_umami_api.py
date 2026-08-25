#!/usr/bin/env python3
"""Tests for bin/umami-api.

Unit tests exercise read_capped() and validate_host() directly. Integration
tests spin up real local HTTP servers and drive the actual bin/umami-api
subprocess through its real stdin/stdout/exit-code protocol — not mocks —
matching the precedent set by Keeply's own review-driven test suite
(HANCORE-linux/omarchy-plugin-marketplace#1750).
"""

import http.server
import importlib.machinery
import importlib.util
import json
import os
import socket
import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
API_SCRIPT = REPO_ROOT / "bin" / "umami-api"


def load_api_module():
    # bin/umami-api has no .py extension, so importlib can't infer a loader
    # from the file suffix alone — an explicit SourceFileLoader is required.
    loader = importlib.machinery.SourceFileLoader("umami_api", str(API_SCRIPT))
    spec = importlib.util.spec_from_loader("umami_api", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


umami_api = load_api_module()


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class FakeResponse:
    """Minimal stand-in for http.client.HTTPResponse's read(n) behavior."""

    def __init__(self, chunks):
        self._chunks = list(chunks)

    def read(self, n=-1):
        if not self._chunks:
            return b""
        return self._chunks.pop(0)


class ReadCappedTests(unittest.TestCase):
    def test_under_cap(self):
        resp = FakeResponse([b"hello", b""])
        data = umami_api.read_capped(resp, 100, time.monotonic() + 5)
        self.assertEqual(data, b"hello")

    def test_exactly_at_cap(self):
        resp = FakeResponse([b"x" * 10, b""])
        data = umami_api.read_capped(resp, 10, time.monotonic() + 5)
        self.assertEqual(len(data), 10)

    def test_over_cap_single_chunk(self):
        resp = FakeResponse([b"x" * 11])
        with self.assertRaises(ValueError):
            umami_api.read_capped(resp, 10, time.monotonic() + 5)

    def test_over_cap_spanning_chunks(self):
        # 6 + 6 = 12 > 10: only trips once accumulated across two reads.
        resp = FakeResponse([b"x" * 6, b"x" * 6, b""])
        with self.assertRaises(ValueError):
            umami_api.read_capped(resp, 10, time.monotonic() + 5)

    def test_deadline_already_passed(self):
        resp = FakeResponse([b"x", b"y", b"z"])
        with self.assertRaises(TimeoutError):
            umami_api.read_capped(resp, 1000, time.monotonic() - 1)


class ValidateHostTests(unittest.TestCase):
    def test_accepts_https(self):
        self.assertEqual(umami_api.validate_host("https://example.com"), "https://example.com")

    def test_accepts_http_with_port(self):
        self.assertEqual(umami_api.validate_host("http://example.com:3000"), "http://example.com:3000")

    def test_rejects_other_scheme(self):
        with self.assertRaises(RuntimeError):
            umami_api.validate_host("ftp://example.com")

    def test_rejects_embedded_userinfo(self):
        with self.assertRaises(RuntimeError):
            umami_api.validate_host("https://user:pass@example.com")


class _RecordingHandler(http.server.BaseHTTPRequestHandler):
    """Base handler that records every request it receives on the class."""

    received = []

    def log_message(self, *args):
        pass

    def _record(self):
        body_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(body_length) if body_length else b""
        type(self).received.append({
            "path": self.path,
            "headers": dict(self.headers),
            "body": body,
        })
        return body

    def do_GET(self):
        self._record()
        self.respond()

    def do_POST(self):
        self._record()
        self.respond()

    def respond(self):
        raise NotImplementedError


def run_server(handler_cls):
    port = free_port()
    server = http.server.HTTPServer(("127.0.0.1", port), handler_cls)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread, port


def call_api(payload, env_overrides=None, timeout=10):
    env = dict(os.environ)
    if env_overrides:
        env.update(env_overrides)
    result = subprocess.run(
        [sys.executable, str(API_SCRIPT)],
        input=json.dumps(payload).encode("utf-8") + b"\n",
        capture_output=True,
        timeout=timeout,
        env=env,
    )
    return result


class SuccessTests(unittest.TestCase):
    def test_normal_success(self):
        class Handler(_RecordingHandler):
            def respond(self):
                body = json.dumps({"ok": True, "count": 3}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server, thread, port = run_server(Handler)
        try:
            result = call_api({
                "method": "GET", "path": "/api/websites",
                "host": f"http://127.0.0.1:{port}", "token": "tok123", "body": None,
            })
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {"ok": True, "count": 3})
        finally:
            server.shutdown()
            server.server_close()

    def test_auth_header_and_post_body_reach_server(self):
        received = []

        class Handler(_RecordingHandler):
            def respond(self):
                received.append(self.headers.get("Authorization"))
                body = b"{}"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server, thread, port = run_server(Handler)
        try:
            result = call_api({
                "method": "POST", "path": "/api/auth/login",
                "host": f"http://127.0.0.1:{port}", "token": "abc",
                "body": {"username": "u", "password": "p"},
            })
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(received, ["Bearer abc"])
            sent_body = json.loads(Handler.received[-1]["body"])
            self.assertEqual(sent_body, {"username": "u", "password": "p"})
        finally:
            server.shutdown()
            server.server_close()


class RedirectTests(unittest.TestCase):
    def test_redirect_is_refused_and_target_never_hit(self):
        class TargetHandler(_RecordingHandler):
            received = []
            def respond(self):
                body = b'{"leaked": true}'
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        target_server, target_thread, target_port = run_server(TargetHandler)

        class RedirectHandler(_RecordingHandler):
            def respond(self):
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{target_port}/steal")
                self.send_header("Content-Length", "0")
                self.end_headers()

        redirect_server, redirect_thread, redirect_port = run_server(RedirectHandler)
        try:
            result = call_api({
                "method": "GET", "path": "/api/websites",
                "host": f"http://127.0.0.1:{redirect_port}", "token": "secret-token", "body": None,
            })
            self.assertEqual(result.returncode, 3)
            self.assertIn(b"http_status:302", result.stderr)
            self.assertEqual(TargetHandler.received, [], "redirect target must never receive a request")
        finally:
            redirect_server.shutdown()
            redirect_server.server_close()
            target_server.shutdown()
            target_server.server_close()


class HttpErrorTests(unittest.TestCase):
    def test_401_maps_to_exit_3_with_status_in_stderr(self):
        class Handler(_RecordingHandler):
            def respond(self):
                body = b'{"error": "unauthorized"}'
                self.send_response(401)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server, thread, port = run_server(Handler)
        try:
            result = call_api({
                "method": "GET", "path": "/api/websites",
                "host": f"http://127.0.0.1:{port}", "token": "stale", "body": None,
            })
            self.assertEqual(result.returncode, 3)
            self.assertEqual(result.stderr.strip(), b"http_status:401")
        finally:
            server.shutdown()
            server.server_close()


class SizeAndTimeoutTests(unittest.TestCase):
    def test_oversized_response_is_rejected(self):
        class Handler(_RecordingHandler):
            def respond(self):
                body = b"x" * 4096
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server, thread, port = run_server(Handler)
        try:
            result = call_api(
                {"method": "GET", "path": "/x", "host": f"http://127.0.0.1:{port}", "token": None, "body": None},
                env_overrides={"UMAMI_API_MAX_RESPONSE_BYTES": "1024"},
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"too large", result.stderr.lower())
        finally:
            server.shutdown()
            server.server_close()

    def test_drip_fed_response_hits_wall_clock_deadline(self):
        # Sends one byte every 0.4s — 20 bytes takes ~8s to fully arrive if
        # nothing bounds it, comfortably under a 1-second per-socket idle
        # timeout at every step (so that timeout alone never fires). Only
        # read_capped()'s one-byte-at-a-time read size lets the wall-clock
        # deadline check actually regain control between bytes; a naive
        # large read size would block for the whole drip regardless (this
        # was caught empirically while writing this test).
        class Handler(_RecordingHandler):
            def respond(self):
                self.send_response(200)
                self.send_header("Content-Length", "20")
                self.end_headers()
                try:
                    for _ in range(20):
                        self.wfile.write(b"x")
                        self.wfile.flush()
                        time.sleep(0.4)
                except BrokenPipeError:
                    pass  # expected: the client correctly disconnects mid-drip

        server, thread, port = run_server(Handler)
        try:
            start = time.monotonic()
            result = call_api(
                {"method": "GET", "path": "/x", "host": f"http://127.0.0.1:{port}", "token": None, "body": None},
                env_overrides={"UMAMI_API_TOTAL_TIMEOUT": "1", "UMAMI_API_SOCKET_TIMEOUT": "5"},
                timeout=15,
            )
            elapsed = time.monotonic() - start
            self.assertEqual(result.returncode, 4)
            self.assertIn(b"time limit", result.stderr)
            self.assertLess(elapsed, 2.5, "the deadline should fire close to the 1s budget, not near the ~8s drip total")
        finally:
            server.shutdown()
            server.server_close()

    def test_unreachable_host_fails_cleanly(self):
        port = free_port()  # nothing is listening here
        result = call_api({
            "method": "GET", "path": "/x", "host": f"http://127.0.0.1:{port}", "token": None, "body": None,
        })
        self.assertEqual(result.returncode, 4)


class BadRequestTests(unittest.TestCase):
    def test_invalid_stdin_json(self):
        result = subprocess.run(
            [sys.executable, str(API_SCRIPT)], input=b"not json\n", capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 4)

    def test_unsupported_method(self):
        result = call_api({"method": "DELETE", "path": "/x", "host": "https://example.com", "token": None, "body": None})
        self.assertEqual(result.returncode, 4)


if __name__ == "__main__":
    unittest.main()
