#!/usr/bin/env bash
# open-code-review.sh — run the open-code-review Docker image against a GitHub repo
#
# Usage:
#   ./open-code-review.sh -r <github-repo-url> -p <provider> -m <model> [-k <api-key>] [-a <review-args...>]
#
# Examples:
#   ./open-code-review.sh -r https://github.com/alibaba/open-code-review -p openai -m gpt-4o
#   ./open-code-review.sh -r https://github.com/foo/bar -p openrouter -m anthropic/claude-3.5-sonnet -k sk-or-...
#   ./open-code-review.sh -r https://github.com/foo/bar -p openai -m gpt-4o -a "scan --path /workspace/src"
#
# Notes:
#   - The repo is cloned to a temp directory and mounted into the container at /workspace.
#   - Provider/model configuration is stored in a named volume (ocr-config) for reuse.
#   - If no API key is given with -k, the script falls back to the provider's environment
#     variable (e.g. OPENAI_API_KEY, OPENROUTER_API_KEY) if set in your shell.
#   - Default review command is "review". Override with -a (quoted string of ocr subcommand + flags).

set -euo pipefail

IMAGE="open-code-review:latest"
CONFIG_VOLUME="ocr-config"

# --- Defaults
REPO_URL=""
PROVIDER=""
MODEL=""
API_KEY=""
REVIEW_ARGS="review"

usage() {
  cat <<EOF
Usage: $0 -r <github-repo-url> -p <provider> -m <model> [-k <api-key>] [-a <review-args>]

Options:
  -r  GitHub repository URL (required)
  -p  LLM provider, e.g. openai, openrouter (required)
  -m  Model ID for the provider, e.g. gpt-4o (required)
  -k  API key for the provider (optional; falls back to env var)
  -a  OCR subcommand + flags (default: "review")
  -h  Show this help

Examples:
  $0 -r https://github.com/alibaba/open-code-review -p openai -m gpt-4o
  $0 -r https://github.com/foo/bar -p openrouter -m anthropic/claude-3.5-sonnet -k sk-or-...
  $0 -r https://github.com/foo/bar -p openai -m gpt-4o -a "scan --path /workspace/src"
EOF
  exit "${1:-0}"
}

# --- Parse args
while getopts ":r:p:m:k:a:h" opt; do
  case "$opt" in
    r) REPO_URL="$OPTARG" ;;
    p) PROVIDER="$OPTARG" ;;
    m) MODEL="$OPTARG" ;;
    k) API_KEY="$OPTARG" ;;
    a) REVIEW_ARGS="$OPTARG" ;;
    h) usage 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage 1 ;;
    :)  echo "Missing argument for -$OPTARG" >&2; usage 1 ;;
  esac
done

# --- Validate required inputs
if [[ -z "$REPO_URL" || -z "$PROVIDER" || -z "$MODEL" ]]; then
  echo "Error: -r <repo-url>, -p <provider>, and -m <model> are required." >&2
  usage 1
fi

# --- Resolve the API key: explicit > env var > empty
# Map provider to its conventional environment variable name.
ENV_VAR_NAME="$(printf 'OPENAI_API_KEY
OPENROUTER_API_KEY
ANTHROPIC_API_KEY
DEEPSEEK_API_KEY
GROQ_API_KEY
MISTRAL_API_KEY
XAI_API_KEY
GEMINI_API_KEY' | awk -v p="$PROVIDER" '
  /^OPENAI_/      { if (p=="openai")      print $0 }
  /^OPENROUTER_/  { if (p=="openrouter")  print $0 }
  /^ANTHROPIC_/   { if (p=="anthropic")   print $0 }
  /^DEEPSEEK_/    { if (p=="deepseek")    print $0 }
  /^GROQ_/        { if (p=="groq")        print $0 }
  /^MISTRAL_/     { if (p=="mistral")     print $0 }
  /^XAI_/         { if (p=="xai")         print $0 }
  /^GEMINI_/      { if (p=="google" || p=="gemini") print $0 }
')"

if [[ -n "$API_KEY" ]]; then
  RESOLVED_KEY="$API_KEY"
elif [[ -n "$ENV_VAR_NAME" && -n "${!ENV_VAR_NAME:-}" ]]; then
  RESOLVED_KEY="${!ENV_VAR_NAME}"
else
  RESOLVED_KEY=""
fi

# --- Prepare repo directory
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Cloning $REPO_URL into $TMP_DIR"
git clone --quiet "$REPO_URL" "$TMP_DIR"

# --- Build docker run args
DOCKER_ARGS=(run --rm)
DOCKER_ARGS+=(-v "$TMP_DIR:/workspace")
DOCKER_ARGS+=(-v "$CONFIG_VOLUME:/root/.config/ocr")

# Pass the API key to the container if we have one.
if [[ -n "$RESOLVED_KEY" ]]; then
  DOCKER_ARGS+=(-e "${ENV_VAR_NAME:-API_KEY}=$RESOLVED_KEY")
fi

# --- Configure provider and model (non-interactive), then run the review.
# ocr config expects interactive use, so we feed it via heredoc/echo.
echo "==> Configuring provider: $PROVIDER"
docker "${DOCKER_ARGS[@]}" "$IMAGE" config provider --non-interactive --provider "$PROVIDER" \
  ${RESOLVED_KEY:+--api-key "$RESOLVED_KEY"} || true

echo "==> Configuring model: $MODEL"
docker "${DOCKER_ARGS[@]}" "$IMAGE" config model --non-interactive --model "$MODEL" || true

echo "==> Running review: ocr $REVIEW_ARGS"
echo "------------------------------------------------------------"
# shellcheck disable=SC2086  # intentional word-splitting of REVIEW_ARGS
docker "${DOCKER_ARGS[@]}" "$IMAGE" $REVIEW_ARGS
echo "------------------------------------------------------------"
echo "==> Done."
