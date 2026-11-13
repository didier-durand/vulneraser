#!/usr/bin/env python3
"""test_pi_rpc.py — test suite for the pi-rpc container image and pi_rpc.py client.

Covers the container image (Dockerfile_pi_rpc) and the Python client (pi_rpc.py)
including functional, protocol, CLI, and edge-case tests.

Requirements:
    - pytest
    - Docker daemon running
    - The `pi-rpc` image built:  docker build -f Dockerfile_pi_rpc -t pi-rpc .
    - A provider API key available in the environment (e.g. OPENAI_API_KEY)

Run:
    pytest test_pi_rpc.py -v

Environment:
    PI_RPC_TEST_IMAGE   image name (default pi-rpc)
    PI_RPC_TEST_PORT    host port to publish (default 9472)
    OPENAI_API_KEY      (or another provider key) must be set
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
from typing import Optional

import pytest

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

IMAGE = os.environ.get("PI_RPC_TEST_IMAGE", "pi-rpc")
HOST_PORT = int(os.environ.get("PI_RPC_TEST_PORT", "9472"))
HOST = "127.0.0.1"
PORT = HOST_PORT
CLIENT = os.path.join(os.path.dirname(__file__), "pi_rpc.py")

# Provider key — fall back to any common provider env var.
API_KEY_ENV = (
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "OPENROUTER_API_KEY",
    "DEEPSEEK_API_KEY",
    "GEMINI_API_KEY",
)
API_KEY = next((os.environ.get(k) for k in API_KEY_ENV if os.environ.get(k)), None)
PROVIDER_ENV_VAR = next((k for k in API_KEY_ENV if os.environ.get(k)), None)

CONTAINER_NAME = "pi-rpc-test"
LONG_TIMEOUT = 120  # seconds for LLM-backed tests
SHORT_TIMEOUT = 10  # seconds for connection-level tests


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _docker(args: list[str], timeout: Optional[float] = 60) -> subprocess.CompletedProcess:
    """Run a docker command and return the completed process."""
    return subprocess.run(
        ["docker", *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def _container_running() -> bool:
    r = _docker(["ps", "--filter", f"name={CONTAINER_NAME}", "--format", "{{.Names}}"])
    return CONTAINER_NAME in r.stdout


def _start_container() -> None:
    """Start the pi-rpc container if it isn't already running."""
    if _container_running():
        return
    _docker(["rm", "-f", CONTAINER_NAME], timeout=30)
    env_flag = []
    if PROVIDER_ENV_VAR and API_KEY:
        env_flag = ["-e", f"{PROVIDER_ENV_VAR}={API_KEY}"]
    r = _docker(
        ["run", "-d", "--name", CONTAINER_NAME, "-p", f"{HOST_PORT}:9471",
         *env_flag, IMAGE],
        timeout=60,
    )
    assert r.returncode == 0, f"docker run failed: {r.stderr}"
    _wait_for_port(HOST, PORT, timeout=30)


def _stop_container() -> None:
    _docker(["rm", "-f", CONTAINER_NAME], timeout=30)


def _wait_for_port(host: str, port: int, timeout: float = 30) -> None:
    """Poll until a TCP port accepts a connection."""
    deadline = time.time() + timeout
    last_err: Optional[Exception] = None
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=2):
                return
        except OSError as exc:
            last_err = exc
            time.sleep(0.5)
    raise AssertionError(f"port {host}:{port} not reachable: {last_err}")


def _run_client(
    message: str,
    *extra: str,
    host: str = HOST,
    port: int = PORT,
    timeout: Optional[float] = LONG_TIMEOUT,
) -> subprocess.CompletedProcess:
    """Invoke pi_rpc.py and return the completed process."""
    cmd = [sys.executable, CLIENT, "--host", host, "--port", str(port)]
    if timeout is not None:
        cmd += ["--timeout", str(timeout)]
    cmd += list(extra)
    cmd += ["--", message]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 30)


def _run_client_raw(message: str, *extra: str, **kw) -> subprocess.CompletedProcess:
    """Invoke pi_rpc.py with the message appended directly (no -- separator)."""
    cmd = [sys.executable, CLIENT, "--host", HOST, "--port", str(PORT)]
    if "timeout" in kw and kw["timeout"] is not None:
        cmd += ["--timeout", str(kw["timeout"])]
    cmd += list(extra)
    cmd += [message]
    t = kw.get("timeout", LONG_TIMEOUT)
    return subprocess.run(cmd, capture_output=True, text=True, timeout=t + 30)


