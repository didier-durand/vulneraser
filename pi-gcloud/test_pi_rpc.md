# Testing Pi RPC — `test_pi_rpc.py`

Comprehensive test suite for the `pi-rpc` Docker image (`Dockerfile_pi_rpc`) and the Python client (`pi_rpc.py`).

---

## Prerequisites

| Requirement | Details |
|---|---|
| Docker | Running daemon with BuildKit |
| Python | 3.8+ |
| pytest | Installed in a virtualenv or globally |
| Provider API key | Set in the environment (e.g. `OPENAI_API_KEY`) |
| `pi-rpc` image | Built from `Dockerfile_pi_rpc` |

### Build the image (if not already built)

```bash
docker build -f Dockerfile_pi_rpc -t pi-rpc .
```

### Install pytest

```bash
python3 -m venv .venv
.venv/bin/pip install pytest
```

---

## Quick start

```bash
export OPENAI_API_KEY=sk-...   # or another provider key

.venv/bin/pytest test_pi_rpc.py -v
```

Expected result:

```
======================== 48 passed in ~80s ========================
```

---

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `OPENAI_API_KEY` | — | OpenAI API key (or `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY`, `GEMINI_API_KEY`) |
| `PI_RPC_TEST_IMAGE` | `pi-rpc` | Docker image name to test |
| `PI_RPC_TEST_PORT` | `9472` | Host port to publish (avoids conflicts with a manually-run container on 9471) |

The suite auto-detects the first available provider key from the environment and passes it into the container.

---

## Test classes

### `TestImage` (8 tests)

Validates the built Docker image without running the agent.

| Test | What it checks |
|---|---|
| `test_image_exists` | Image is present |
| `test_image_has_pi_installed` | `pi --version` runs inside the image |
| `test_image_has_socat` | `socat` binary is on the PATH |
| `test_image_has_git` | `git` is installed (required by Pi tools) |
| `test_image_has_ripgrep` | `rg` is installed (required by Pi tools) |
| `test_image_exposes_port` | `9471/tcp` is in `ExposedPorts` |
| `test_image_entrypoint_is_socat` | Entrypoint is `socat TCP-LISTEN:9471,...` |
| `test_image_workdir_is_workspace` | `WorkingDir` is `/workspace` |

### `TestContainer` (3 tests)

Validates the running container accepts connections.

| Test | What it checks |
|---|---|
| `test_container_starts_and_listens` | Container is running and port is reachable |
| `test_port_accepts_connection` | TCP connection succeeds |
| `test_socat_forks_per_connection` | Three simultaneous connections each get a response |

### `TestClientFunctional` (11 tests)

End-to-end tests driving `pi_rpc.py` against the live container with an LLM.

| Test | What it checks |
|---|---|
| `test_basic_prompt_returns_text` | A simple prompt returns the expected text |
| `test_short_answer` | Factual answer (`2+2 → 4`) |
| `test_json_mode_emits_jsonl` | `--json` outputs valid JSONL lines |
| `test_json_mode_contains_prompt_response` | JSON includes the correlated prompt response |
| `test_json_mode_contains_agent_settled` | JSON includes `agent_settled` |
| `test_json_mode_contains_text_delta` | JSON includes `text_delta` events |
| `test_custom_command_id` | `--id` is echoed back in the response |
| `test_tool_use_bash` | Pi uses the `bash` tool inside the container |
| `test_unicode_prompt` | Unicode characters survive the round trip |
| `test_long_prompt` | A 2000+ character prompt is handled |
| `test_multiline_prompt` | Newlines within the prompt are accepted |

### `TestSessionIsolation` (1 test)

Validates that each TCP connection gets a fresh ephemeral session (`--no-session`).

| Test | What it checks |
|---|---|
| `test_two_connections_are_independent` | A secret told in connection 1 is not remembered in connection 2 |

### `TestProtocol` (6 tests)

Speaks the JSONL protocol directly over a raw TCP socket.

| Test | What it checks |
|---|---|
| `test_prompt_command_returns_response` | `prompt` command yields a `response` with `success: true` |
| `test_get_state_command` | `get_state` returns session data |
| `test_invalid_json_returns_parse_error` | Malformed JSON yields a `parse` error response |
| `test_response_id_matches_command_id` | Response `id` correlates with the command `id` |
| `test_agent_settled_present` | `agent_settled` event is emitted after a run |
| `test_text_deltas_form_coherent_text` | Concatenated `text_delta` events form the full answer |

