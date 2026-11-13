# gcloud_run.sh — Deploy the Pi Agent to Google Cloud Run

Deploy the Pi coding agent as an HTTP service on Google Cloud Run. The agent accepts prompts via HTTP and returns AI-generated responses, with optional SSE streaming.

---

## Architecture

Cloud Run requires an HTTP server listening on `$PORT`. The Pi agent's RPC mode is a JSONL protocol over stdin/stdout, so this deployment uses a dedicated HTTP wrapper:

```
┌────────────┐     HTTP      ┌──────────────────────────────┐
│  Client     │ ────────────► │  Cloud Run                    │
│  (curl)     │               │  ┌──────────────────────┐     │
│             │ ◄──────────── │  │ pi_http_server.mjs   │     │
│             │   HTTP resp   │  │  (Node.js HTTP)      │     │
│             │               │  │   ├─ POST /prompt    │     │
│             │               │  │   ├─ GET /health    │     │
│             │               │  │   └─ spawns:        │     │
│             │               │  │      pi --mode rpc   │     │
│             │               │  └──────────────────────┘     │
└────────────┘               └──────────────────────────────┘
```

Each HTTP request spawns a fresh `pi --mode rpc --no-session` subprocess. The HTTP server translates between HTTP request/response (or SSE) and the JSONL protocol.

### Files

| File | Purpose |
|---|---|
| `pi_http_server.mjs` | Node.js HTTP server wrapping Pi's RPC protocol |
| `Dockerfile_pi_http` | Docker image for Cloud Run (HTTP server + Pi) |
| `gcloud_run.sh` | Build, push, and deploy script |

---

## Prerequisites

| Requirement | Details |
|---|---|
| Google Cloud CLI | Installed and authenticated (`gcloud auth login`) |
| Docker | Running locally |
| GCP project | Set via `gcloud config set project <ID>` or `-p` flag |
| Artifact Registry repo | Created once (see below) |
| Cloud APIs enabled | `run.googleapis.com`, `artifactregistry.googleapis.com` |
| Provider API key | OpenAI, Anthropic, OpenRouter, etc. (passed via `-k` or env var) |

### Enable required APIs (one-time)

```bash
gcloud services enable \
    run.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com
```

### Create the Artifact Registry repository (one-time)

```bash
gcloud artifacts repositories create vulneraser \
    --repository-format=docker \
    --location=us-central1
```

### Configure Docker for Artifact Registry (one-time)

```bash
gcloud auth configure-docker us-central1-docker.pkg.dev
```

---

## Usage

```bash
./gcloud_run.sh [options]
```

### Options

| Flag | Default | Purpose |
|---|---|---|
| `-r, --region <region>` | `us-central1` | GCP region for the Cloud Run service |
| `-s, --service <name>` | `pi-agent` | Cloud Run service name |
| `-i, --image <path>` | auto-derived | Full image path in Artifact Registry |
| `-p, --project <id>` | `gcloud config` | GCP project ID |
| `-R, --repository <name>` | `vulneraser` | Artifact Registry repository name |
| `-k, --api-key <key>` | env var | Provider API key (auto-detects provider from prefix) |
| `-e, --env KEY=VALUE` | — | Extra environment variable (repeatable) |
| `--min-instances <n>` | `0` | Minimum number of instances (0 = scale to zero) |
| `--max-instances <n>` | `3` | Maximum number of instances |
| `--memory <mem>` | `1Gi` | Memory limit per instance |
| `--cpu <n>` | `1` | CPU cores per instance |
| `--timeout <seconds>` | `300` | Max request timeout (Cloud Run max: 3600) |
| `--concurrency <n>` | `80` | Max concurrent requests per instance |
| `--no-allow-unauth` | (off) | Require authentication (IAM) |
| `--build-only` | (off) | Build and push image but don't deploy |
| `-h, --help` | — | Show help |

---

## Examples

### Deploy with defaults

```bash
./gcloud_run.sh
```

Builds `pi-http:latest`, pushes to Artifact Registry, and deploys as `pi-agent` in `us-central1`.

### Deploy with an explicit API key

```bash
./gcloud_run.sh -k sk-...
```

The script auto-detects the provider from the key prefix:
- `sk-or-...` → `OPENROUTER_API_KEY`
- `sk-ant-...` → `ANTHROPIC_API_KEY`
- other → `OPENAI_API_KEY`

### Deploy with extra environment variables

```bash
./gcloud_run.sh -e PI_REASONING_LEVEL=high -e MY_CONFIG=value
```

### Custom region and scaling

```bash
./gcloud_run.sh -r europe-west1 --max-instances 10 --memory 2Gi --cpu 2
```

