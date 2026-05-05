#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RHAIS_IMAGE="${RHAIS_IMAGE:-registry.redhat.io/rhaiis/vllm-rocm-rhel9:3.2.5}"
DEFAULT_MODEL="RedHatAI/Qwen2-72B-Instruct-FP8"
DEFAULT_PORT="8000"

MODEL="${1:-$DEFAULT_MODEL}"
PORT="${2:-$DEFAULT_PORT}"

CONTAINER_PREFIX="${RHAIS_CONTAINER_PREFIX:-rhais}"
CONTAINER_NAME="${CONTAINER_PREFIX}-${PORT}"

HF_CACHE_DIR="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"
SHM_SIZE="${SHM_SIZE:-8GB}"

COLOR_RESET=$'\033[0m'
COLOR_GREEN=$'\033[0;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_RED=$'\033[0;31m'

ok() { printf "%s[OK]%s %s\n" "${COLOR_GREEN}" "${COLOR_RESET}" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "${COLOR_YELLOW}" "${COLOR_RESET}" "$*"; }
err() { printf "%s[ERROR]%s %s\n" "${COLOR_RED}" "${COLOR_RESET}" "$*"; }

echo "== Serve RHAIS =="
echo "Model: ${MODEL}"
echo "Port:  ${PORT}"
echo "Container: ${CONTAINER_NAME}"

VIDEO_GID="$(getent group video | cut -d: -f3)"
RENDER_GID="$(getent group render | cut -d: -f3)"

if [[ -z "${VIDEO_GID}" || -z "${RENDER_GID}" ]]; then
  err "Could not resolve group GIDs for 'video'/'render'."
  err "Run the group permission fix from the README and re-login."
  exit 1
fi

GPU_ID="${GPU_ID:-}"

stop_existing() {
  if podman container exists "${CONTAINER_NAME}" >/dev/null 2>&1; then
    warn "Container exists; removing ${CONTAINER_NAME}"
    podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
}

start_container() {
  local -a env_args=()
  if [[ -n "${GPU_ID}" ]]; then
    env_args+=(-e "HIP_VISIBLE_DEVICES=${GPU_ID}" -e "ROCR_VISIBLE_DEVICES=${GPU_ID}")
  fi

  # RHAIS image entrypoint is vLLM serve directly; pass model args as container arguments.
  podman run -d \
    --name "${CONTAINER_NAME}" \
    --security-opt=label=disable \
    --device=/dev/kfd \
    --device=/dev/dri \
    --group-add "${VIDEO_GID}" \
    --group-add "${RENDER_GID}" \
    --shm-size="${SHM_SIZE}" \
    --network=host \
    -v "${HF_CACHE_DIR}:/root/.cache/huggingface:rw" \
    "${env_args[@]}" \
    "${RHAIS_IMAGE}" \
    --model "${MODEL}" \
    --dtype auto \
    --host 0.0.0.0 \
    --port "${PORT}"
}

poll_health() {
  local url="http://127.0.0.1:${PORT}/health"
  echo "== Waiting for health =="
  for i in $(seq 1 60); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      ok "Healthy: ${url}"
      return 0
    fi
    sleep 2
  done
  err "Health check timed out: ${url}"
  echo
  err "Last 200 lines of podman logs:"
  podman logs --tail 200 "${CONTAINER_NAME}" || true
  return 1
}

run_test_completion() {
  echo "== Test completion =="
  local url="http://127.0.0.1:${PORT}/v1/chat/completions"
  # Small prompt to quickly validate request/response.
  local resp
  resp="$(curl -sS -X POST "${url}" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "'"${MODEL}"'",
      "messages": [{"role":"user","content":"Say hello in a single sentence."}],
      "temperature": 0.2,
      "max_tokens": 16
    }' || true)"
  if [[ -z "${resp}" ]]; then
    err "Test completion returned empty response."
    return 1
  fi
  ok "Test completion succeeded (response received)."
}

echo
stop_existing

echo "== Starting container =="
start_container >/dev/null

poll_health

run_test_completion

echo
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
if [[ -z "${HOST_IP}" ]]; then
  HOST_IP="127.0.0.1"
fi

echo "Endpoint: http://${HOST_IP}:${PORT}"
echo "Docs: use /health, /v1/models, /v1/chat/completions"

ok "RHAIS serve complete."

