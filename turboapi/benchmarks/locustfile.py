import os
import time
import statistics
from locust import HttpUser, task, between, events
from locust.runners import MasterRunner
import requests

FASTAPI_URL = os.getenv("FASTAPI_URL", "http://app_fastapi:8001")
TURBOAPI_URL = os.getenv("TURBOAPI_URL", "http://app_turbo:8002")


class FastAPIUser(HttpUser):
    host = FASTAPI_URL
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
        self.client.get("/cached endpoint")

    @task(3)
    def complex_query(self):
        self.client.get("/complex-query?n=100")


class TurboAPIUser(HttpUser):
    host = TURBOAPI_URL
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
        self.client.get("/cached endpoint")

    @task(3)
    def complex_query(self):
        self.client.get("/complex-query?n=100")


@events.test_start.add_listener
def on_test_start(environment, **kwargs):
    print(f"\n{'=' * 60}")
    print("BENCHMARK TEST STARTING")
    print(f"{'=' * 60}")
    print(f"FastAPI Target: {FASTAPI_URL}")
    print(f"TurboAPI Target: {TURBOAPI_URL}")

    for url, name in [(FASTAPI_URL, "FastAPI"), (TURBOAPI_URL, "TurboAPI")]:
        try:
            response = requests.get(f"{url}/health", timeout=10)
            print(f"{name} Status: {response.status_code} - {response.json()}")
        except Exception as e:
            print(f"{name} Connection Failed: {e}")
    print(f"{'=' * 60}\n")


@events.test_stop.add_listener
def on_test_stop(environment, **kwargs):
    print(f"\n{'=' * 60}")
    print("BENCHMARK TEST COMPLETE")
    print(f"{'=' * 60}")

    if isinstance(environment.runner, MasterRunner):
        stats = environment.stats
        print("\nFastAPI Results:")
        print_stats(stats.get("GET /health", None))
        print_stats(stats.get("GET /db-test", None))
        print_stats(stats.get("GET /cached endpoint", None))

        print("\nTurboAPI Results:")
        print_stats(stats.get("GET /health", None))
        print_stats(stats.get("GET /db-test", None))
        print_stats(stats.get("GET /cached endpoint", None))


def print_stats(request_stats):
    if request_stats:
        print(f"  Requests: {request_stats.num_requests}")
        print(f"  Failures: {request_stats.num_failures}")
        print(f"  Median: {request_stats.median_response_time}ms")
        print(f"  Avg: {request_stats.avg_response_time}ms")
        print(f"  Max: {request_stats.max_response_time}ms")
        print(f"  RPS: {request_stats.total_rps:.2f}")