### Require authentication

```bash
./gcloud_run.sh --no-allow-unauth
```

The service will require an IAM-authenticated caller. Use a service account or user identity token:

```bash
TOKEN=$(gcloud auth print-identity-token)
curl -sS -H "Authorization: Bearer $TOKEN" $SERVICE_URL/prompt ...
```

### Build and push only (no deploy)

```bash
./gcloud_run.sh --build-only
```

Useful for CI pipelines that build once and deploy separately.

### Specify the project explicitly

```bash
./gcloud_run.sh -p my-gcp-project-123
```

### Combine all options

```bash
./gcloud_run.sh \
    -r europe-west1 \
    -s pi-agent-prod \
    -k sk-... \
    --max-instances 10 \
    --memory 2Gi \
    --cpu 2 \
    --timeout 600 \
    --concurrency 100
```

---

## What the script does

1. Resolves the GCP project ID from `gcloud config` or the `-p` flag.
2. Derives the image path: `<region>-docker.pkg.dev/<project>/<repository>/pi-http:latest`.
3. Configures Docker for Artifact Registry authentication.
4. Builds the image from `Dockerfile_pi_http` locally.
5. Pushes the image to Artifact Registry.
6. (Unless `--build-only`) Deploys to Cloud Run with `gcloud run deploy`:
   - Sets the provider API key as an environment variable.
   - Configures scaling, memory, CPU, timeout, and concurrency.
   - Enables unauthenticated access by default (disable with `--no-allow-unauth`).
7. Prints the service URL and example `curl` commands.

---

## API endpoints

### `GET /health`

Health check for Cloud Run. Returns `200 OK`.

```bash
curl -sS $SERVICE_URL/health
```

```json
{"status":"ok"}
```

### `POST /prompt`

Send a prompt and receive the full response. Non-streaming.

```bash
curl -sS -X POST $SERVICE_URL/prompt \
    -H 'Content-Type: application/json' \
    -d '{"message":"Explain what this repo does"}'
```

```json
{
  "text": "This repository contains...",
  "disposition": "started",
  "model": "gpt-6.1-sol",
  "usage": {
    "input": 3,
    "output": 150,
    "totalTokens": 1088,
    "cost": { "total": 0.0028 }
  }
}
```

### `POST /prompt?stream=1`

Send a prompt and receive the response as a Server-Sent Events stream. Each `text_delta` is sent as a separate SSE `data` event.

```bash
curl -sS -N -X POST "$SERVICE_URL/prompt?stream=1" \
    -H 'Content-Type: application/json' \
    -d '{"message":"Count from 1 to 5"}'
```

```
data: {"delta":"1"}

data: {"delta":","}

data: {"delta":" "}

data: {"delta":"2"}

data: {"delta":"done"}

data: {"done":true}
```

### Error responses

| Scenario | HTTP status | Body |
|---|---|---|
| Invalid JSON body | 400 | `{"error":"invalid JSON body"}` |
| Missing `message` field | 400 | `{"error":"missing 'message' field"}` |
| Pi agent error | 500 | `{"error":"<details>"}` |
| Unknown path | 404 | `{"error":"not found","endpoints":[...]}` |

---

## Calling the deployed service

### Set the service URL

```bash
SERVICE_URL=$(gcloud run services describe pi-agent \
    --region us-central1 --format 'value(status.url)')
echo "$SERVICE_URL"
```

### Health check

```bash
curl -sS "$SERVICE_URL/health"
```

### Non-streaming prompt

```bash
curl -sS -X POST "$SERVICE_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d '{"message":"What is 2+2?"}'
```

### Streaming prompt (SSE)

```bash
curl -sS -N -X POST "$SERVICE_URL/prompt?stream=1" \
    -H 'Content-Type: application/json' \
    -d '{"message":"Write a haiku about Docker"}'
```

### From Python

```python
import requests

response = requests.post(
    f"{SERVICE_URL}/prompt",
    json={"message": "Explain what this repo does"},
    timeout=300,
)
print(response.json()["text"])
```

### From Python with SSE streaming

```python
import requests

with requests.post(
    f"{SERVICE_URL}/prompt?stream=1",
    json={"message": "Write a haiku about Docker"},
    stream=True,
    timeout=300,
) as response:
    for line in response.iter_lines():
        if line:
            print(line.decode(), flush=True)
```

### Authenticated calls (if `--no-allow-unauth`)

```bash
TOKEN=$(gcloud auth print-identity-token)
curl -sS -H "Authorization: Bearer $TOKEN" \
    -X POST "$SERVICE_URL/prompt" \
    -H 'Content-Type: application/json' \
    -d '{"message":"Hello"}'
```

