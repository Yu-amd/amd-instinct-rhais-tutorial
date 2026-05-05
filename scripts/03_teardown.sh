#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RHAIS_IMAGE="${RHAIS_IMAGE:-registry.redhat.io/rhaiis/vllm-rocm-rhel9:3.2.5}"

DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-${REPO_ROOT}/grafana/docker-compose.yml}"

COLOR_RESET=$'\033[0m'
COLOR_GREEN=$'\033[0;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_RED=$'\033[0;31m'

ok() { printf "%s[OK]%s %s\n" "${COLOR_GREEN}" "${COLOR_RESET}" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "${COLOR_YELLOW}" "${COLOR_RESET}" "$*"; }
err() { printf "%s[ERROR]%s %s\n" "${COLOR_RED}" "${COLOR_RESET}" "$*"; }

echo "== Teardown =="
echo "RHAIS image: ${RHAIS_IMAGE}"

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO="sudo"
fi

echo
echo "== Stopping/removing RHAIS containers =="

mapfile -t containers < <(podman ps -a --filter "ancestor=${RHAIS_IMAGE}" --format '{{.Names}}' | sort -u)

if [[ "${#containers[@]}" -eq 0 ]]; then
  warn "No RHAIS containers found for image ${RHAIS_IMAGE}."
else
  for c in "${containers[@]}"; do
    warn "Removing podman container: ${c}"
    podman rm -f "${c}" >/dev/null 2>&1 || true
  done
  ok "Removed ${#containers[@]} container(s)."
fi

echo
echo "== Stopping monitoring stack =="

if [[ -f "${DOCKER_COMPOSE_FILE}" ]]; then
  docker compose -f "${DOCKER_COMPOSE_FILE}" down >/dev/null 2>&1 || docker-compose -f "${DOCKER_COMPOSE_FILE}" down >/dev/null 2>&1 || true
  ok "Monitoring stack stopped."
else
  warn "Docker compose file not found at: ${DOCKER_COMPOSE_FILE}"
fi

echo
warn "Cost reminder: destroy the DigitalOcean droplet to stop GPU charges."
ok "Teardown complete."

