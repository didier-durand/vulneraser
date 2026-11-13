#!/usr/bin/env python3
"""pi_rpc.py — client for the pi-rpc Docker container.

Connects to a Pi agent running in RPC mode (JSONL over TCP) inside the
Docker container built from Dockerfile_pi_rpc, sends a prompt, and prints
the streamed assistant response.

Usage:
    python3 pi_rpc.py "Your prompt here"
    python3 pi_rpc.py --host 127.0.0.1 --port 9471 "Your prompt here"
    python3 pi_rpc.py --json "Your prompt here"   # print raw JSONL events

Environment:
    PI_RPC_HOST   host (default 127.0.0.1)
    PI_RPC_PORT   port (default 9471)

Protocol: https://pi.dev/docs/rpc  (RPC mode)
"""

import argparse
import json
import os
import socket
import sys
from typing import Optional


def read_lines(sock: socket.socket):
    """Yield complete LF-terminated lines from a socket without treating
    Unicode line/paragraph separators (U+2028, U+2029) as record boundaries."""
    buf = bytearray()
    while True:
        try:
            chunk = sock.recv(65536)
        except ConnectionResetError:
            break
        if not chunk:
            if buf:
                yield bytes(buf)
            return
        buf.extend(chunk)
        while True:
            idx = buf.find(b"\n")
            if idx < 0:
                break
            line = bytes(buf[:idx])
            del buf[: idx + 1]
            if line.endswith(b"\r"):
                line = line[:-1]
            yield line


def send_command(sock: socket.socket, command: dict) -> None:
    data = (json.dumps(command) + "\n").encode("utf-8")
    sock.sendall(data)


def prompt(
    sock: socket.socket,
    message: str,
    cmd_id: str = "prompt-1",
    raw: bool = False,
    timeout: Optional[float] = None,
) -> str:
    """Send a prompt command and stream the assistant response until settled.

    Returns the concatenated assistant text deltas.
    """
    if timeout is not None:
        sock.settimeout(timeout)

    send_command(sock, {"id": cmd_id, "type": "prompt", "message": message})

    collected = []
    saw_response = False

    for line in read_lines(sock):
        if not line:
            continue
        try:
            record = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            print(f"[warn] could not parse line: {exc}", file=sys.stderr)
            continue

        rtype = record.get("type")

        if raw:
            print(json.dumps(record))

        # Correlate the prompt command response.
        if rtype == "response" and record.get("id") == cmd_id:
            saw_response = True
            if not record.get("success"):
                err = record.get("error", "unknown error")
                print(f"[error] prompt rejected: {err}", file=sys.stderr)
                return ""
            disp = record.get("data", {}).get("disposition")
            if disp == "handled":
                # Extension/handler consumed it; no run will start.
                return ""
            continue

        # Stream assistant text deltas.
        if rtype == "message_update":
            event = record.get("assistantMessageEvent", {})
            if event.get("type") == "text_delta":
                delta = event.get("delta", "")
                collected.append(delta)
                if not raw:
                    sys.stdout.write(delta)
                    sys.stdout.flush()

        # End of the full agent run cycle.
        elif rtype == "agent_settled":
            if not raw:
                print()  # newline after streamed text
            break

        elif rtype == "agent_end":
            # A single low-level run ended; keep reading until agent_settled.
            continue

    if not saw_response:
        print("[warn] no prompt response received before stream ended",
              file=sys.stderr)

    return "".join(collected)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Send a prompt to a Pi agent running in RPC mode (TCP).",
    )
    parser.add_argument("message", help="The prompt to send to the agent.")
    parser.add_argument("--host", default=os.environ.get("PI_RPC_HOST", "127.0.0.1"),
                        help="Container host (default 127.0.0.1)")
    parser.add_argument("--port", type=int,
                        default=int(os.environ.get("PI_RPC_PORT", "9471")),
                        help="Container RPC port (default 9471)")
    parser.add_argument("--json", action="store_true",
                        help="Print raw JSONL events instead of plain text.")
    parser.add_argument("--timeout", type=float, default=None,
                        help="Socket timeout in seconds (optional).")
    parser.add_argument("--id", default="prompt-1",
                        help="Command ID for correlation (default prompt-1).")
    args = parser.parse_args()

    try:
        sock = socket.create_connection((args.host, args.port), timeout=10)
    except OSError as exc:
        print(f"[error] cannot connect to {args.host}:{args.port}: {exc}",
              file=sys.stderr)
        print("        Is the pi-rpc container running? "
              "Start it with:", file=sys.stderr)
        print("        docker run --rm -p 9471:9471 -e OPENAI_API_KEY=... pi-rpc",
              file=sys.stderr)
        return 1

    try:
        text = prompt(sock, args.message, cmd_id=args.id, raw=args.json,
                      timeout=args.timeout)
        if not args.json and not text:
            print("[info] no assistant text was produced.", file=sys.stderr)
    finally:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