---

## Managing the deployment

### View the service

```bash
gcloud run services describe pi-agent --region us-central1
```

### View logs

```bash
gcloud logging read \
    "resource.type=cloud_run_revision AND resource.labels.service_name=pi-agent" \
    --limit 50 --format "value(textPayload)"
```

Or stream logs in real time:

```bash
gcloud logging tail \
    "resource.type=cloud_run_revision AND resource.labels.service_name=pi-agent"
```

### Update the service

Re-run the deploy script:

```bash
./gcloud_run.sh
```

Or update just the image without rebuilding:

```bash
gcloud run services update pi-agent \
    --image us-central1-docker.pkg.dev/$PROJECT/vulneraser/pi-http:latest \
    --region us-central1
```

### Delete the service

```bash
gcloud run services delete pi-agent --region us-central1
```

### List revisions

```bash
gcloud run revisions list --service pi-agent --region us-central1
```

---

## Scaling and cost considerations

| Setting | Default | Recommendation |
|---|---|---|
| `--min-instances` | `0` | Keep `0` for dev to save cost; set `1+` for production to avoid cold starts |
| `--max-instances` | `3` | Increase for high traffic; each instance handles `--concurrency` requests |
| `--memory` | `1Gi` | Pi + Node.js needs ~512MB minimum; increase to `2Gi` for large repos |
| `--cpu` | `1` | Increase to `2` for faster LLM tool-use (file reads, bash) |
| `--timeout` | `300` | Set to `600+` for long code reviews; Cloud Run max is `3600` |
| `--concurrency` | `80` | Each request spawns a Pi subprocess; lower this if memory is constrained |

### Cold starts

With `--min-instances 0` (default), the first request after idle takes ~10–30 seconds to start a new instance. Set `--min-instances 1` to keep a warm instance:

```bash
./gcloud_run.sh --min-instances 1
```

### Cost optimization

- Use `--min-instances 0` for development (scales to zero when idle).
- Use `--max-instances 1` for single-user testing.
- Each request spawns a Pi subprocess, so CPU and memory scale with concurrency.

---

## Troubleshooting

### `no GCP project ID set`

```bash
gcloud config set project my-project-id
# or
./gcloud_run.sh -p my-project-id
```

### `denied: permission denied` on push

```bash
gcloud auth login
gcloud auth configure-docker us-central1-docker.pkg.dev
```

### `repository not found`

```bash
gcloud artifacts repositories create vulneraser \
    --repository-format=docker --location us-central1
```

### Cloud Run deployment fails

Ensure the Cloud Run API is enabled:

```bash
gcloud services enable run.googleapis.com
```

### Request times out

Increase the timeout:

```bash
./gcloud_run.sh --timeout 600
```

### Out of memory

```bash
./gcloud_run.sh --memory 2Gi --concurrency 20
```

### Cold start latency too high

```bash
./gcloud_run.sh --min-instances 1
```

### `internal_logging.go` warnings

Lines like these are harmless telemetry noise from the local Docker host, not from Cloud Run:

```
"msg"="parse url" "error"="parse \"127.0.0.1:4317\"..."
```

### View container logs on Cloud Run

```bash
gcloud logging read \
    "resource.type=cloud_run_revision AND resource.labels.service_name=pi-agent" \
    --limit 50
```

---

## Comparison: `pi-rpc` vs `pi-http`

| Aspect | `pi-rpc` (Dockerfile_pi_rpc) | `pi-http` (Dockerfile_pi_http) |
|---|---|---|
| Protocol | Raw TCP (JSONL) | HTTP (JSON request/response + SSE) |
| Transport | `socat` on port 9471 | Node.js HTTP server on port 8080 |
| Cloud Run | ❌ Not supported (no raw TCP) | ✅ Designed for Cloud Run |
| Local use | ✅ `pi_rpc.py` client | ✅ `curl` or any HTTP client |
| Streaming | JSONL events over TCP | SSE (`text/event-stream`) |
| Client | `pi_rpc.py` (Python) | Any HTTP client (curl, Python, JS, etc.) |

Use `pi-rpc` for direct TCP access and `pi_rpc.py` as the client. Use `pi-http` for Cloud Run and any HTTP-based integration.

---

## Reference

- [Cloud Run documentation](https://cloud.google.com/run/docs)
- [Cloud Run container runtime contract](https://cloud.google.com/run/docs/container-contract)
- [Artifact Registry documentation](https://cloud.google.com/artifact-registry/docs)
- [gcloud run deploy reference](https://cloud.google.com/sdk/gcloud/reference/run/deploy)
- [Server-Sent Events spec](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
