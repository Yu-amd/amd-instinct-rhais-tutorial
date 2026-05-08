#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RHAIS_IMAGE="${RHAIS_IMAGE:-registry.redhat.io/rhaiis/vllm-rocm-rhel9:3.2.5}"
DEFAULT_MODEL="RedHatAI/Qwen2-72B-Instruct-FP8"

TARGET_INSTANCES="${1:-}"
MODEL="${MODEL:-$DEFAULT_MODEL}"

CONTAINER_PREFIX="${RHAIS_CONTAINER_PREFIX:-rhais}"

NGINX_LISTEN_PORT="${NGINX_LISTEN_PORT:-8080}"
NGINX_UPSTREAM_FILE="${NGINX_UPSTREAM_FILE:-/etc/nginx/conf.d/rhais_upstream.conf}"
# Set SKIP_NGINX=1 to skip upstream config reload (still updates Prometheus).
SKIP_NGINX="${SKIP_NGINX:-0}"

PROMETHEUS_YML="${PROMETHEUS_YML:-${REPO_ROOT}/grafana/prometheus.yml}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-${REPO_ROOT}/grafana/docker-compose.yml}"

COLOR_RESET=$'\033[0m'
COLOR_GREEN=$'\033[0;32m'
COLOR_YELLOW=$'\033[1;33m'
COLOR_RED=$'\033[0;31m'

ok() { printf "%s[OK]%s %s\n" "${COLOR_GREEN}" "${COLOR_RESET}" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "${COLOR_YELLOW}" "${COLOR_RESET}" "$*"; }
err() { printf "%s[ERROR]%s %s\n" "${COLOR_RED}" "${COLOR_RESET}" "$*"; }

if [[ -z "${TARGET_INSTANCES}" ]]; then
  err "Usage: $0 <TARGET_INSTANCES>"
  exit 1
fi

if ! [[ "${TARGET_INSTANCES}" =~ ^[0-9]+$ ]]; then
  err "TARGET_INSTANCES must be an integer; got '${TARGET_INSTANCES}'."
  exit 1
fi

if [[ ! -f "${PROMETHEUS_YML}" ]]; then
  err "Prometheus config not found at: ${PROMETHEUS_YML}"
  exit 1
fi

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO="sudo"
fi

echo "== Scale RHAIS =="
echo "Image: ${RHAIS_IMAGE}"
echo "Model: ${MODEL}"
echo "Target instances: ${TARGET_INSTANCES}"
echo

detect_running_ports() {
  # Container naming convention: ${CONTAINER_PREFIX}-<PORT>
  # We only consider containers that use the expected image.
  podman ps \
    --filter "ancestor=${RHAIS_IMAGE}" \
    --format '{{.Names}}' \
    | while read -r name; do
        if [[ "${name}" == "${CONTAINER_PREFIX}-"* ]]; then
          port="${name##*-}"
          if [[ "${port}" =~ ^[0-9]+$ ]]; then
            echo "${port}"
          fi
        fi
      done
}

sorted_unique_ports() {
  # shellcheck disable=SC2001
  echo "$1" | tr ' ' '\n' | awk 'NF{print}' | sort -n | uniq
}

detect_gpus_round_robin() {
  local -a ids=()
  if command -v rocm-smi >/dev/null 2>&1; then
    local out
    out="$(rocm-smi --showid 2>/dev/null || true)"
    if [[ -n "${out}" ]]; then
      # Parse GPU[0], GPU[1], ...
      mapfile -t ids < <(echo "${out}" | grep -oE 'GPU\[[0-9]+\]' | sed -E 's/.*\[([0-9]+)\].*/\1/' | sort -n | uniq)
    fi
  fi
  if [[ "${#ids[@]}" -eq 0 ]]; then
    warn "rocm-smi parsing failed; defaulting GPU_ID=0" >&2
    ids=(0)
  fi
  echo "${ids[*]}"
}

port_health() {
  local port="$1"
  if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
    echo "healthy"
  else
    echo "unhealthy"
  fi
}

require_nginx_unless_skipped() {
  if [[ "${SKIP_NGINX}" == "1" ]]; then
    return 0
  fi
  if command -v nginx >/dev/null 2>&1; then
    return 0
  fi
  err "nginx is not installed (missing 'nginx' binary)."
  err "Install nginx first (example): sudo apt-get update && sudo apt-get install -y nginx"
  err "Or set SKIP_NGINX=1 to update Prometheus only (no nginx upstream)."
  exit 1
}

write_nginx_config() {
  local -a servers=("$@")

  if ! command -v nginx >/dev/null 2>&1; then
    err "nginx is not installed (missing 'nginx' binary)."
    err "Install nginx first (example): sudo apt-get update && sudo apt-get install -y nginx"
    exit 1
  fi

  local upstream_servers=""
  local p
  for p in "${servers[@]}"; do
    upstream_servers+="  server 127.0.0.1:${p};"$'\n'
  done

  local tmpfile
  tmpfile="$(mktemp)"
  cat > "${tmpfile}" <<EOF
upstream rhaiis_upstream {
${upstream_servers}
}

server {
  listen ${NGINX_LISTEN_PORT};
  location / {
    proxy_pass http://rhaiis_upstream;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
  }
}
EOF

  if [[ -n "${SUDO}" ]]; then
    ${SUDO} cp "${tmpfile}" "${NGINX_UPSTREAM_FILE}"
  else
    cp "${tmpfile}" "${NGINX_UPSTREAM_FILE}"
  fi
  rm -f "${tmpfile}"
}

