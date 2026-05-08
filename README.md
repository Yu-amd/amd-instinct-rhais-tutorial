# AMD Instinct + RHAIS Tutorial (DigitalOcean MI300X)

This repository is a practitioner’s guide for running **Red Hat AI Inference Server (RHAIS)** on a **DigitalOcean (DO) AMD Instinct MI300X GPU droplet** using **Podman** (for inference) plus **Prometheus + Grafana** (for observability).

The target audience is **ML engineers / platform engineers** with basic Linux experience, but who may not have used RHAIS before.

## Section 0: Clone this repository

On the machine where you plan to run the tutorial steps:

```bash
git clone https://github.com/Yu-amd/amd-instinct-rhais-tutorial.git
cd amd-instinct-rhais-tutorial
```

If you already have the repo, pull latest changes before starting:

```bash
git pull
```

## Prerequisites

You’ll need:

1. A **DigitalOcean account** with access to GPU Droplets in the **ATL region**.
2. A **Red Hat account** with access to a **RHAIS trial** (used for pulling the RHAIS container image).
3. A **HuggingFace account** (to download models). For this tutorial’s model, anonymous download may work, but setting an HF token is recommended to avoid rate limits/auth issues.
4. Basic Linux knowledge (SSH, `sudo`, editing/reading logs, `curl`).
5. Tools locally on the droplet:
   - `podman`
   - `curl`
   - `docker` (for the monitoring stack)
   - `rocm-smi` (usually installed/enabled on the DO ROCm image)

> Important platform detail (Ubuntu DO droplets):
>
> The GPU device nodes exist, but **Podman must be able to pass the ROCm GPU “groups”** into the container. On these Ubuntu droplets you must add the user to `video` and `render`:
>
> ```bash
> sudo usermod -aG video root && sudo usermod -aG render root
> ```
>
> If your DO SSH user is not `root`, replace `root` with your username.

## Section 1: Provision a GPU Droplet

1. In DigitalOcean, create a new **Droplet**.
2. Choose:
   - Region: **ATL (Atlanta)**
   - Hardware/accelerator: **AMD Instinct MI300X**
   - OS: **Ubuntu 22.04** with **ROCm** (use the DO ROCm image)
3. Attach your SSH keys and create the droplet.

After provisioning, SSH into it:

```bash
ssh root@<DROPLET_IP>
```

## Section 2: Environment setup

### 2.1 Install Podman (if needed)

On Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y podman
```

Verify:

```bash
podman --version
```

### 2.2 Log into the Red Hat registry

Login to `registry.redhat.io` so you can pull the RHAIS image:

```bash
podman login registry.redhat.io
```

Use your Red Hat username + password/API token as prompted.

### 2.3 Configure Hugging Face token (recommended)

Even though this tutorial's model may be downloadable without a token, setting one up makes downloads more reliable and is required for many gated/private models.

1. Create a token in Hugging Face settings:
   - https://huggingface.co/settings/tokens
2. Export it in your shell:

```bash
export HUGGING_FACE_HUB_TOKEN="<your_hf_token>"
```

3. Persist it for future sessions (optional):

```bash
echo 'export HUGGING_FACE_HUB_TOKEN="<your_hf_token>"' >> ~/.bashrc
source ~/.bashrc
```

4. Quick check:

```bash
python3 - <<'PY'
import os
print("HF token set:", bool(os.getenv("HUGGING_FACE_HUB_TOKEN")))
PY
```

### 2.4 Fix Podman GPU group permissions (required)

The tutorial uses these group IDs dynamically:

```bash
VIDEO_GID="$(getent group video | cut -d: -f3)"
RENDER_GID="$(getent group render | cut -d: -f3)"
echo "VIDEO_GID=$VIDEO_GID"
echo "RENDER_GID=$RENDER_GID"
```

Apply the group membership fix:

```bash
sudo usermod -aG video root && sudo usermod -aG render root
```

Then log out/in (or `newgrp`) so group membership takes effect:

```bash
newgrp video || true
newgrp render || true
```

### 2.5 Pull the RHAIS image

```bash
podman pull registry.redhat.io/rhaiis/vllm-rocm-rhel9:3.2.5
```

## Section 3: Run a single RHAIS instance (Qwen2-72B FP8)

### 3.1 Pre-flight checks

Run:

```bash
./scripts/00_preflight.sh
```

### 3.2 Start the server

Set model + port:

```bash
export MODEL="RedHatAI/Qwen2-72B-Instruct-FP8"
export PORT=8000

