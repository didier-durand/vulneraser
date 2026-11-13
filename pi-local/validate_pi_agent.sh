#!/usr/bin/env bash
# validate_pi_agent.sh — validate the pi-agent Docker image.
#
# Builds the image from Dockerfile_pi and runs a series of checks:
#   1. Build succeeds
#   2. Runs as the pi-agent user (non-root)
#   3. HOME is /workspace
#   4. Working directory is /workspace
#   5. /workspace/.pi/agent exists and is owned by pi-agent
#   6. pi --version works
#   7. git and ripgrep are installed
#   8. A prompt returns a response (requires an API key)
#   9. Bash tool works with a mounted volume (requires an API key)
#
# Usage:
#   ./validate_pi_agent.sh [options]
#
# Options:
#   -i, --image     image name           (default pi-agent)
#   -k, --api-key   provider API key     (default: $OPENAI_API_KEY env var)
#   -p, --provider  provider name         (default openai)
#   --no-build      skip the build step
#   --no-llm        skip LLM-backed tests (no API key needed)
#   -h, --help      show this help

set -euo pipefail

# --- Defaults
IMAGE="pi-agent"
API_KEY=""
PROVIDER="openai"
DO_BUILD=true
DO_LLM=true

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -i, --image     image name           (default pi-agent)
  -k, --api-key   provider API key     (default: \$OPENAI_API_KEY env var)
  -p, --provider  provider name        (default openai)
      --no-build   skip the build step
      --no-llm     skip LLM-backed tests (no API key needed)
  -h, --help      show this help
EOF
  exit "${1:-0}"
}

# --- Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)     IMAGE="$2"; shift 2 ;;
    -k|--api-key)   API_KEY="$2"; shift 2 ;;
    -p|--provider)  PROVIDER="$2"; shift 2 ;;
    --no-build)     DO_BUILD=false; shift ;;
    --no-llm)       DO_LLM=false; shift ;;
    -h|--help)      usage 0 ;;
    *)              echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# --- Resolve API key
if [[ -z "$API_KEY" ]]; then
  for var in OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY DEEPSEEK_API_KEY GEMINI_API_KEY; do
    if [[ -n "${!var:-}" ]]; then
      API_KEY="${!var}"
      # Auto-detect provider from env var name if not overridden.
      case "$var" in
        OPENAI_API_KEY)      PROVIDER="${PROVIDER:-openai}" ;;
        ANTHROPIC_API_KEY)   PROVIDER="${PROVIDER:-anthropic}" ;;
        OPENROUTER_API_KEY)  PROVIDER="${PROVIDER:-openrouter}" ;;
        DEEPSEEK_API_KEY)    PROVIDER="${PROVIDER:-deepseek}" ;;
        GEMINI_API_KEY)      PROVIDER="${PROVIDER:-google}" ;;
      esac
      break
    fi
  done
fi

if $DO_LLM && [[ -z "$API_KEY" ]]; then
  echo "WARNING: no API key found. LLM-backed tests will be skipped." >&2
  DO_LLM=false
fi

# --- Resolve the API key env var name for docker -e
ENV_VAR="OPENAI_API_KEY"
case "$PROVIDER" in
  openai)      ENV_VAR="OPENAI_API_KEY" ;;
  anthropic)   ENV_VAR="ANTHROPIC_API_KEY" ;;
  openrouter)  ENV_VAR="OPENROUTER_API_KEY" ;;
  deepseek)    ENV_VAR="DEEPSEEK_API_KEY" ;;
  google|gemini) ENV_VAR="GEMINI_API_KEY" ;;
esac

# --- Helpers
PASS=0
FAIL=0
SKIP=0

ok() {
  echo "  ✅ $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  ❌ $1"
  FAIL=$((FAIL + 1))
}

skip() {
  echo "  ⏭  $1"
  SKIP=$((SKIP + 1))
}

section() {
  echo
  echo "── $1 ──"
}

docker_run_rm() {
  docker run --rm "$@" 2>&1 | rg -v 'internal_logging' || true
}

# --- Determine the env var to pass to the container
ENV_FLAGS=()
if $DO_LLM; then
  ENV_FLAGS=(-e "${ENV_VAR}=${API_KEY}" -e "PI_PROVIDER=${PROVIDER}")
fi

# --- Tests

section "1. Build image"
if $DO_BUILD; then
  if docker build -f Dockerfile_pi -t "$IMAGE" . 2>&1 | tail -3 | rg -q 'naming to'; then
    ok "build succeeded"
  else
    # Re-run to capture the actual error
    build_output=$(docker build -f Dockerfile_pi -t "$IMAGE" . 2>&1 || true)
    if echo "$build_output" | rg -q 'naming to'; then
      ok "build succeeded (cached)"
    else
      fail "build failed"
      echo "$build_output" | tail -10 | sed 's/^/    /' >&2
      exit 1
    fi
  fi