def _connect() -> socket.socket:
    """Open a raw TCP socket to the container."""
    return socket.create_connection((HOST, PORT), timeout=10)


def _send_jsonl(sock: socket.socket, obj: dict) -> None:
    sock.sendall((json.dumps(obj) + "\n").encode("utf-8"))


def _read_jsonl(sock: socket.socket, timeout: float = LONG_TIMEOUT) -> list[dict]:
    """Read JSONL records until the socket closes or agent_settled is seen."""
    sock.settimeout(timeout)
    records: list[dict] = []
    buf = bytearray()
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        buf.extend(chunk)
        while True:
            idx = buf.find(b"\n")
            if idx < 0:
                break
            line = bytes(buf[:idx])
            del buf[: idx + 1]
            if line.endswith(b"\r"):
                line = line[:-1]
            try:
                rec = json.loads(line.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            records.append(rec)
            if rec.get("type") == "agent_settled":
                return records
    return records


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def container():
    """Start the pi-rpc container once for the whole module."""
    if not API_KEY:
        pytest.skip("No provider API key set in environment")
    _start_container()
    yield
    _stop_container()


@pytest.fixture(scope="module")
def image_built():
    """Ensure the pi-rpc image exists."""
    r = _docker(["image", "inspect", IMAGE], timeout=30)
    if r.returncode != 0:
        pytest.skip(f"Docker image '{IMAGE}' not built. Run: docker build -f Dockerfile_pi_rpc -t {IMAGE} .")


# ---------------------------------------------------------------------------
# Image tests
# ---------------------------------------------------------------------------

class TestImage:
    """Tests that inspect the built image without running the agent."""

    def test_image_exists(self, image_built):
        assert image_built is None  # fixture would skip otherwise

    def test_image_has_pi_installed(self, image_built):
        r = _docker(["run", "--rm", "--entrypoint", "pi", IMAGE, "--version"])
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip()  # should print a version string

    def test_image_has_socat(self, image_built):
        r = _docker(["run", "--rm", "--entrypoint", "which", IMAGE, "socat"])
        assert r.returncode == 0, r.stderr
        assert "socat" in r.stdout

    def test_image_has_git(self, image_built):
        r = _docker(["run", "--rm", "--entrypoint", "bash", IMAGE, "-c", "git --version"])
        assert r.returncode == 0, r.stderr
        assert "git version" in r.stdout

    def test_image_has_ripgrep(self, image_built):
        r = _docker(["run", "--rm", "--entrypoint", "bash", IMAGE, "-c", "rg --version"])
        assert r.returncode == 0, r.stderr
        assert "ripgrep" in r.stdout.lower()

    def test_image_exposes_port(self, image_built):
        r = _docker(["inspect", IMAGE, "--format", "{{json .Config.ExposedPorts}}"])
        assert r.returncode == 0, r.stderr
        ports = json.loads(r.stdout)
        assert "9471/tcp" in ports

    def test_image_entrypoint_is_socat(self, image_built):
        r = _docker(["inspect", IMAGE, "--format", "{{json .Config.Entrypoint}}"])
        assert r.returncode == 0, r.stderr
        entrypoint = json.loads(r.stdout)
        assert "socat" in entrypoint
        assert "TCP-LISTEN:9471" in " ".join(entrypoint)

    def test_image_workdir_is_workspace(self, image_built):
        r = _docker(["inspect", IMAGE, "--format", "{{.Config.WorkingDir}}"])
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "/workspace"


# ---------------------------------------------------------------------------
# Container / connectivity tests
# ---------------------------------------------------------------------------

class TestContainer:
    """Tests that the container starts and listens on the expected port."""

    def test_container_starts_and_listens(self, container):
        assert _container_running()
        _wait_for_port(HOST, PORT, timeout=10)

    def test_port_accepts_connection(self, container):
        with _connect() as sock:
            assert sock.fileno() > 0

    def test_socat_forks_per_connection(self, container):
        """Each TCP connection should get its own pi subprocess."""
        sockets = []
        try:
            for _ in range(3):
                s = _connect()
                sockets.append(s)
            # All three should be open simultaneously.
            for s in sockets:
                s.sendall(b'{"id":"ping","type":"get_state"}\n')
            time.sleep(1)
            for s in sockets:
                data = s.recv(65536)
                assert data  # should have received something
        finally:
            for s in sockets:
                s.close()


# ---------------------------------------------------------------------------
# Functional client tests
# ---------------------------------------------------------------------------

class TestClientFunctional:
    """End-to-end tests driving pi_rpc.py against the live container."""

    def test_basic_prompt_returns_text(self, container):
        r = _run_client("Reply with exactly: hello world")
        assert r.returncode == 0, r.stderr
        assert "hello world" in r.stdout.lower()

    def test_short_answer(self, container):
        r = _run_client("What is 2+2? Answer with just the number.")
        assert r.returncode == 0, r.stderr
        assert "4" in r.stdout

    def test_json_mode_emits_jsonl(self, container):
        r = _run_client("Say hi", "--json")
        assert r.returncode == 0, r.stderr
        lines = [l for l in r.stdout.strip().splitlines() if l.strip()]
        assert len(lines) >= 2  # at least response + agent_settled
        for line in lines:
            obj = json.loads(line)  # must be valid JSON
            assert isinstance(obj, dict)

    def test_json_mode_contains_prompt_response(self, container):
        r = _run_client("Hello", "--json", "--id", "test-json-1")
        assert r.returncode == 0, r.stderr
        found = False
        for line in r.stdout.strip().splitlines():
            obj = json.loads(line)
            if obj.get("type") == "response" and obj.get("id") == "test-json-1":
                found = True
                assert obj["command"] == "prompt"
                assert obj["success"] is True
                break
        assert found, "prompt response not found in JSON output"

    def test_json_mode_contains_agent_settled(self, container):
        r = _run_client("Hi", "--json")
        assert r.returncode == 0, r.stderr
        types = [json.loads(l).get("type") for l in r.stdout.strip().splitlines() if l]
        assert "agent_settled" in types

    def test_json_mode_contains_text_delta(self, container):
        r = _run_client("Say the word banana", "--json")
        assert r.returncode == 0, r.stderr
        found_delta = False
        for line in r.stdout.strip().splitlines():
            obj = json.loads(line)
            if obj.get("type") == "message_update":
                ev = obj.get("assistantMessageEvent", {})
                if ev.get("type") == "text_delta":
                    found_delta = True
                    break
        assert found_delta, "no text_delta event in JSON output"

    def test_custom_command_id(self, container):
        custom_id = "my-custom-id-42"
        r = _run_client("Hi", "--json", "--id", custom_id)
        assert r.returncode == 0, r.stderr
        found = False
        for line in r.stdout.strip().splitlines():
            obj = json.loads(line)
            if obj.get("type") == "response" and obj.get("id") == custom_id:
                found = True
                break
        assert found, f"custom command id '{custom_id}' not found in response"

    def test_tool_use_bash(self, container):
        """Pi should be able to use the bash tool inside the container."""
        r = _run_client(
            "Use the bash tool to run: echo TOOL_TEST_OK_12345. "
            "Then tell me exactly what it printed."
        )
        assert r.returncode == 0, r.stderr
        assert "TOOL_TEST_OK_12345" in r.stdout

    def test_unicode_prompt(self, container):
        r = _run_client("Say 'héllo wörld' back to me exactly.")
        assert r.returncode == 0, r.stderr
        # The response should contain the unicode echo.
        assert "héllo" in r.stdout or "hello" in r.stdout.lower()

    def test_long_prompt(self, container):
        long_text = "This is a test sentence. " * 100
        r = _run_client(f"Repeat back the first 5 words of this: {long_text}")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip()  # should produce some output

    def test_multiline_prompt(self, container):
        prompt = "Line one.\nLine two.\nLine three.\nRespond with 'ok'."
        r = _run_client(prompt)
        assert r.returncode == 0, r.stderr
        assert "ok" in r.stdout.lower()


# ---------------------------------------------------------------------------
# Session isolation tests
# ---------------------------------------------------------------------------

class TestSessionIsolation:
    """Each TCP connection gets a fresh ephemeral session (--no-session)."""

    def test_two_connections_are_independent(self, container):
        r1 = _run_client("Remember the secret code BANANA_7. Just say 'got it'.")
        assert r1.returncode == 0, r1.stderr
        assert "got it" in r1.stdout.lower()

        r2 = _run_client("What secret code did I tell you? If none, say 'no code'.")
        assert r2.returncode == 0, r2.stderr
        # The second connection should NOT remember the code.
        assert "BANANA_7" not in r2.stdout


# ---------------------------------------------------------------------------
# Protocol-level tests (raw socket)
# ---------------------------------------------------------------------------

class TestProtocol:
    """Tests that speak the JSONL protocol directly over a raw socket."""

    def test_prompt_command_returns_response(self, container):
        with _connect() as sock:
            _send_jsonl(sock, {"id": "proto-1", "type": "prompt",
                               "message": "Reply with: proto-ok"})
            records = _read_jsonl(sock)
        responses = [r for r in records if r.get("type") == "response"
                     and r.get("id") == "proto-1"]
        assert len(responses) == 1
        assert responses[0]["command"] == "prompt"
        assert responses[0]["success"] is True
        assert responses[0]["data"]["disposition"] in ("started", "handled")

    def test_get_state_command(self, container):
        with _connect() as sock:
            _send_jsonl(sock, {"id": "state-1", "type": "get_state"})
            records = _read_jsonl(sock, timeout=10)
        # get_state responds immediately; we may not get agent_settled.
        # Look for the response record.
        responses = [r for r in records if r.get("type") == "response"
                     and r.get("id") == "state-1"]
        if not responses:
            # Read more — get_state may close without agent_settled.
            with _connect() as sock:
                _send_jsonl(sock, {"id": "state-2", "type": "get_state"})
                sock.settimeout(10)
                buf = b""
                while True:
                    chunk = sock.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
                    if b'"id": "state-2"' in buf or b'"id":"state-2"' in buf:
                        break
                for line in buf.split(b"\n"):
                    if not line.strip():
                        continue
                    rec = json.loads(line.decode("utf-8"))
                    if rec.get("type") == "response" and rec.get("id") == "state-2":
                        responses.append(rec)
                        break
        assert len(responses) >= 1
        assert responses[0]["success"] is True
        assert "data" in responses[0]

    def test_invalid_json_returns_parse_error(self, container):
        with _connect() as sock:
            sock.sendall(b"this is not json\n")
            sock.settimeout(10)
            buf = b""
            try:
                while True:
                    chunk = sock.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
                    if b"parse" in buf or b"error" in buf:
                        break
            except socket.timeout:
                pass
        # Pi should return a parse error response (no id).
        assert buf, "no response to invalid JSON"
        # Find the first JSON line.
        for line in buf.split(b"\n"):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line.decode("utf-8"))
                if rec.get("type") == "response" and rec.get("command") == "parse":
                    assert rec["success"] is False
                    return
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
        pytest.fail("no parse error response for invalid JSON")

    def test_response_id_matches_command_id(self, container):
        test_id = "correlation-test-99"
        with _connect() as sock:
            _send_jsonl(sock, {"id": test_id, "type": "prompt",
                               "message": "Say 'correlated'"})
            records = _read_jsonl(sock)
        for rec in records:
            if rec.get("type") == "response":
                assert rec.get("id") == test_id
                break

    def test_agent_settled_present(self, container):
        with _connect() as sock:
            _send_jsonl(sock, {"id": "settle-1", "type": "prompt",
                               "message": "Say 'done'"})
            records = _read_jsonl(sock)
        types = [r.get("type") for r in records]
        assert "agent_settled" in types

    def test_text_deltas_form_coherent_text(self, container):
        with _connect() as sock:
            _send_jsonl(sock, {"id": "delta-1", "type": "prompt",
                               "message": "Reply with exactly: ABCDEF"})
            records = _read_jsonl(sock)
        deltas = []
        for rec in records:
            if rec.get("type") == "message_update":
                ev = rec.get("assistantMessageEvent", {})
                if ev.get("type") == "text_delta":
                    deltas.append(ev.get("delta", ""))
        combined = "".join(deltas)
        assert len(combined) > 0
        # The combined deltas should contain the target string.
        assert "ABCDEF" in combined or "abcdef" in combined.lower()


