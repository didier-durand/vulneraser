# validate_pi_agent.sh — Validate the `pi-agent` Docker Image

A shell script that builds the `pi-agent` image from `Dockerfile_pi` and runs a series of automated checks to verify the image is correctly built and functional.

---

## Prerequisites

| Requirement | Details |
|---|---|
| Docker | Running daemon |
| `Dockerfile_pi` | Present in the repo root |
| Provider API key | Set in the environment (e.g. `OPENAI_API_KEY`) for LLM-backed tests |

The script auto-detects the first available provider key from the environment:

| Env var | Provider |
|---|---|
| `OPENAI_API_KEY` | OpenAI |
| `ANTHROPIC_API_KEY` | Anthropic |
| `OPENROUTER_API_KEY` | OpenRouter |
| `DEEPSEEK_API_KEY` | DeepSeek |
| `GEMINI_API_KEY` | Google Gemini |

---

## Usage

```bash
./validate_pi_agent.sh [options]
```

### Options

| Flag | Default | Purpose |
|---|---|---|
| `-i, --image <name>` | `pi-agent` | Docker image name to build and test |
| `-k, --api-key <key>` | env var | Provider API key (auto-detected from env if not set) |
| `-p, --provider <name>` | `openai` | Provider name (`openai`, `anthropic`, `openrouter`, `deepseek`, `google`) |
| `--no-build` | (off) | Skip the build step (image must already exist) |
| `--no-llm` | (off) | Skip LLM-backed tests (no API key needed) |
| `-h, --help` | — | Show help and exit |

---

## Examples

### Full validation (build + all tests)

```bash
export OPENAI_API_KEY=sk-...
./validate_pi_agent.sh
```

### Skip the build (image already built)

```bash
./validate_pi_agent.sh --no-build
```

### Skip LLM-backed tests (no API key needed)

```bash
./validate_pi_agent.sh --no-llm
```

### Custom image name

```bash
./validate_pi_agent.sh -i my-pi-agent
```

### Explicit API key and provider

```bash
./validate_pi_agent.sh -k sk-or-... -p openrouter
```

### Combine options

```bash
./validate_pi_agent.sh -i my-pi-agent --no-build -k sk-ant-... -p anthropic
```

---

## What the script checks

| # | Check | Description |
|---|---|---|
| 1 | Build succeeds | `docker build -f Dockerfile_pi -t pi-agent .` completes without error |
| 2 | Runs as `pi-agent` user | `whoami` inside the container returns `pi-agent` (non-root) |
| 3 | HOME is `/workspace` | `$HOME` is set to `/workspace` |
| 4 | Working directory | `pwd` returns `/workspace` |
| 5 | Config directory | `/workspace/.pi/agent` exists and is owned by `pi-agent:pi-agent` |
| 6 | Pi version | `pi --version` produces output |
| 7 | `git` installed | `git --version` returns a version string |
| 8 | `ripgrep` installed | `rg --version` returns a version string |
| 9 | LLM prompt | `pi -p "Reply with exactly: validate-ok"` returns the expected text |
| 10 | Bash tool + volume | Mounts a temp dir with a test file, Pi reads it via the `bash` tool |

Checks 9 and 10 require a valid provider API key. They are skipped if no key is found or `--no-llm` is set.

---

## Output format

The script prints each check with a status icon:

| Icon | Meaning |
|---|---|
| ✅ | Check passed |
| ❌ | Check failed |
| ⏭ | Check skipped |

### Example output

```
── 1. Build image ──
  ✅ build succeeded (cached)

── 2. Runs as pi-agent user (non-root) ──
  ✅ user is pi-agent

── 3. HOME is /workspace ──
  ✅ HOME=/workspace

── 4. Working directory is /workspace ──
  ✅ workdir is /workspace

── 5. /workspace/.pi/agent exists and is owned by pi-agent ──
  ✅ .pi/agent owned by pi-agent:pi-agent

── 6. pi --version works ──
  ✅ pi version: 1.5.2

── 7. git and ripgrep are installed ──
  ✅ git: git version 2.39.5
  ✅ ripgrep: ripgrep 13.0.0

── 8. Prompt returns a response (LLM) ──
  ✅ prompt returned: validate-ok

── 9. Bash tool with mounted volume (LLM) ──
  ✅ bash tool read mounted file correctly

════════════════════════════════════════
  Passed: 10
  Failed: 0
  Skipped: 0
════════════════════════════════════════
```

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All checks passed (skips are OK) |
| `1` | One or more checks failed, or the build failed |

Use this in CI pipelines:

```bash
./validate_pi_agent.sh || exit 1
```

---

## CI / CD integration

### GitHub Actions

```yaml
- name: Validate pi-agent image
  env:
    OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
  run: ./validate_pi_agent.sh
```

### GitLab CI

```yaml
validate-pi-agent:
  script:
    - ./validate_pi_agent.sh
  variables:
    OPENAI_API_KEY: $OPENAI_API_KEY
```

### Without LLM tests in CI

If you don't want to spend API tokens in CI, run only the structural checks:

```bash
./validate_pi_agent.sh --no-llm
```

---

## Troubleshooting

### `build failed`

Ensure Docker is running and `Dockerfile_pi` exists:

```bash
ls -l Dockerfile_pi
docker build -f Dockerfile_pi -t pi-agent .
```

### `user is pi-agent` fails

The `USER pi-agent` directive may have been removed from the Dockerfile. Verify:

```bash
rg 'USER pi-agent' Dockerfile_pi
```

### LLM tests skipped

```
WARNING: no API key found. LLM-backed tests will be skipped.
```

Set a provider key in the environment or pass it explicitly:

```bash
export OPENAI_API_KEY=sk-...
# or
./validate_pi_agent.sh -k sk-...
```

### `prompt did not return expected text`

- Verify the API key is valid and the provider is reachable.
- Check that the provider name matches the key (e.g. OpenRouter keys start with `sk-or-`).
- Use `-p` to specify the provider explicitly:

```bash
./validate_pi_agent.sh -k sk-or-... -p openrouter
```

### `bash tool test failed`

The bash tool test mounts a temporary directory and asks Pi to read a file. If it fails:

- Ensure Docker can mount local directories (Docker Desktop: enable file sharing).
- Check that the API key and provider are correct.

### `internal_logging.go` warnings

Lines like these are harmless telemetry noise from the local Docker host and are filtered out by the script:

```
"msg"="parse url" "error"="parse \"127.0.0.1:4317\"..."
```

---

## Reference

- [`Dockerfile_pi`](Dockerfile_pi) — the Dockerfile being validated
- [`Dockerfile_pi.md`](Dockerfile_pi.md) — image usage documentation
- [Pi containerization guide](https://pi.dev/docs/containerization)
