# Observability Guide (Grafana dashboard for RHAIS)

This document explains what each dashboard panel measures, what “healthy” looks like, what to watch, and what to do when thresholds are breached.

The dashboard uses these metric names from RHAIS (vLLM):
- `vllm:request_success_total`
- `vllm:time_to_first_token_seconds_bucket` (TTFT histogram)
- `vllm:e2e_request_latency_seconds_bucket` (E2E latency histogram)
- `vllm:request_queue_time_seconds_bucket` (queue-time histogram)
- `vllm:time_per_output_token_seconds_bucket` (ITL histogram)
- `vllm:kv_cache_usage_perc`
- `vllm:num_requests_running`
- `vllm:num_requests_waiting`
- `vllm:generation_tokens_total`

## Panel-by-panel guidance

### 1) Success throughput (`vllm:request_success_total`)
What it measures: how many requests per second are successfully served.

Healthy:
- Stable or slowly increasing with load.

Watch:
- Throughput dropping while request latency grows often means the server is saturating.

Action:
- If throughput collapses and latencies rise: scale out or reduce concurrency.

### 2) TTFT P99 (ms) — thresholds
Query: `vllm:time_to_first_token_seconds_bucket` quantile 0.99, multiplied into ms.

Thresholds used in the dashboard:
- Yellow: `TTFT P99 > 500ms`
- Red: `TTFT P99 > 2000ms`

What TTFT means:
- Time to first token: prompt processing + scheduling + initial decode until the first output token.

Healthy:
- Low, stable TTFT P99 under expected traffic.

Watch:
- TTFT P99 rising without corresponding increases in queue time can indicate prompt-heavy workloads or CPU-side bottlenecks.

Action when breached:
- Prefer scaling out (more instances/replicas) when TTFT P99 stays red for multiple minutes.
- If you’re running load tests, reduce user concurrency to confirm the server is capacity-bound.

### 3) ITL P99 (ms) — thresholds
Query: `vllm:time_per_output_token_seconds_bucket` quantile 0.99, multiplied into ms.

Thresholds used in the dashboard:
- Yellow: `ITL P99 > 50ms`
- Red: `ITL P99 > 100ms`

What ITL means:
- “Internal token latency”: how long it takes to produce each output token (decode speed).

Healthy:
- ITL P99 remains low and relatively constant.

Watch:
- ITL trending upward often correlates with GPU saturation and KV-cache pressure.

Action when breached:
- If ITL stays high and KV cache usage is also high: scale out.
- If ITL is high but KV cache is not: check request mix (long outputs) and consider lowering `max_tokens` / concurrency.

### 4) E2E latency P99 (ms)
Query: `vllm:e2e_request_latency_seconds_bucket` quantile 0.99, multiplied into ms.

Healthy:
- Low E2E P99 for your SLA target.

Watch:
- If E2E rises in lockstep with TTFT: scheduling/prompt stage is the bottleneck.
- If E2E rises while TTFT is stable: decode/ITL or queueing is the bottleneck.

Action:
- Use panels 5/6/7/8 to decide whether it’s queueing, KV cache pressure, or running-work saturation.

### 5) Queue time P99 (ms)
Query: `vllm:request_queue_time_seconds_bucket` quantile 0.99.

What it means:
- How long requests spend waiting before they start service.

Healthy:
- Queue-time P99 stays low under steady traffic.

Watch:
- Waiting grows while running remains flat -> queue is building (capacity reached).

Action:
- Scale out when queue-time P99 remains elevated.

### 6) KV cache usage (%) — thresholds and scale-out trigger
Query: `avg(vllm:kv_cache_usage_perc)`.

Thresholds used in the dashboard:
- Yellow: `KV cache > 70%`
- Red: `KV cache > 90%` (scale out)

What it means:
- KV cache is the memory used for attention keys/values for in-flight and recent tokens.

Healthy:
- Values remain well below 70% during steady load.

Watch:
- KV cache usage drifting upward with time usually means longer sequences or higher concurrency.

Action when breached:
- If you hit `> 90%`, the server is close to OOM or will start throttling/scheduling delays.
- Scale out immediately:
  - Run `./scripts/02_scale.sh <TARGET_INSTANCES>`
  - Re-check KV cache, TTFT P99, and queue-time after scaling.

### 7) Requests running (`vllm:num_requests_running`)
Healthy:
- Running count is stable for your workload, and TTFT/ITL remain within thresholds.

Watch:
- Running count climbing with TTFT rising can mean you are saturating the GPU and the scheduler is delaying prompts.

Action:
- If running climbs and waiting also climbs: scale out.

### 8) Requests waiting (`vllm:num_requests_waiting`)
Healthy:
- Waiting should not grow unbounded during steady traffic.

Watch:
- Waiting rises quickly while running is flat: the system is capacity-bound.

Action:
- Scale out or reduce offered load.

### 9) Generated tokens rate (`vllm:generation_tokens_total`)
Healthy:
- Token rate increases with more offered load until reaching a plateau.

Watch:
- Token rate plateauing while TTFT/ITL rise suggests the model is compute/memory saturated.

Action:
- Scale out or adjust request mix / `max_tokens`.

### 10) TTFT P50 (ms), 11) ITL P50 (ms), 12) E2E P50 (ms)
Why they exist:
- P99 highlights tail latency; P50 helps you tell if changes are systemic or only affect outliers.

Healthy patterns:
- When P99 breaches, P50 is often trending up too (but more slowly).

Action:
- Use together with P99 and KV cache usage to decide whether you need scaling vs workload tuning.

## Practical response playbook

If you see sustained breaches:
- `TTFT P99 > 500ms` (yellow) and especially `> 2000ms` (red): scale out and/or reduce prompt concurrency.
- `ITL P99 > 50ms` (yellow) / `> 100ms` (red): scale out and check workload/output length.
- `KV cache usage > 70%` (yellow) / `> 90%` (red): scale out immediately.

Then confirm after scaling:
- KV cache usage stabilizes (no sustained climb)
- TTFT P99 and queue-time P99 fall back toward baseline
- Waiting stops growing unbounded