### `TestCLI` (6 tests)

Tests the client's command-line interface and error handling.

| Test | What it checks |
|---|---|
| `test_help_flag` | `--help` prints usage and exits 0 |
| `test_missing_message_argument` | Missing positional arg exits non-zero |
| `test_connection_refused` | Unreachable port exits 1 with a clear error |
| `test_invalid_host` | Invalid IP address exits 1 |
| `test_env_var_host_and_port` | `PI_RPC_HOST` / `PI_RPC_PORT` env vars are honored |
| `test_cli_timeout_does_not_crash` | `--timeout 120` doesn't crash the client |

### `TestEdgeCases` (13 tests)

Boundary and unusual-input tests.

| Test | What it checks |
|---|---|
| `test_empty_string_prompt` | Empty message doesn't crash the client |
| `test_single_character_prompt` | One-character prompt works |
| `test_whitespace_only_prompt` | Whitespace-only prompt doesn't crash |
| `test_prompt_with_quotes_and_special_chars` | Quotes, `{}`, `<>`, `&` are handled |
| `test_prompt_with_newlines_and_tabs` | `\n` and `\t` inside the prompt are accepted |
| `test_emoji_in_prompt` | Emoji (`🚀`) survive the round trip |
| `test_unicode_line_separator_in_prompt` | U+2028 doesn't break JSONL framing |
| `test_very_long_single_word` | A 500-character word is accepted |
| `test_rapid_sequential_connections` | Five back-to-back connections all succeed |
| `test_concurrent_connections` | Three simultaneous connections all succeed |
| `test_connection_close_without_prompt` | Open-and-close doesn't crash the container |
| `test_partial_json_then_close` | Partial JSON then close doesn't crash the container |
| `test_multiple_prompts_one_connection` | Two prompts on one connection are both acknowledged |

---

## Running specific tests

### Run a single class

```bash
.venv/bin/pytest test_pi_rpc.py::TestImage -v
```

### Run a single test

```bash
.venv/bin/pytest test_pi_rpc.py::TestEdgeCases::test_emoji_in_prompt -v
```

### Run by keyword

```bash
.venv/bin/pytest test_pi_rpc.py -v -k "json"
```

### Stop on first failure

```bash
.venv/bin/pytest test_pi_rpc.py -v -x
```

### Show full tracebacks

```bash
.venv/bin/pytest test_pi_rpc.py -v --tb=long
```

### Run without capturing output (see live streaming)

```bash
.venv/bin/pytest test_pi_rpc.py -v -s
```

---

## What the suite does automatically

1. Checks that the `pi-rpc` image exists (skips if not built).
2. Checks that a provider API key is set in the environment (skips if absent).
3. Starts a container named `pi-rpc-test` on the configured port (default `9472`).
4. Waits for the port to become reachable.
5. Runs all 48 tests against the container.
6. Removes the container after the suite finishes.

---

## Troubleshooting

### Tests are skipped

```
Skipped: Docker image 'pi-rpc' not built.
```

Build the image:

```bash
docker build -f Dockerfile_pi_rpc -t pi-rpc .
```

```
Skipped: No provider API key set in environment
```

Export a provider key:

```bash
export OPENAI_API_KEY=sk-...
```

### Port conflict

If port `9472` is already in use, set a different one:

```bash
PI_RPC_TEST_PORT=9473 .venv/bin/pytest test_pi_rpc.py -v
```

### Leftover container

If a previous run left a container behind, remove it:

```bash
docker rm -f pi-rpc-test
```

### Tests hang or time out

- Ensure Docker has enough resources (CPU/memory).
- Verify the API key is valid and the provider is reachable.
- Increase the timeout: the suite uses 120s per LLM-backed test internally. For slow providers, run fewer tests in parallel:

```bash
.venv/bin/pytest test_pi_rpc.py -v -p no:randomly --timeout 300
```

### `internal_logging.go` warnings on stderr

Lines like these are harmless telemetry noise from the host's OpenTelemetry collector, not from the tests or container:

```
"msg"="parse url" "error"="parse \"127.0.0.1:4317\"..."
```

---

## Test file

| File | Lines | Tests |
|---|---|---|
| `test_pi_rpc.py` | ~480 | 48 |

The suite uses only the Python standard library plus `pytest`. No other dependencies are required.