# ---------------------------------------------------------------------------
# CLI / error-handling tests
# ---------------------------------------------------------------------------

class TestCLI:
    """Tests for the client's command-line interface and error handling."""

    def test_help_flag(self):
        r = subprocess.run(
            [sys.executable, CLIENT, "--help"],
            capture_output=True, text=True, timeout=10,
        )
        assert r.returncode == 0
        assert "prompt" in r.stdout.lower() or "usage" in r.stdout.lower()

    def test_missing_message_argument(self):
        r = subprocess.run(
            [sys.executable, CLIENT, "--host", HOST, "--port", str(PORT)],
            capture_output=True, text=True, timeout=10,
        )
        assert r.returncode != 0
        # argparse prints usage error to stderr
        assert "error" in r.stderr.lower() or "usage" in r.stderr.lower()

    def test_connection_refused(self):
        # Use a port that's almost certainly not running the container.
        r = _run_client("hello", host="127.0.0.1", port=59999, timeout=5)
        assert r.returncode == 1
        assert "cannot connect" in r.stderr.lower()

    def test_invalid_host(self):
        r = _run_client("hello", host="256.256.256.256", port=PORT, timeout=5)
        assert r.returncode == 1
        assert "cannot connect" in r.stderr.lower()

    def test_env_var_host_and_port(self, container, monkeypatch):
        monkeypatch.setenv("PI_RPC_HOST", HOST)
        monkeypatch.setenv("PI_RPC_PORT", str(PORT))
        cmd = [sys.executable, CLIENT, "Say 'env-ok'"]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=LONG_TIMEOUT + 30)
        assert r.returncode == 0, r.stderr
        assert "env-ok" in r.stdout.lower()

    def test_cli_timeout_does_not_crash(self, container):
        """A generous timeout should not cause a crash."""
        r = _run_client("Say 'ok'", "--timeout", "120")
        assert r.returncode == 0, r.stderr


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

