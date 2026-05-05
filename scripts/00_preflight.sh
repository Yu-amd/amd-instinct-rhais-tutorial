#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RHAIS_IMAGE="${RHAIS_IMAGE:-registry.redhat.io/rhaiis/vllm-rocm-rhel9:3.2.5}"
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$USER}}"

COLOR_RESET=$'\033[0m'
COLOR_GREEN=$'\033[0;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_RED=$'\033[0;31m'

ok() { printf "%s[PASS]%s %s\n" "${COLOR_GREEN}" "${COLOR_RESET}" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "${COLOR_YELLOW}" "${COLOR_RESET}" "$*"; }
err() { printf "%s[FAIL]%s %s\n" "${COLOR_RED}" "${COLOR_RESET}" "$*"; }

pass_count=0
fail_count=0

run_check() {
  local name="$1"
  shift
  if "$@"; then
    ok "$name"
    pass_count=$((pass_count + 1))
  else
    err "$name"
    fail_count=$((fail_count + 1))
  fi
}

echo "== RHAIS preflight =="
echo "Image: ${RHAIS_IMAGE}"
echo "Target user (for group checks): ${TARGET_USER}"
echo

VIDEO_GID="$(getent group video | cut -d: -f3 || true)"
RENDER_GID="$(getent group render | cut -d: -f3 || true)"

echo "== Hardware + permissions =="

run_check "podman is installed" podman --version >/dev/null 2>&1

run_check "/dev/kfd exists" test -e /dev/kfd
run_check "/dev/dri exists" test -e /dev/dri

if [[ -z "${VIDEO_GID}" || -z "${RENDER_GID}" ]]; then
  fail_count=$((fail_count + 1))
  err "Could not resolve GIDs for groups 'video' and/or 'render' (need getent group video/render)"
else
  ok "Resolved group GIDs (video=${VIDEO_GID}, render=${RENDER_GID})"
  pass_count=$((pass_count + 1))
fi

run_check "user is in video group" bash -lc "id -nG '${TARGET_USER}' | grep -qw video"
run_check "user is in render group" bash -lc "id -nG '${TARGET_USER}' | grep -qw render"

echo
echo "== Containers =="
run_check "RHAIS image is available locally" bash -lc "podman image exists '${RHAIS_IMAGE}'"

echo
echo "== Optional: HuggingFace token =="
HF_TOKEN_VALUE="${HUGGING_FACE_HUB_TOKEN:-${HF_HUB_TOKEN:-${HF_TOKEN:-}}}"
HF_TOKEN_SOURCE=""
if [[ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
  HF_TOKEN_SOURCE="HUGGING_FACE_HUB_TOKEN"
elif [[ -n "${HF_HUB_TOKEN:-}" ]]; then
  HF_TOKEN_SOURCE="HF_HUB_TOKEN"
elif [[ -n "${HF_TOKEN:-}" ]]; then
  HF_TOKEN_SOURCE="HF_TOKEN"
fi

if [[ -z "${HF_TOKEN_VALUE}" ]]; then
  warn "No Hugging Face token env var detected (checked: HUGGING_FACE_HUB_TOKEN, HF_HUB_TOKEN, HF_TOKEN). This tutorial’s model may still work without one, but if downloads fail you may need a token."
else
  ok "Hugging Face token is set via ${HF_TOKEN_SOURCE} (optional)"
  pass_count=$((pass_count + 1))
fi

echo
echo "== Monitoring stack requirements =="
if docker info >/dev/null 2>&1; then
  ok "Docker is available"
  pass_count=$((pass_count + 1))
else
  warn "Docker is not available/running. Observability stack (Prometheus+Grafana) will fail until Docker works."
fi

echo
echo "== Summary =="
printf "Passed: %s\nFailed: %s\n" "${pass_count}" "${fail_count}"

if [[ "${fail_count}" -gt 0 ]]; then
  echo
  err "Preflight failed. Fix the failed items above and re-run."
  exit 1
fi

ok "Preflight checks passed."
exit 0

