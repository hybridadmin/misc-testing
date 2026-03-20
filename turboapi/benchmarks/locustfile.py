"""
Locust benchmark file.

Run against ONE target at a time for fair comparison:
    locust -f locustfile.py --host http://app_fastapi:8001 --headless -u 100 -r 10 -t 60s
    locust -f locustfile.py --host http://app_turbo:8002  --headless -u 100 -r 10 -t 60s

Or with the web UI:
    locust -f locustfile.py --host http://app_fastapi:8001
"""

import os
from locust import HttpUser, task, between, events
import requests


class APIUser(HttpUser):
    """Generic user class -- set --host to target FastAPI or TurboAPI."""

    wait_time = between(0.001, 0.01)

    @task(10)
    def health_check(self):
        self.client.get("/health")

    @task(5)
    def db_test(self):
        self.client.get("/db-test")

    @task(5)
    def cache_test(self):
        self.client.get("/cache-test")

    @task(15)
    def cached_endpoint(self):
        self.client.get("/cached-endpoint")

    @task(3)
    def complex_query(self):
        self.client.get("/complex-query?n=100")

    @task(2)
    def bulk_insert(self):
        self.client.post("/bulk-insert?count=100")


@events.test_start.add_listener
def on_test_start(environment, **kwargs):
    host = environment.host or "unknown"
    print(f"\n{'=' * 60}")
    print(f"BENCHMARK: {host}")
    print(f"{'=' * 60}")
    try:
        resp = requests.get(f"{host}/health", timeout=5)
        print(f"Health: {resp.json()}")
    except Exception as e:
        print(f"Health check failed: {e}")
    print(f"{'=' * 60}\n")


@events.test_stop.add_listener
def on_test_stop(environment, **kwargs):
    stats = environment.stats
    print(f"\n{'=' * 60}")
    print("RESULTS SUMMARY")
    print(f"{'=' * 60}")
    for entry in stats.entries.values():
        print(
            f"  {entry.method} {entry.name:30s}  "
            f"reqs={entry.num_requests:>6d}  "
            f"fails={entry.num_failures:>4d}  "
            f"avg={entry.avg_response_time:>7.1f}ms  "
            f"p50={entry.get_response_time_percentile(0.5) or 0:>7.1f}ms  "
            f"p95={entry.get_response_time_percentile(0.95) or 0:>7.1f}ms  "
            f"p99={entry.get_response_time_percentile(0.99) or 0:>7.1f}ms  "
            f"rps={entry.total_rps:>8.1f}"
        )
    total = stats.total
    print(
        f"\n  TOTAL: reqs={total.num_requests} fails={total.num_failures} rps={total.total_rps:.1f}"
    )
    print(f"{'=' * 60}")
