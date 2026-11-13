# Dockerfile_pi — Pi Agent as a Dedicated `pi-agent` User

Run the [Pi coding agent](https://pi.dev) in a container as an unprivileged Linux user named `pi-agent`, with the home directory set to `/workspace` — the agent's working directory.

This is the simplest container for running Pi interactively or non-interactively against a mounted project folder. Unlike `pi-rpc` (raw TCP) or `pi-http` (Cloud Run), this image is designed for direct CLI usage.

---

## Image overview

| Aspect | Value |
|---|---|
| Image name | `pi-agent` |
| Base image | `node:22-bookworm-slim` |
| User | `pi-agent` (system user, non-root) |
| Home directory | `/workspace` |
| Working directory | `/workspace` |
| Pi config location | `/workspace/.pi/agent` |
| Pi version | latest from npm (`@earendil-works/pi-coding-agent`) |
| Installed tools | Pi CLI, `git`, `ripgrep`, `bash` |
| Entrypoint | `pi` |
| Port | none (CLI-only) |

### Why a dedicated user?

- **Security** — Pi and all its tool calls (`bash`, `read`, `write`, `edit`) run as the unprivileged `pi-agent` user, not root.
- **File ownership** — Files created by Pi inside the container are owned by `pi-agent`, matching the mounted host directory's expectations.
- **Isolation** — Pi's config, sessions, and extensions all live under `$HOME/.pi/agent` inside `/workspace`, keeping everything in one place.

### Directory layout inside the container

```
/workspace                  ← pi-agent's home ($HOME) and working dir
├── .pi/
│   └── agent/              ← Pi config, sessions, extensions
│       ├── auth.json       ← stored credentials (if /login is used)
│       ├── settings.json   ← Pi settings
│       ├── sessions/       ← session files
│       └── extensions/     ← installed extensions
└── <your project files>    ← mounted from host
```

---

## Build the image

```bash
docker build -f Dockerfile_pi -t pi-agent .
```

### What the Dockerfile does

1. Installs `git`, `ripgrep`, `bash`, and `ca-certificates` (Pi's runtime dependencies).
2. Installs the Pi CLI globally via npm (`@earendil-works/pi-coding-agent`).
3. Creates the `/workspace` directory and `/workspace/.pi/agent` config tree.
4. Creates a system group and user `pi-agent` with home set to `/workspace`.
5. Sets ownership of `/workspace` to `pi-agent:pi-agent`.
6. Switches to the `pi-agent` user (`USER pi-agent`).
7. Sets `HOME=/workspace` and `WORKDIR /workspace`.
8. Sets the entrypoint to `pi`.

---

## Run the container

### Interactive mode

```bash
docker run --rm -it \
    -e OPENAI_API_KEY=sk-... \
    -v "$PWD:/workspace" \
    pi-agent
```

This opens the Pi interactive TUI with your current directory mounted as the workspace.

### Non-interactive (single prompt)

```bash
docker run --rm \
    -e OPENAI_API_KEY=sk-... \
    -v "$PWD:/workspace" \
    pi-agent -p "Review this code for bugs"
```

The `-p` flag processes the prompt and exits.

### Without a mounted volume

```bash
docker run --rm -it \
    -e OPENAI_API_KEY=sk-... \
    pi-agent
```

Pi starts in an empty `/workspace`. Use `!git clone ...` or the `bash` tool to bring files in.

---

## Authentication

Pi needs an LLM provider API key. Pass it as an environment variable:

| Provider | Environment variable | Key prefix |
|---|---|---|
| OpenAI | `OPENAI_API_KEY` | `sk-...` |
| Anthropic | `ANTHROPIC_API_KEY` | `sk-ant-...` |
| OpenRouter | `OPENROUTER_API_KEY` | `sk-or-...` |
| DeepSeek | `DEEPSEEK_API_KEY` | `sk-...` |
| Google Gemini | `GEMINI_API_KEY` | `AIza...` |

### Pass the key via `-e`

```bash
docker run --rm -it \
    -e OPENAI_API_KEY=sk-... \
    -v "$PWD:/workspace" \
    pi-agent
```

### Pass the key via an env file

Create `.env`:

```
OPENAI_API_KEY=sk-...
```

```bash
docker run --rm -it \
    --env-file .env \
    -v "$PWD:/workspace" \
    pi-agent
```

### Store credentials inside the container

If you mount a persistent volume on `/workspace/.pi/agent`, you can run `pi auth login` once and the credential persists across runs:

```bash
docker run --rm -it \
    -v pi-agent-home:/workspace/.pi/agent \
    -v "$PWD:/workspace/project" \
    pi-agent
```

Then inside Pi:

```
pi auth login
```

The credential is stored in `/workspace/.pi/agent/auth.json` (on the persistent volume).

---

## Selecting a model

### Via CLI flags

```bash
docker run --rm -it \
    -e OPENAI_API_KEY=sk-... \
    -v "$PWD:/workspace" \
    pi-agent --model gpt-4o
```

### Via provider/model pair

```bash
docker run --rm -it \
    -e ANTHROPIC_API_KEY=sk-ant-... \
    -v "$PWD:/workspace" \
    pi-agent --provider anthropic --model claude-sonnet-4-20250514
```

### With a thinking level

```bash
docker run --rm -it \
    -e OPENAI_API_KEY=sk-... \
    -v "$PWD:/workspace" \
    pi-agent --model gpt-4o --thinking high
```

---

## Volume mounts

### Mount a project directory

```bash
-v "$PWD:/workspace"
```

Your host directory appears at `/workspace` inside the container. Pi can read and edit files directly — changes write through to the host.

### Mount a project subdirectory

If you want the project in a subdirectory and Pi's config separate:

```bash
-v "$PWD:/workspace/project" \
-v pi-agent-config:/workspace/.pi/agent
```

Pi's config persists on the named volume, and your project is at `/workspace/project`.

### Read-only mount

To prevent Pi from modifying host files:

```bash
-v "$PWD:/workspace:ro"
```

Pi can still read files and run commands, but `write` and `edit` tool calls will fail.

### Persist Pi config and sessions

```bash
-v pi-agent-home:/workspace/.pi/agent
```

This keeps `auth.json`, `settings.json`, sessions, and extensions between container runs without mounting the entire workspace.

---

## Common workflows

### Review a repository

```bash
cd /path/to/my-repo
docker run --rm -it \
    -e OPENAI_API_KEY=sk-... \
    -v "$PWD:/workspace" \
    pi-agent -p "Review the code in /workspace and report any bugs"
```

### Fix failing tests

```bash
docker run --rm -it \
    -e OPENAI_API_KEY=sk-... \
    -v "$PWD:/workspace" \
    pi-agent -p "Run the test suite and fix any failing tests"
```

### Explore a codebase interactively

```bash
docker run --rm -it \
    -e OPENAI_API_KEY=sk-... \
    -v "$PWD:/workspace" \
    pi-agent
```

Then ask questions in the Pi TUI:

```
> What does this project do?
> Find all uses of the deprecated API
> Explain the authentication flow
```

### Continue a previous session

```bash
docker run --rm -it \
    -e OPENAI_API_KEY=sk-... \
    -v "$PWD:/workspace" \
    -v pi-agent-home:/workspace/.pi/agent \
    pi-agent --continue
```

### Use a specific system prompt

```bash
docker run --rm -it \
    -e OPENAI_API_KEY=sk-... \
    -v "$PWD:/workspace" \
    pi-agent --append-system-prompt "Focus on security vulnerabilities"
```

---

## Inspection and debugging

### Check the running user

```bash
docker run --rm --entrypoint bash pi-agent -c 'whoami && echo "HOME=$HOME" && pwd'
```

```
pi-agent
HOME=/workspace
/workspace
```

### Check installed tools

```bash
docker run --rm --entrypoint bash pi-agent -c 'pi --version && git --version && rg --version'
```

### Inspect the image configuration

```bash
docker inspect pi-agent --format 'User: {{.Config.User}}
WorkDir: {{.Config.WorkingDir}}
Home env: {{range .Config.Env}}{{println .}}{{end}}'
```

### Drop into a shell as pi-agent

```bash
docker run --rm -it --entrypoint bash pi-agent
```

### Check file ownership in the workspace

```bash
docker run --rm --entrypoint bash pi-agent -c 'ls -la /workspace'
```

---

## Security considerations

- **Non-root execution** — Pi runs as the `pi-agent` system user. It cannot modify system files or escalate privileges within the container.
- **Mounted volumes** — A read-write mount on `/workspace` gives Pi full access to those host files. Use `:ro` for read-only access when you don't want Pi to modify files.
- **API keys** — Environment variables passed with `-e` are visible to Pi and any processes it spawns. Use `--env-file` with restrictive permissions for sensitive keys.
- **Network** — Pi can make outbound network requests (LLM API calls, `git clone`, etc.). Use Docker network restrictions if you need to limit egress.
- **No host mount of `~/.pi/agent`** — The image uses `/workspace/.pi/agent` (inside the container) for config. Do not mount the host's `~/.pi/agent` unless you intentionally want to share host credentials and settings.

See the [Pi security documentation](https://pi.dev/docs/security) for more guidance.

---

## Comparison with other images in this repo

| Image | Dockerfile | Use case | Network | User |
|---|---|---|---|---|
| `pi-agent` | `Dockerfile_pi` | Direct CLI usage | none | `pi-agent` |
| `pi-rpc` | `Dockerfile_pi_rpc` | Raw TCP RPC mode | TCP 9471 | root |
| `pi-http` | `Dockerfile_pi_http` | Google Cloud Run (HTTP) | HTTP 8080 | root |
| `open-code-review` | `Dockerfile_ocr` | Open Code Review CLI | none | root |

- Use **`pi-agent`** for interactive or single-prompt usage with a mounted project.
- Use **`pi-rpc`** for programmatic access over TCP from `pi_rpc.py`.
- Use **`pi-http`** for Cloud Run or any HTTP-based integration.
- Use **`open-code-review`** for the separate Open Code Review tooling.

---

## Troubleshooting

### `pi: command not found`

The image didn't build correctly. Rebuild:

```bash
docker build -f Dockerfile_pi -t pi-agent .
```

### Permission denied on mounted files

The `pi-agent` user (UID is auto-assigned) may not match your host user's UID. For most use cases this is fine because Docker maps the volume owner. If you hit permission errors:

```bash
# Option 1: Run as your host UID
docker run --rm -it \
    --user "$(id -u):$(id -g)" \
    -e OPENAI_API_KEY=sk-... \
    -v "$PWD:/workspace" \
    pi-agent

# Option 2: Fix permissions on the host
chmod -R a+rwX "$PWD"
```

### `HOME` is not `/workspace`

The `HOME=/workspace` env var is baked into the image. If you override it with `-e HOME=...`, Pi may not find its config. Don't override `HOME` unless you know what you're doing.

### API key not working

```bash
# Verify the key is set inside the container
docker run --rm --entrypoint bash -e OPENAI_API_KEY pi-agent -c 'echo ${OPENAI_API_KEY:0:10}...'
```

### `internal_logging.go` warnings

Lines like these on stderr are harmless telemetry noise from the local Docker host, not from the container:

```
"msg"="parse url" "error"="parse \"127.0.0.1:4317\"..."
```

---

## Reference

- [Pi documentation](https://pi.dev/docs)
- [Pi containerization guide](https://pi.dev/docs/containerization)
- [Pi CLI reference](https://pi.dev/docs/cli)
- [Pi models & providers](https://pi.dev/docs/models)
- [Pi security](https://pi.dev/docs/security)