# If 8000 is already in use, pick another port (for example 8001).
if ss -ltn "sport = :${PORT}" | awk 'NR>1{found=1} END{exit !found}'; then
  echo "Port ${PORT} is already in use; switching to 8001"
  export PORT=8001
fi

export VIDEO_GID="$(getent group video | cut -d: -f3)"
export RENDER_GID="$(getent group render | cut -d: -f3)"

export HF_CACHE_DIR="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"
mkdir -p "${HF_CACHE_DIR}"
```

RHAIS uses **vLLM as its entrypoint**. That means you pass vLLM arguments as **container arguments** (i.e., after the image name). In this tutorial we use **`--dtype auto`** for the FP8 quantized model.

Run the container:

```bash
podman rm -f "rhais-${PORT}" 2>/dev/null || true

podman run -d \
  --name "rhais-${PORT}" \
  --security-opt=label=disable \
  --device=/dev/kfd \
  --device=/dev/dri \
  --group-add "${VIDEO_GID}" \
  --group-add "${RENDER_GID}" \
  --shm-size=8GB \
  --network=host \
  -e HF_HUB_OFFLINE=false \
  -e TRANSFORMERS_OFFLINE=false \
  -e HF_DATASETS_OFFLINE=false \
  -e HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN:-${HF_HUB_TOKEN:-${HF_TOKEN:-}}}" \
  -v "${HF_CACHE_DIR}:/root/.cache/huggingface:rw" \
  registry.redhat.io/rhaiis/vllm-rocm-rhel9:3.2.5 \
  --model "${MODEL}" \
  --dtype auto \
  --host 0.0.0.0 \
  --port "${PORT}"
```

Notes:
 - The container is on `--network=host`, so the vLLM server listens directly on the host port.
 - The `HF_CACHE_DIR` mount ensures model weights are cached. Subsequent instances of the same model typically start in ~30s.
 - Offline environment flags are explicitly disabled above so first-run model downloads work even if your shell has offline-related vars set.

### 3.3 Wait for startup (container logs)

If you open a new shell, previously exported variables (like `PORT`) will be empty. Re-export them before following logs:

```bash
export MODEL="${MODEL:-RedHatAI/Qwen2-72B-Instruct-FP8}"
export PORT="${PORT:-8000}"
```

Stream vLLM/RHAIS logs until startup finishes (Ctrl+C stops following; the server keeps running):

```bash
podman logs -f "rhais-${PORT:-8000}"
```

Wait until the logs show **Application startup complete.** (Uvicorn prints this when the API server is ready). Large models may take several minutes on first load or download.

If you prefer not to follow indefinitely, inspect recent output instead:

```bash
podman logs --tail 200 "rhais-${PORT:-8000}"
```

### 3.4 Send a test completion

This uses the OpenAI-compatible `/v1/chat/completions` endpoint and does **not** require an HF token for this model.

```bash
curl -sS -X POST "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"${MODEL}"'",
    "messages": [
      {"role": "user", "content": "Write a short haiku about AMD Instinct."}
    ],
    "temperature": 0.7,
    "max_tokens": 64
  }'
```

### 3.5 List models

```bash
curl -sS "http://127.0.0.1:${PORT}/v1/models" | head -c 4000
echo
```

## Section 4: Observability (Prometheus + Grafana)

This section starts:
- **Prometheus** to scrape RHAIS’ `/metrics`
- **Grafana** to visualize RHAIS’ vLLM metrics

### 4.1 Start monitoring stack

From the repo root:

```bash
# Use the same port your RHAIS server is actually running on.
export PORT="${PORT:-8000}"

# Keep Prometheus scrape target aligned with the active RHAIS port.
sed -i -E "s#(targets: \\['host\\.docker\\.internal:)[0-9]+('\\])#\\1${PORT}\\2#" grafana/prometheus.yml
```

Start the monitoring services:

```bash
docker compose -f grafana/docker-compose.yml up -d
```

Wait for Prometheus and Grafana to come up:

```bash
docker compose -f grafana/docker-compose.yml ps
```

Verify Prometheus can scrape the active RHAIS target (must show `health` as `up`):

```bash
curl -s "http://localhost:9090/api/v1/targets" | jq -r '
  .data.activeTargets[] |
  select(.labels.job=="vllm-primary") |
  [.scrapeUrl, .health, .lastError] | @tsv
