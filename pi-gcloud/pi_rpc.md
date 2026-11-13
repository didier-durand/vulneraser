# Pi RPC — Docker Container & Python Client

Run the [Pi coding agent](https://pi.dev) in RPC mode inside a Docker container and drive it from a Python client over TCP.

Pi's [RPC mode](https://pi.dev/docs/rpc) is a JSONL protocol over stdin/stdout. The container wraps it with `socat` so each TCP connection spawns a fresh `pi --mode rpc` subprocess, making the RPC interface reachable over the network.

## Files

| File | Purpose |
|---|---|
| `Dockerfile_pi_rpc` | Builds the `pi-rpc` Docker image |
| `pi_rpc.py` | Python client that connects to the container and sends prompts |

---

## Prerequisites

- **Docker** (with BuildKit)
- **Python 3.8+** (for the client; standard library only — no pip install needed)
- An **LLM provider API key** (e.g. `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`)

---

## Build the image

```bash
docker build -f Dockerfile_pi_rpc -t pi-rpc .
```

### What's inside

| Component | Version / Purpose |
|---|---|
| Base image | `node:22-bookworm-slim` |
| Pi coding agent | `@earendil-works/pi-coding-agent` (latest from npm) |
| `git` | Required by Pi's built-in tools |
| `ripgrep` | Required by Pi's search tools |
| `socat` | Bridges TCP connections to Pi's JSONL stdin/stdout |
| Port | `9471` (TCP) |

The entrypoint runs:

```
socat TCP-LISTEN:9471,reuseaddr,fork EXEC:pi --mode rpc --no-session
```

Each incoming TCP connection spawns a fresh `pi --mode rpc --no-session` process. The socket is piped bidirectionally to Pi's stdin/stdout JSONL stream. No PTY is used, keeping the JSONL framing clean (no echo, no CR injection). Child stderr goes to `docker logs`, not the socket.

---

## Run the container

```bash
docker run --rm -p 9471:9471 -e OPENAI_API_KEY=sk-... pi-rpc
```

Replace `OPENAI_API_KEY` with the credential required by your provider:

| Provider | Environment variable |
|---|---|
| OpenAI | `OPENAI_API_KEY` |
| Anthropic | `ANTHROPIC_API_KEY` |
| OpenRouter | `OPENROUTER_API_KEY` |
| DeepSeek | `DEEPSEEK_API_KEY` |
| Google Gemini | `GEMINI_API_KEY` |

### Run in the background

```bash
docker run -d --name pi-rpc -p 9471:9471 -e OPENAI_API_KEY=sk-... pi-rpc
```

### Select a provider and model

Pi picks up the provider from the available API key. To select a specific model, pass `--model`:

```bash
docker run --rm -p 9471:9471 \
  -e OPENAI_API_KEY=sk-... \
  pi-rpc -- --model gpt-4o
```

### Mount a working directory

To let Pi read and edit files in a host directory, mount it at `/workspace`:

```bash
docker run --rm -p 9471:9471 \
  -e OPENAI_API_KEY=sk-... \
  -v "$PWD:/workspace" \
  pi-rpc
```

### Persist Pi configuration

Mount a named volume on `/root/.pi/agent` to keep settings, credentials, and sessions between container runs:

```bash
docker run --rm -p 9471:9471 \
  -e OPENAI_API_KEY=sk-... \
  -v pi-agent-home:/root/.pi/agent \
  pi-rpc
```

### View container logs

```bash
docker logs pi-rpc
```

Pi's stderr diagnostics appear here (not on the RPC socket).

### Stop the container

```bash
docker rm -f pi-rpc
```

---

## Use the Python client

```bash
python3 pi_rpc.py "Your prompt here"
```

### Options

```
usage: pi_rpc.py [-h] [--host HOST] [--port PORT] [--json] [--timeout SECONDS] [--id ID] message

positional:
  message           The prompt to send to the agent.

options:
  --host HOST       Container host (default 127.0.0.1, or PI_RPC_HOST env)
  --port PORT       Container RPC port (default 9471, or PI_RPC_PORT env)
  --json            Print raw JSONL events instead of plain text
  --timeout SECONDS Socket timeout in seconds (optional)
  --id ID           Command ID for correlation (default prompt-1)
  -h, --help        Show help
```

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `PI_RPC_HOST` | `127.0.0.1` | Container host |
| `PI_RPC_PORT` | `9471` | Container RPC port |

### Examples

```bash
# Basic prompt — streams the response as plain text
python3 pi_rpc.py "Explain what this repo does"

# From environment variables
export PI_RPC_HOST=127.0.0.1
export PI_RPC_PORT=9471
python3 pi_rpc.py "What is 2+2?"

# Raw JSONL event stream (for debugging or custom parsing)
python3 pi_rpc.py --json "Say hi in one word"

# With a timeout
python3 pi_rpc.py --timeout 120 "Review this code for bugs"

# Custom command ID (for multi-request correlation)
python3 pi_rpc.py --id req-001 "First prompt"
```

---

## How it works

```
┌──────────────┐     TCP 9471     ┌─────────────────────────────────┐
│  pi_rpc.py   │ ───────────────► │  socat (fork per connection)    │
│  (Python)    │                  │     │                           │
│              │ ◄─────────────── │     ▼                           │
│  reads JSONL │   JSONL stream   │  pi --mode rpc --no-session      │
│  prints text │                  │  (stdin/stdout JSONL protocol)   │
└──────────────┘                  └─────────────────────────────────┘
```

1. The client opens a TCP connection to the container on port 9471.
2. `socat` spawns a fresh `pi --mode rpc --no-session` subprocess for that connection.
3. The client sends a `prompt` command as one JSONL line.
4. Pi accepts the prompt and streams `message_update` events (text deltas) back as JSONL lines.
5. The client collects `text_delta` events and prints them live.
6. When Pi emits `agent_settled`, the client prints a final newline and closes the connection.
7. The `pi` subprocess exits; `socat` returns to listening for the next connection.

### RPC protocol

Pi's RPC mode uses strict JSONL framing — one JSON object per line, terminated by LF (`\n`). See the [RPC protocol docs](https://pi.dev/docs/rpc) and [RPC commands reference](https://pi.dev/docs/rpc-commands).

Key record types:

| Direction | Record | Purpose |
|---|---|---|
| Client → Pi | `{"type":"prompt","message":"..."}` | Send a prompt |
| Pi → Client | `{"type":"response","command":"prompt",...}` | Acknowledgement |
| Pi → Client | `{"type":"message_update",...}` | Streamed text deltas |
| Pi → Client | `{"type":"agent_settled"}` | Agent finished all work |

The client correlates the prompt response by command `id` and reads continuously until `agent_settled`.

---

## Session behavior

The container runs with `--no-session`, so each TCP connection is an **ephemeral session** — no conversation history persists between connections. This is ideal for stateless request/response use cases.

For persistent sessions, omit `--no-session` and mount a session directory:

```bash
docker run --rm -p 9471:9471 \
  -e OPENAI_API_KEY=sk-... \
  -v pi-sessions:/root/.pi/agent/sessions \
  pi-rpc
```

Then adjust the client to send multiple prompts over a single TCP connection (keeping the connection open between prompts).

---

## Troubleshooting

### Connection refused

```
[error] cannot connect to 127.0.0.1:9471: Connection refused
```

The container isn't running or the port isn't published. Start it with `-p 9471:9471`:

```bash
docker run -d --name pi-rpc -p 9471:9471 -e OPENAI_API_KEY=sk-... pi-rpc
```

### No assistant text produced

The provider may have rejected the prompt or no API key is set. Check the container logs:

```bash
docker logs pi-rpc
```

### Provider authentication errors

Pass the correct environment variable for your provider (see the table above). The key must be available inside the container, not just on the host.

### Unicode parsing errors

The client uses a binary LF splitter that does not treat U+2028 (line separator) or U+2029 (paragraph separator) as record boundaries — a known pitfall with generic line readers like Node.js `readline`. This is handled correctly in `pi_rpc.py`.

### Port already in use

```bash
docker run --rm -p 9472:9471 -e OPENAI_API_KEY=sk-... pi-rpc
python3 pi_rpc.py --port 9472 "Hello"
```

---

## Reference

- [Pi RPC mode docs](https://pi.dev/docs/rpc) — protocol overview
- [Pi RPC commands](https://pi.dev/docs/rpc-commands) — full command reference
- [Pi containerization](https://pi.dev/docs/containerization) — isolation options
- [Pi models & providers](https://pi.dev/docs/models) — configuration
- [Pi providers & auth](https://pi.dev/docs/providers) — API keys and login