reload_nginx() {
  if command -v systemctl >/dev/null 2>&1; then
    if [[ -n "${SUDO}" ]]; then
      $SUDO systemctl reload nginx || $SUDO systemctl restart nginx
    else
      systemctl reload nginx || systemctl restart nginx
    fi
  else
    if [[ -n "${SUDO}" ]]; then
      $SUDO nginx -s reload
    else
      nginx -s reload
    fi
  fi
}

update_prometheus_jobs() {
  local -a ports=("$@")

  # Build scrape configs for ports > 8000.
  local block=""
  local port
  for port in "${ports[@]}"; do
    if [[ "${port}" == "8000" ]]; then
      continue
    fi
    block+="  - job_name: vllm-${port}"$'\n'
    block+="    metrics_path: /metrics"$'\n'
    block+="    static_configs:"$'\n'
    block+="      - targets: ['host.docker.internal:${port}']"$'\n'
  done

  # Update prometheus.yml between SCALE_JOBS_START and SCALE_JOBS_END.
  local tmp
  tmp="$(mktemp)"
  awk -v block="$block" '
    $0 ~ /# SCALE_JOBS_START/ {print; print block; skip=1; next}
    $0 ~ /# SCALE_JOBS_END/ {skip=0; print; next}
    skip==1 {next}
    {print}
  ' "${PROMETHEUS_YML}" > "${tmp}"
  mv "${tmp}" "${PROMETHEUS_YML}"
}

restart_prometheus() {
  docker compose -f "${DOCKER_COMPOSE_FILE}" restart prometheus >/dev/null 2>&1 || \
    docker compose -f "${DOCKER_COMPOSE_FILE}" up -d prometheus
}

main() {
  local -a running_ports=()
  mapfile -t running_ports < <(detect_running_ports | sort -n)

  if [[ "${#running_ports[@]}" -eq 0 ]]; then
    warn "No running RHAIS containers found for image ${RHAIS_IMAGE}."
    warn "Start a primary instance first with scripts/01_serve.sh."
    exit 1
  fi

  local current="${#running_ports[@]}"
  echo "Current running RHAIS instances: ${current}"
  echo "Running ports: ${running_ports[*]}"
  echo

  require_nginx_unless_skipped

  if [[ "${current}" -ge "${TARGET_INSTANCES}" ]]; then
    ok "Already running >= target instances; will still refresh nginx + Prometheus config."
  else
    local needed=$((TARGET_INSTANCES - current))
    warn "Need to start ${needed} additional instance(s)."

    local gpu_ids
    gpu_ids="$(detect_gpus_round_robin)"
    read -r -a gpu_id_arr <<< "${gpu_ids}"
    local gpu_count="${#gpu_id_arr[@]}"

    declare -A used=()
    local p
    for p in "${running_ports[@]}"; do
      used["$p"]=1
    done

    local candidate=8001
    local idx="${current}"
    while [[ "${needed}" -gt 0 ]]; do
      if [[ -z "${used[${candidate}]:-}" ]]; then
        local gpu_id="${gpu_id_arr[$((idx % gpu_count))]}"
        warn "Starting new RHAIS on port ${candidate} (GPU_ID=${gpu_id})"
        GPU_ID="${gpu_id}" "${SCRIPT_DIR}/01_serve.sh" "${MODEL}" "${candidate}" >/dev/null
        running_ports+=("${candidate}")
        used["$candidate"]=1
        needed=$((needed - 1))
        idx=$((idx + 1))
      fi
      candidate=$((candidate + 1))
    done
  fi

  # Recompute/sort ports
  mapfile -t running_ports < <(printf "%s\n" "${running_ports[@]}" | sort -n | uniq)

  echo
  if [[ "${SKIP_NGINX}" == "1" ]]; then
    warn "SKIP_NGINX=1 set; skipping nginx upstream update."
  else
    echo "== Updating nginx upstream =="
    write_nginx_config "${running_ports[@]}"
    reload_nginx
    ok "nginx upstream updated (listen port ${NGINX_LISTEN_PORT})"
  fi

  echo
  echo "== Updating Prometheus scrape config =="
  update_prometheus_jobs "${running_ports[@]}"
  restart_prometheus
  ok "Prometheus restarted to pick up new scrape jobs."

  echo
  echo "== Health summary =="
  printf "%-8s %-12s %s\n" "PORT" "HEALTH" "URL"
  for p in "${running_ports[@]}"; do
    local h
    h="$(port_health "${p}")"
    local url="http://127.0.0.1:${p}/health"
    if [[ "${h}" == "healthy" ]]; then
      printf "%-8s %-12s %s\n" "${p}" "${h}" "${url}"
    else
      printf "%-8s %-12s %s\n" "${p}" "${h}" "${url}"
    fi
  done

  echo
  if [[ "${SKIP_NGINX}" != "1" ]]; then
    echo "nginx load balancer: http://127.0.0.1:${NGINX_LISTEN_PORT}/v1/chat/completions"
  fi
  echo "Direct endpoints: http://127.0.0.1:<PORT>/v1/chat/completions"
}

main "$@"