'
```

Grafana UI:
 - `http://<DROPLET_IP>:3000`
 - Default credentials (in this repo’s compose file): `admin` / `admin`

### 4.2 Datasource + dashboard provisioning

This repo provisions both:
- datasource `Prometheus` with fixed UID `prometheus`
- dashboard JSON that references datasource UID `prometheus`

So you do **not** need manual datasource UID substitution or API dashboard import.

If you updated this repo from an older revision, restart Grafana so provisioned datasource settings are reloaded:

```bash
docker compose -f grafana/docker-compose.yml restart grafana
```

Quick verification:

```bash
curl -s "http://admin:admin@localhost:3000/api/datasources" | jq -r '.[] | [.name,.uid,.type] | @tsv'
```

Expected output should include:

```text
Prometheus    prometheus    prometheus
```

### 4.3 What you should see (key RHAIS/vLLM metrics)

RHAIS exposes vLLM metrics via `/metrics` on the **same port as the inference server**.

This tutorial’s Grafana dashboard visualizes:
- `vllm:request_success_total`
- `vllm:time_to_first_token_seconds_bucket`
- `vllm:e2e_request_latency_seconds_bucket`
- `vllm:kv_cache_usage_perc`
- `vllm:num_requests_running`
- `vllm:num_requests_waiting`
- `vllm:generation_tokens_total`
- `vllm:time_per_output_token_seconds_bucket`
- `vllm:request_queue_time_seconds_bucket`

Grafana panels:
1. Success throughput
2. TTFT P99 (ms) with thresholds
3. ITL (time-per-output-token) P99 (ms) with thresholds
4. E2E latency P99 (ms)
5. Queue time P99 (ms)
6. KV cache usage (%)
7. Requests running
8. Requests waiting
9. Tokens generated
10. TTFT P50 (ms)
11. ITL P50 (ms)
12. E2E latency P50 (ms)

Quick panel guide (what “good” looks like):
- Success throughput (`vllm:request_success_total`): stable or rising throughput; drops usually indicate saturation.
- TTFT P99 (`vllm:time_to_first_token_seconds_bucket`): tail prompt-to-first-token latency. Thresholds: yellow `>500ms`, red `>2000ms`.
- ITL P99 (`vllm:time_per_output_token_seconds_bucket`): per-output-token decode latency. Thresholds: yellow `>50ms`, red `>100ms`.
- E2E latency P99 (`vllm:e2e_request_latency_seconds_bucket`): end-to-end tail latency; correlate with TTFT/ITL.
- Queue time P99 (`vllm:request_queue_time_seconds_bucket`): how long requests wait before starting. Rising queue time indicates capacity limits.
- KV cache usage (`vllm:kv_cache_usage_perc`): tail-serving memory pressure. Thresholds: yellow `>70%`, red `>90%` (scale out).
- Requests running (`vllm:num_requests_running`): currently being served; should stabilize under steady load.
- Requests waiting (`vllm:num_requests_waiting`): queued backlog; if it grows, you’re under-provisioned.
- Tokens generated (`vllm:generation_tokens_total`): output throughput; often plateaus as the server saturates.
- TTFT P50 / ITL P50 / E2E P50: medians to distinguish outlier/tail issues (P99) from system-wide slowdowns.

For deeper explanations and what action to take when thresholds are breached, read `docs/observability.md`.

## Section 5: Load testing with Locust

This tutorial includes a Locust scenario that issues:
- short completions (task weight `8`)
- long completions (task weight `2`)
- health checks (task weight `1`)

### 5.1 Install Locust

On the droplet (or your dev machine pointed at the droplet):

```bash
python3 -m pip install --user locust
```

### 5.2 Run Locust (example)

Target host should be the RHAIS endpoint or nginx load balancer endpoint (if you enabled scaling+nginx).

Direct to RHAIS on your active `PORT`:

```bash
locust -f loadtest/locust_inference.py \
  --headless \
  --host "http://<DROPLET_IP>:${PORT}" \
  -u 50 -r 5 -t 3m
```

