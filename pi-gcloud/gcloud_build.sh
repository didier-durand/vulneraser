#!/usr/bin/env bash
# gcloud_build.sh — build and push container images to Google Cloud Artifact Registry.
#
# Builds both images from this repo locally, tags them, and pushes them to
# Artifact Registry. Useful when Cloud Build is unavailable or you want to
# build on a machine with a faster CPU.
#
# Usage:
#   ./gcloud_build.sh [options]
#
# Options:
#   -r, --region       Artifact Registry region  (default us-central1)
#   -R, --repository   Artifact Registry repo    (default vulneraser)
#   -p, --project      GCP project ID             (default: gcloud config)
#   -t, --tag          Extra tag (e.g. v1.0)      (default: latest + git sha)
#   -i, --image        Build only one image: pi-rpc | ocr | both (default both)
#   --no-push          Build locally but don't push
#   -h, --help         Show this help
#
# Prerequisites:
#   - Google Cloud CLI installed and authenticated (gcloud auth login)
#   - Docker configured for Artifact Registry:
#       gcloud auth configure-docker <region>-docker.pkg.dev
#   - Artifact Registry repository created:
#       gcloud artifacts repositories create vulneraser \
#           --repository-format=docker --location=us-central1
#
# Examples:
#   ./gcloud_build.sh
#   ./gcloud_build.sh --region europe-west1 --repository vulneraser
#   ./gcloud_build.sh --image pi-rpc
#   ./gcloud_build.sh --tag v1.0 --no-push

set -euo pipefail

# --- Defaults
REGION="us-central1"
REPOSITORY="vulneraser"
PROJECT_ID=""
EXTRA_TAG=""
IMAGE="both"
PUSH=true

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -r, --region       Artifact Registry region  (default us-central1)
  -R, --repository   Artifact Registry repo    (default vulneraser)
  -p, --project      GCP project ID            (default: gcloud config)
  -t, --tag          Extra tag (e.g. v1.0)      (default: latest + git sha)
  -i, --image        Build only one image: pi-rpc | ocr | both (default both)
  --no-push          Build locally but don't push
  -h, --help         Show this help
EOF
  exit "${1:-0}"
}

# --- Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region)     REGION="$2"; shift 2 ;;
    -R|--repository) REPOSITORY="$2"; shift 2 ;;
    -p|--project)    PROJECT_ID="$2"; shift 2 ;;
    -t|--tag)        EXTRA_TAG="$2"; shift 2 ;;
    -i|--image)      IMAGE="$2"; shift 2 ;;
    --no-push)       PUSH=false; shift ;;
    -h|--help)       usage 0 ;;
    *)               echo "Unknown option: $1" >&2; usage 1 ;;
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

# --- Determine git short SHA
SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo local)"
echo "==> GCP project:  $PROJECT_ID"
echo "==> Region:      $REGION"
echo "==> Repository:  $REPOSITORY"
echo "==> Git SHA:     $SHORT_SHA"
if [[ -n "$EXTRA_TAG" ]]; then
  echo "==> Extra tag:   $EXTRA_TAG"
fi
echo "==> Images:      $IMAGE"
echo "==> Push:         $PUSH"
echo

REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}"

# --- Helpers
build_image() {
  local name="$1" dockerfile="$2"

  echo "--- Building ${name} ---"
  local -a tags=(
    "${REGISTRY}/${name}:latest"
    "${REGISTRY}/${name}:${SHORT_SHA}"
  )
  if [[ -n "$EXTRA_TAG" ]]; then
    tags+=("${REGISTRY}/${name}:${EXTRA_TAG}")
  fi

  local -a build_args=(build -f "$dockerfile")
  for tag in "${tags[@]}"; do
    build_args+=(-t "$tag")
  done
  build_args+=(.)

  docker "${build_args[@]}"
  echo "==> Built ${name} with tags:"
  for tag in "${tags[@]}"; do
    echo "    $tag"
  done
  echo

  if $PUSH; then
    echo "--- Pushing ${name} ---"
    for tag in "${tags[@]}"; do
      echo "    docker push $tag"
      docker push "$tag"
    done
    echo
  fi
}

# --- Configure Docker for Artifact Registry (idempotent)
if $PUSH; then
  echo "==> Configuring Docker for ${REGION}-docker.pkg.dev"
  gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
  echo
fi

# --- Build requested images
case "$IMAGE" in
  pi-rpc|both) build_image "pi-rpc" "Dockerfile_pi_rpc" ;;
esac
case "$IMAGE" in
  ocr|both)   build_image "open-code-review" "Dockerfile_ocr" ;;
esac

echo "==> Done."
if $PUSH; then
  echo "Images available at:"
  case "$IMAGE" in
    pi-rpc|both) echo "  ${REGISTRY}/pi-rpc:latest" ;;
  esac
  case "$IMAGE" in
    ocr|both)   echo "  ${REGISTRY}/open-code-review:latest" ;;
  esac
fi