else
  skip "build (skipped by --no-build)"
fi

section "2. Runs as pi-agent user (non-root)"
USER_OUT="$(docker run --rm --entrypoint bash "$IMAGE" -c 'whoami' 2>&1 | rg -v 'internal_logging' || true)"
if [[ "$USER_OUT" == "pi-agent" ]]; then
  ok "user is pi-agent"
else
  fail "expected user 'pi-agent', got '$USER_OUT'"
fi

section "3. HOME is /workspace"
HOME_OUT="$(docker run --rm --entrypoint bash "$IMAGE" -c 'echo $HOME' 2>&1 | rg -v 'internal_logging' || true)"
if [[ "$HOME_OUT" == "/workspace" ]]; then
  ok "HOME=/workspace"
else
  fail "expected HOME=/workspace, got '$HOME_OUT'"
fi

section "4. Working directory is /workspace"
PWD_OUT="$(docker run --rm --entrypoint bash "$IMAGE" -c 'pwd' 2>&1 | rg -v 'internal_logging' || true)"
if [[ "$PWD_OUT" == "/workspace" ]]; then
  ok "workdir is /workspace"
else
  fail "expected /workspace, got '$PWD_OUT'"
fi

section "5. /workspace/.pi/agent exists and is owned by pi-agent"
LS_OUT="$(docker run --rm --entrypoint bash "$IMAGE" -c 'ls -ld /workspace/.pi/agent' 2>&1 | rg -v 'internal_logging' || true)"
if echo "$LS_OUT" | rg -q 'pi-agent.*pi-agent'; then
  ok ".pi/agent owned by pi-agent:pi-agent"
else
  fail ".pi/agent ownership check failed: $LS_OUT"
fi

section "6. pi --version works"
VER_OUT="$(docker run --rm --entrypoint pi "$IMAGE" --version 2>&1 | rg -v 'internal_logging' || true)"
if [[ -n "$VER_OUT" ]]; then
  ok "pi version: $VER_OUT"
else
  fail "pi --version produced no output"
fi

section "7. git and ripgrep are installed"
GIT_OUT="$(docker run --rm --entrypoint bash "$IMAGE" -c 'git --version' 2>&1 | rg -v 'internal_logging' || true)"
if echo "$GIT_OUT" | rg -q 'git version'; then
  ok "git: $GIT_OUT"
else
  fail "git not found: $GIT_OUT"
fi

RG_OUT="$(docker run --rm --entrypoint bash "$IMAGE" -c 'rg --version' 2>&1 | rg -v 'internal_logging' || true)"
if echo "$RG_OUT" | rg -q 'ripgrep'; then
  ok "ripgrep: $(echo "$RG_OUT" | head -1)"
else
  fail "ripgrep not found: $RG_OUT"
fi

section "8. Prompt returns a response (LLM)"
if $DO_LLM; then
  PROMPT_OUT="$(docker run --rm "${ENV_FLAGS[@]}" "$IMAGE" -p "Reply with exactly: validate-ok" 2>&1 | rg -v 'internal_logging' || true)"
  if echo "$PROMPT_OUT" | rg -q 'validate-ok'; then
    ok "prompt returned: $(echo "$PROMPT_OUT" | head -1)"
  else
    fail "prompt did not return expected text: $PROMPT_OUT"
  fi
else
  skip "LLM prompt test (no API key or --no-llm)"
fi

section "9. Bash tool with mounted volume (LLM)"
if $DO_LLM; then
  TMP_DIR="$(mktemp -d)"
  echo "test file" > "$TMP_DIR/test.txt"
  BASH_OUT="$(docker run --rm "${ENV_FLAGS[@]}" -v "$TMP_DIR:/workspace" "$IMAGE" \
    -p "Use the bash tool to run: cat /workspace/test.txt. Tell me what it contains." \
    2>&1 | rg -v 'internal_logging' || true)"
  rm -rf "$TMP_DIR"
  if echo "$BASH_OUT" | rg -q 'test file'; then
    ok "bash tool read mounted file correctly"
  else
    fail "bash tool test failed: $BASH_OUT"
  fi
else
  skip "bash tool test (no API key or --no-llm)"
fi

# --- Summary
echo
echo "════════════════════════════════════════"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Skipped: $SKIP"
echo "════════════════════════════════════════"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