Interpretation hints:
- If **Grafana TTFT P99** rises quickly, the server is saturating.
- If **requests waiting** rises while running stays flat, queueing is growing.
- If **KV cache usage** approaches the configured memory pressure, you may need to scale out.

## Section 6: Scaling to multiple instances

Scaling in this tutorial means starting additional RHAIS/vLLM servers on additional ports.

We assume you already have:
- a primary instance from Section 3 (typically `8000`, unless you switched ports)
- monitoring stack running from Section 4

### 6.1 Detect available GPUs

On the DO MI300X ROCm image:

```bash
rocm-smi --showid
```

Count GPUs and decide how many instances you can fit per GPU based on HBM3 size (see Section 7 for the reference table).

### 6.2 Scale out

**Install nginx first (Ubuntu).** `02_scale.sh` writes `/etc/nginx/conf.d/rhais_upstream.conf` and reloads nginx for load balancing across ports. The script checks for `nginx` before starting new instances so you do not spend time bringing up replicas only to fail at the nginx step.

```bash
sudo apt-get update
sudo apt-get install -y nginx
```

Verify:

```bash
command -v nginx && nginx -v
```

Run scaling (example: 8 total RHAIS containers, including the primary on `8000`):

```bash
./scripts/02_scale.sh <TARGET_INSTANCES>
```

Behavior:
- Detects currently running RHAIS containers for the configured image
- Starts additional replicas on sequential ports `8001..800N`
- Updates an nginx upstream configuration and reloads nginx
- Updates Prometheus scrape jobs for new ports and reloads Prometheus
- Prints a health summary table for all ports

Notes:
- You need `sudo` (or root) so the script can install the upstream file under `/etc/nginx/conf.d/` and reload the service.
- Default nginx listen port is `8080` (override via `NGINX_LISTEN_PORT` when running the script).
- If you only want to refresh Prometheus scrape jobs and skip nginx entirely: `SKIP_NGINX=1 ./scripts/02_scale.sh <TARGET_INSTANCES>`.

Access:
- RHAIS remains reachable directly on each port
- After nginx upstream update, you can also use nginx for load distribution (nginx listens on the configured port in the script)

### 6.3 Prometheus and host networking detail

Prometheus runs in Docker, while inference runs on Podman with `--network=host`.

To bridge Docker->host networking reliably, this repo’s `grafana/docker-compose.yml` includes:
- an `extra_hosts` entry for `host.docker.internal`
- Prometheus scrape targets use `host.docker.internal:<PORT>`

### 6.4 Scaling formula (how to decide TARGET_INSTANCES)

Use Section 7’s reference table and/or this rule of thumb:

```text
instances_per_gpu = floor( (HBM3_GiB * utilization_factor) / memory_per_instance_GiB )
```

Then:

```text
total_instances ~= instances_per_gpu * num_gpus
```

The table below uses:
- MI300X HBM3: `192 GiB` per GPU
- utilization headroom factor: `0.85`

## Section 7: Scaling formula reference table

These are **approximate** capacity planning numbers based on weights in FP8/FP16 (plus a small overhead factor). Real capacity will vary with vLLM settings (max tokens, batch sizing, KV cache behavior, etc.).

Assumptions used for planning:
- MI300X HBM3 per GPU: `192 GiB`
- Headroom factor: `0.85`
- FP8 weight overhead factor: `1.15`
- FP16 weight overhead factor: `1.10`

| Model | Weight memory FP8 (GiB) | Instances/GPU (FP8) | Weight memory FP16 (GiB) | Instances/GPU (FP16) | Instances/8-GPU node (FP8) | Instances/8-GPU node (FP16) |
|---|---:|---:|---:|---:|---:|---:|
| 7B | ~7.5 | ~21 | ~14.3 | ~11 | ~168 | ~88 |
| 13B | ~13.9 | ~11 | ~26.6 | ~6 | ~88 | ~48 |
| 34B | ~36.4 | ~4 | ~69.7 | ~2 | ~32 | ~16 |
| 70B/72B | ~77.1 | ~2 | ~147.5 | ~1 | ~16 | ~8 |

For Qwen2-72B FP8 specifically, the planning assumption suggests roughly **2 instances per GPU** if weights dominate memory; you should confirm with actual Grafana KV cache + latency behavior.

