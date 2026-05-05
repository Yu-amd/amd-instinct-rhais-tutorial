"""
Locust scenario for RHAIS/vLLM OpenAI-compatible endpoints.

How to run (headless):

  locust -f loadtest/locust_inference.py \
    --headless \
    --host "http://<DROPLET_IP>:8000" \
    -u 50 -r 5 -t 3m

How to run with a custom user count:

  -u 10 -r 2 means: start with 10 users, ramp up by 2 users per second
  -t 2m means: run for 2 minutes
"""

from locust import HttpUser, between, task


MODEL_NAME = "RedHatAI/Qwen2-72B-Instruct-FP8"


class InferenceUser(HttpUser):
    """
    Weighted mix:
      - short completion: weight 8
      - long completion: weight 2
      - health check: weight 1
    """

    wait_time = between(0.2, 0.8)

    @task(8)
    def short_completion(self):
        self.client.post(
            "/v1/chat/completions",
            json={
                "model": MODEL_NAME,
                "messages": [{"role": "user", "content": "Summarize AMD Instinct in one sentence."}],
                "temperature": 0.2,
                "max_tokens": 64,
            },
            timeout=60,
        )

    @task(2)
    def long_completion(self):
        self.client.post(
            "/v1/chat/completions",
            json={
                "model": MODEL_NAME,
                "messages": [
                    {
                        "role": "user",
                        "content": (
                            "Explain the role of KV cache and TTFT/ITL latency in serving large "
                            "language models, and outline one practical scaling strategy for GPUs."
                        ),
                    }
                ],
                "temperature": 0.2,
                "max_tokens": 256,
            },
            timeout=120,
        )

    @task(1)
    def health_check(self):
        self.client.get("/health", timeout=10)

