#!/usr/bin/env bash
# gcloud_run.sh — deploy the Pi agent HTTP image to Google Cloud Run.
#
# Cloud Run requires an HTTP server, not raw TCP. This script deploys the
# image built from Dockerfile_pi_http, which wraps Pi's RPC protocol in a
# small HTTP server.
#
# Usage:
#   ./gcloud_run.sh [options]
#
# Options:
#   -r, --region       GCP region                (default us-central1)
#   -s, --service      Cloud Run service name     (default pi-agent)
#   -i, --image        Full image path            (default: auto-built)
#   -p, --project      GCP project ID             (default: gcloud config)
#   -R, --repository   Artifact Registry repo    (default vulneraser)
#   -k, --api-key      Provider API key           (default: env var)
#   -e, --env          Extra env var KEY=VALUE    (repeatable)
#   --min-instances    Min instances              (default 0)
#   --max-instances    Max instances              (default 3)
#   --memory          Memory limit               (default 1Gi)
#   --cpu              CPU count                  (default 1)
#   --timeout          Request timeout seconds    (default 300)
#   --concurrency      Max concurrent requests     (default 80)
#   --no-allow-unauth  Require authentication
#   --build-only       Build image but don't deploy
#   -h, --help         Show this help
#
# Prerequisites:
#   - gcloud CLI installed and authenticated
#   - Cloud Run API enabled:  gcloud services enable run.googleapis.com
#   - Artifact Registry repo created (see gcloud_build.md)
#
# Examples:
#   ./gcloud_run.sh
#   ./gcloud_run.sh -k sk-... -e OPENAI_API_KEY=sk-...
#   ./gcloud_run.sh --region europe-west1 --max-instances 10
#   ./gcloud_run.sh --build-only

set -euo pipefail

# --- Defaults
REGION="us-central1"
SERVICE="pi-agent"
IMAGE_PATH=""
PROJECT_ID=""
REPOSITORY="vulneraser"
API_KEY=""
EXTRA_ENV=()
MIN_INSTANCES=0
MAX_INSTANCES=3
MEMORY="1Gi"
CPU=1
TIMEOUT=300
CONCURRENCY=80
ALLOW_UNAUTH=true
BUILD_ONLY=false

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -r, --region        GCP region                (default us-central1)
  -s, --service       Cloud Run service name    (default pi-agent)
  -i, --image         Full image path           (default: auto from registry)
  -p, --project       GCP project ID            (default: gcloud config)
  -R, --repository    Artifact Registry repo    (default vulneraser)
  -k, --api-key       Provider API key          (default: env var)
  -e, --env           Extra env var KEY=VALUE   (repeatable)
      --min-instances Min instances             (default 0)
      --max-instances Max instances             (default 3)
      --memory        Memory limit              (default 1Gi)
      --cpu            CPU count                (default 1)
      --timeout        Request timeout seconds  (default 300)
      --concurrency    Max concurrent requests   (default 80)
      --no-allow-unauth  Require authentication
      --build-only     Build image but don't deploy
  -h, --help          Show this help
EOF
  exit "${1:-0}"
}

# --- Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region)        REGION="$2"; shift 2 ;;
    -s|--service)       SERVICE="$2"; shift 2 ;;
    -i|--image)         IMAGE_PATH="$2"; shift 2 ;;
    -p|--project)       PROJECT_ID="$2"; shift 2 ;;
    -R|--repository)    REPOSITORY="$2"; shift 2 ;;
    -k|--api-key)       API_KEY="$2"; shift 2 ;;
    -e|--env)           EXTRA_ENV+=("$2"); shift 2 ;;
    --min-instances)    MIN_INSTANCES="$2"; shift 2 ;;
    --max-instances)    MAX_INSTANCES="$2"; shift 2 ;;
    --memory)           MEMORY="$2"; shift 2 ;;
    --cpu)              CPU="$2"; shift 2 ;;
    --timeout)          TIMEOUT="$2"; shift 2 ;;
    --concurrency)      CONCURRENCY="$2"; shift 2 ;;
    --no-allow-unauth)  ALLOW_UNAUTH=false; shift ;;
    --build-only)       BUILD_ONLY=true; shift ;;
    -h|--help)          usage 0 ;;
    *)                  echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# --- Resolve GCP project ID