## Section 8: Teardown

Stop everything created by this tutorial:

```bash
./scripts/03_teardown.sh
```

Then destroy the droplet in DigitalOcean when you are done (to avoid incurring GPU costs).

---

## Troubleshooting

### No HIP GPUs are available (Podman/container sees no devices)

Symptom:
- Container logs show errors like “No HIP GPUs are available”.

Fix:
1. Confirm the host has the groups:
   ```bash
   getent group video
   getent group render
   ```
2. Apply the required group membership fix (Ubuntu DO droplets):
   ```bash
   sudo usermod -aG video root && sudo usermod -aG render root
   ```
3. Log out and back in so group membership takes effect.
4. Re-run `./scripts/00_preflight.sh`.

### registry auth failures (cannot pull RHAIS image)

Fix:
1. Re-run:
   ```bash
   podman login registry.redhat.io
   ```
2. Verify you can pull:
   ```bash
   podman pull registry.redhat.io/rhaiis/vllm-rocm-rhel9:3.2.5
   ```

### Model download timeouts

Symptoms:
- Long stalls during container startup while downloading weights.

Fix:
1. Ensure you have stable outbound connectivity from the droplet.
2. Confirm `HF_CACHE_DIR` is mounted (weights cache in the volume mount).
3. Restart the server once network is stable; cached weights usually reduce subsequent startup to ~30s.

### nginx fails to start or reload (`./scripts/02_scale.sh`)

Symptoms:
- `nginx.service is not active`, `cannot reload`, or `Job for nginx.service failed`.

Fix:
1. Validate configuration (includes `/etc/nginx/conf.d/rhais_upstream.conf` from the tutorial):
   ```bash
   sudo nginx -t
   ```
2. Read the service log:
   ```bash
   sudo journalctl -xeu nginx.service --no-pager | tail -80
   ```
3. **`nginx -t` can pass while systemd start still fails.** Common causes:
   - **Port 80 in use.** Ubuntu enables `/etc/nginx/sites-enabled/default`, which listens on `:80`. If another daemon already holds `:80`, nginx exits immediately even though `/etc/nginx/nginx.conf` looks valid. `./scripts/02_scale.sh` removes that symlink once (see script warnings); you can undo with `sudo ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default`. To preserve the stock site: `DISABLE_UBUNTU_DEFAULT_SITE=0 ./scripts/02_scale.sh 8`.
   - **LB port clash:** check `sudo ss -ltn 'sport = :8080'` (tutorial default LB port).
4. If **`address already in use`** on the load-balancer port, pick a free port and re-run scaling (default is `8080`):
   ```bash
   NGINX_LISTEN_PORT=18080 ./scripts/02_scale.sh 8
   ```
5. If nginx was never enabled after install:
   ```bash
   sudo systemctl enable --now nginx
   ```

### Prometheus not scraping (no metrics / missing panels)

Common cause:
- `host.docker.internal` does not resolve to the correct gateway in your environment.

Fix:
1. Verify Prometheus’ scrape target is reachable from the Docker network:
   ```bash
   curl -sS "http://host.docker.internal:${PORT:-8000}/metrics" | head -n 5
   ```
2. Ensure `grafana/docker-compose.yml` contains the `extra_hosts` entry for `host.docker.internal`.
3. Restart monitoring stack:
   ```bash
   docker compose -f grafana/docker-compose.yml restart prometheus
   ```

### Grafana shows panels but “no data” (datasource/provisioning mismatch)

Cause:
- Grafana was started before datasource provisioning changes (or has stale state), so datasource UID does not match dashboard expectations.

Fix:
1. Restart Grafana and Prometheus:
   ```bash
   docker compose -f grafana/docker-compose.yml restart grafana prometheus
   ```
2. Verify datasource UID is `prometheus`:
   ```bash
   curl -s "http://admin:admin@localhost:3000/api/datasources" | jq -r '.[] | [.name,.uid,.type] | @tsv'
   ```
3. Verify Prometheus target is `up` and scrape URL points to your active port:
   ```bash
   curl -s "http://localhost:9090/api/v1/targets" | jq -r '.data.activeTargets[] | [.labels.job,.scrapeUrl,.health,.lastError] | @tsv'
   ```

