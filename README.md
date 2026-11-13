# vulneraser

Vulneraser: discover and remove vulnerabilities in source code.

This repository provides Docker images, clients, and deployment scripts for running AI-powered code review tools — the [Pi coding agent](https://pi.dev) and [Open Code Review](https://open-codereview.ai) — in containers, over the network, and on Google Cloud.

## Repository structure

```
vulneraser/
├── ocr/                  # Open Code Review Docker image and runner script
├── pi-gcloud/            # Pi agent: RPC/HTTP images, GCloud build & deploy
├── pi-local/             # Pi agent: local Docker image and validation
├── COMMANDS.md           # Docker build command reference
├── DOCS.md               # Links to Open Code Review resources
└── LICENSE               # Apache-2.0 license
```

## Subdirectories

### `ocr/` — Open Code Review

Docker image and shell script for [Open Code Review](https://open-codereview.ai), an AI-powered code review CLI by Alibaba.

| File | Description |
|---|---|
| `Dockerfile_ocr` | Builds an `open-code-review` image (Ubuntu 24.04, Git 2.43, Node 20) with the `ocr` CLI installed |
| `open-code-review.sh` | Shell script that clones a GitHub repo and runs `ocr` against it with a given provider and model |

**Quick start:**
```bash
docker build -f ocr/Dockerfile_ocr -t open-code-review .
docker run --rm -v "$PWD:/workspace" open-code-review review
```

### `pi-gcloud/` — Pi Agent: RPC, HTTP, and Google Cloud

Docker images, Python client, and Google Cloud deployment scripts for the [Pi coding agent](https://pi.dev).

| File | Description |
|---|---|
| `Dockerfile_pi_rpc` | Pi agent in RPC mode exposed over TCP via socat (port 9471) |
| `pi_rpc.py` | Python client that connects to the RPC container and streams responses |
| `pi_rpc.md` | RPC client usage documentation |
| `test_pi_rpc.py` | 48-test suite covering image, container, client, protocol, CLI, and edge cases |
| `test_pi_rpc.md` | Test suite documentation |
| `Dockerfile_pi_http` | Pi agent with an HTTP wrapper for Google Cloud Run (port 8080) |
| `pi_http_server.mjs` | Node.js HTTP server wrapping Pi's RPC protocol (`POST /prompt`, SSE streaming) |
| `gcloud_run.sh` | Build, push, and deploy the HTTP image to Google Cloud Run |
| `gcloud_run.md` | Cloud Run deployment documentation |
| `cloudbuild.yaml` | Cloud Build config for building both Pi images serverlessly |
| `gcloud_build.sh` | Local build and push to Artifact Registry |
| `gcloud_build.md` | Build script documentation |

**RPC mode (TCP):**
```bash
docker build -f pi-gcloud/Dockerfile_pi_rpc -t pi-rpc .
docker run --rm -p 9471:9471 -e OPENAI_API_KEY=sk-... pi-rpc
python3 pi-gcloud/pi_rpc.py "Hello"
```

**Cloud Run (HTTP):**
```bash
./pi-gcloud/gcloud_run.sh
```

### `pi-local/` — Pi Agent: Local Docker Image

A minimal Docker image for running the Pi agent locally as a dedicated non-root user.

| File | Description |
|---|---|
| `Dockerfile_pi` | Pi agent running as the `pi-agent` Linux user with `/workspace` as home and working directory |
| `Dockerfile_pi.md` | Image usage documentation |
| `validate_pi_agent.sh` | Automated validation script (10 checks: build, user, home, tools, LLM prompt, bash tool) |
| `validate_pi_agent.md` | Validation script documentation |

**Quick start:**
```bash
docker build -f pi-local/Dockerfile_pi -t pi-agent .
docker run --rm -it -e OPENAI_API_KEY=sk-... -v "$PWD:/workspace" pi-agent
```

**Validate:**
```bash
./pi-local/validate_pi_agent.sh
```

## Quick reference

All Docker images in this repo:

| Image | Dockerfile | Port | Use case |
|---|---|---|---|
| `pi-agent` | `pi-local/Dockerfile_pi` | — | Local interactive/non-interactive Pi CLI |
| `pi-rpc` | `pi-gcloud/Dockerfile_pi_rpc` | TCP 9471 | Programmatic access via `pi_rpc.py` |
| `pi-http` | `pi-gcloud/Dockerfile_pi_http` | HTTP 8080 | Google Cloud Run or any HTTP integration |
| `open-code-review` | `ocr/Dockerfile_ocr` | — | Open Code Review CLI |

## License

Apache-2.0 — see [LICENSE](LICENSE).