if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
fi
if [[ -z "$PROJECT_ID" ]]; then
  echo "Error: no GCP project ID set. Run 'gcloud config set project <ID>' or use -p." >&2
  exit 1
fi

# --- Resolve image path
if [[ -z "$IMAGE_PATH" ]]; then
  IMAGE_PATH="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/pi-http:latest"
fi

echo "==> GCP project:  $PROJECT_ID"
echo "==> Region:      $REGION"
echo "==> Service:     $SERVICE"
echo "==> Image:       $IMAGE_PATH"
echo "==> Min/Max:     $MIN_INSTANCES / $MAX_INSTANCES"
echo "==> Memory/CPU:  $MEMORY / $CPU"
echo "==> Timeout:     ${TIMEOUT}s"
echo "==> Concurrency: $CONCURRENCY"
echo "==> Allow unauth: $ALLOW_UNAUTH"
echo

# --- Configure Docker for Artifact Registry
echo "==> Configuring Docker for ${REGION}-docker.pkg.dev"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
echo

# --- Build and push the image
echo "==> Building and pushing $IMAGE_PATH"
docker build -f Dockerfile_pi_http -t "$IMAGE_PATH" .
docker push "$IMAGE_PATH"
echo

if $BUILD_ONLY; then
  echo "==> Build-only mode: image pushed, skipping deployment."
  echo "    Image: $IMAGE_PATH"
  exit 0
fi

# --- Resolve the API key env var
ENV_FLAGS=()
if [[ -n "$API_KEY" ]]; then
  # Auto-detect provider from key prefix; default to OPENAI_API_KEY.
  if [[ "$API_KEY" == sk-or-* ]]; then
    ENV_FLAGS+=(--set-env-vars "OPENROUTER_API_KEY=$API_KEY")
  elif [[ "$API_KEY" == sk-ant-* ]]; then
    ENV_FLAGS+=(--set-env-vars "ANTHROPIC_API_KEY=$API_KEY")
  else
    ENV_FLAGS+=(--set-env-vars "OPENAI_API_KEY=$API_KEY")
  fi
else
  # Pass through existing env vars if set.
  for var in OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY DEEPSEEK_API_KEY GEMINI_API_KEY; do
    if [[ -n "${!var:-}" ]]; then
      ENV_FLAGS+=(--set-env-vars "${var}=${!var}")
    fi
  done
fi

# --- Extra env vars
for envvar in "${EXTRA_ENV[@]:-}"; do
  ENV_FLAGS+=(--set-env-vars "$envvar")
done

# --- Deploy to Cloud Run
echo "==> Deploying $SERVICE to Cloud Run"
gcloud run deploy "$SERVICE" \
  --image "$IMAGE_PATH" \
  --region "$REGION" \
  --platform managed \
  --min-instances "$MIN_INSTANCES" \
  --max-instances "$MAX_INSTANCES" \
  --memory "$MEMORY" \
  --cpu "$CPU" \
  --timeout "$TIMEOUT" \
  --concurrency "$CONCURRENCY" \
  --port 8080 \
  "${ENV_FLAGS[@]}" \
  $($ALLOW_UNAUTH && echo "--allow-unauthenticated") \
  --no-cpu-boost \
  --quiet

echo
echo "==> Deployed successfully!"
echo

# --- Get the service URL
SERVICE_URL="$(gcloud run services describe "$SERVICE" --region "$REGION" --format 'value(status.url)' 2>/dev/null || true)"
if [[ -n "$SERVICE_URL" ]]; then
  echo "==> Service URL: $SERVICE_URL"
  echo
  echo "Test it:"
  echo "  curl -sS $SERVICE_URL/health"
  echo "  curl -sS -X POST $SERVICE_URL/prompt -H 'Content-Type: application/json' -d '{\"message\":\"Hello\"}'"
  echo "  curl -sS -N -X POST '$SERVICE_URL/prompt?stream=1' -H 'Content-Type: application/json' -d '{\"message\":\"Hello\"}'"
fi