class TestEdgeCases:
    """Boundary and unusual-input tests."""

    def test_empty_string_prompt(self, container):
        """An empty message should not crash the client (Pi may reject)."""
        r = _run_client("")
        # Pi may reject or respond; the client should not hang or crash.
        assert r.returncode in (0, 1)

    def test_single_character_prompt(self, container):
        r = _run_client("Hi")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip()

    def test_whitespace_only_prompt(self, container):
        r = _run_client("   ")
        assert r.returncode in (0, 1)

    def test_prompt_with_quotes_and_special_chars(self, container):
        r = _run_client('Say: "hello {world}" & <tag> end.')
        assert r.returncode == 0, r.stderr

    def test_prompt_with_newlines_and_tabs(self, container):
        r = _run_client("Line1\nLine2\n\tIndented\nReply with 'ok'.")
        assert r.returncode == 0, r.stderr
        assert "ok" in r.stdout.lower()

    def test_emoji_in_prompt(self, container):
        r = _run_client("Say 🚀 back to me.")
        assert r.returncode == 0, r.stderr
        assert "🚀" in r.stdout or r.stdout.strip()

    def test_unicode_line_separator_in_prompt(self, container):
        """U+2028 (line separator) inside the prompt must not break framing."""
        msg = "Say 'unicode-ok'\u2028done."
        r = _run_client(msg)
        assert r.returncode == 0, r.stderr

    def test_very_long_single_word(self, container):
        long_word = "A" * 500
        r = _run_client(f"Repeat: {long_word}")
        assert r.returncode == 0, r.stderr

    def test_rapid_sequential_connections(self, container):
        """Five connections in a row should all succeed."""
        results = []
        for i in range(5):
            r = _run_client(f"Say the number {i}")
            results.append(r)
        for r in results:
            assert r.returncode == 0, r.stderr
            assert r.stdout.strip()

    def test_concurrent_connections(self, container):
        """Three simultaneous connections should all work."""
        import concurrent.futures

        def ask(n: int) -> subprocess.CompletedProcess:
            return _run_client(f"Say 'conn{n}'")

        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            futures = [pool.submit(ask, i) for i in range(3)]
            results = [f.result(timeout=LONG_TIMEOUT + 30) for f in futures]
        for r in results:
            assert r.returncode == 0, r.stderr

    def test_connection_close_without_prompt(self, container):
        """Opening and closing a connection without sending data should not crash."""
        with _connect() as sock:
            sock.close()  # immediate close
        # Container should still be alive.
        with _connect() as sock:
            sock.sendall(b'{"id":"health","type":"get_state"}\n')
            sock.settimeout(10)
            data = sock.recv(65536)
            assert data  # container still responds

    def test_partial_json_then_close(self, container):
        """Sending partial JSON then closing should not crash the container."""
        with _connect() as sock:
            sock.sendall(b'{"id":"partial","type":"prom')
            sock.close()
        # Container should survive.
        with _connect() as sock:
            sock.sendall(b'{"id":"after-partial","type":"get_state"}\n')
            sock.settimeout(10)
            data = sock.recv(65536)
            assert data

    def test_multiple_prompts_one_connection(self, container):
        """Send two prompts over a single connection before agent_settled.

        The second prompt should be queued or rejected, but the client/server
        should not crash.
        """
        with _connect() as sock:
            _send_jsonl(sock, {"id": "multi-1", "type": "prompt",
                               "message": "Say 'first'"})
            # Send second prompt immediately (before first settles).
            _send_jsonl(sock, {"id": "multi-2", "type": "prompt",
                               "message": "Say 'second'"})
            records = _read_jsonl(sock, timeout=LONG_TIMEOUT)
        # We should get responses for both IDs.
        ids = {r.get("id") for r in records if r.get("type") == "response"}
        assert "multi-1" in ids
        # The second may be queued or rejected, but we should see it.
        assert "multi-2" in ids
