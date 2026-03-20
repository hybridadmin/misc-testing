FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY locustfile.py .
COPY run_benchmarks.sh .
RUN chmod +x run_benchmarks.sh && mkdir -p /app/results

CMD ["bash", "-c", "echo 'Benchmark container ready. Run:' && echo '  locust -f locustfile.py --host http://app_fastapi:8001 --headless -u 100 -r 10 -t 60s' && tail -f /dev/null"]
