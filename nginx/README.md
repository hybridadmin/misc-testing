# High-Performance Nginx Docker Setup

Dockerized Nginx server tuned for high throughput (~1000 connections/sec) with **Gzip** and **Brotli** compression, plus **OpenTelemetry** distributed tracing exported to an OTel Collector.

## Architecture

```
                 :8080                    :4317 (gRPC)
┌────────┐      ┌─────────────┐          ┌──────────────────┐
│ Client ├─────►│    Nginx    ├─traces──►│  OTel Collector  ├──► Exporters
└────────┘      │ (ngx_otel)  │          │  (contrib)       │    (debug/stdout)
                └─────────────┘          └──────────────────┘
                 Brotli + Gzip              :4318 (HTTP)
                 Rate limiting              :13133 (health)
                 Security headers
```

Nginx sends trace spans over gRPC to the OTel Collector, which batches and exports them. By default the collector uses the `debug` exporter (prints traces to its stdout). You can add any OTLP-compatible backend (Jaeger, Zipkin, Grafana Tempo, Datadog, etc.) by editing `otel-collector-config.yaml`.

## Stack

| Component | Version / Source |
|-----------|-----------------|
| Nginx | `nginx:1.29.5` (Debian Trixie) |
| Brotli module | Dynamic module compiled from [google/ngx_brotli](https://github.com/google/ngx_brotli) |
| OTel module | Dynamic module compiled from [nginxinc/nginx-otel](https://github.com/nginxinc/nginx-otel) |
| OTel Collector | `otel/opentelemetry-collector-contrib:latest` |

## Quick Start

```bash
# Build and start (first build takes ~15 min due to OTel/gRPC compilation)
docker compose up -d --build

# Verify Nginx is running
curl http://localhost:8080/health

# Verify OTel Collector is running
curl http://localhost:13133/

# Generate some traffic, then check traces
curl http://localhost:8080/
docker compose logs otel-collector

# Stop
docker compose down
```

## Files

| File | Purpose |
|------|---------|
| `config/nginx.conf` | Nginx config: performance tuning, gzip, brotli, OTel tracing, rate limiting, security headers |
| `config/otel-collector-config.yaml` | OTel Collector config: OTLP receivers, batch processor, debug exporter, health check |
| `Dockerfile` | Multi-stage build — compiles Brotli + OTel dynamic modules, produces a slim final image |
| `docker-compose.yml` | Two services: `nginx` + `otel-collector`, with kernel tuning (ulimits, sysctls) |

## Configuration Overview

### Performance Tuning

- **`worker_processes auto`** — matches available CPU cores
- **`worker_connections 4096`** — max simultaneous connections per worker
- **`worker_rlimit_nofile 65535`** — raised file descriptor limit
- **`epoll` + `multi_accept on`** — efficient event-driven I/O
- **`sendfile` + `tcp_nopush` + `tcp_nodelay`** — zero-copy file serving, optimized packet batching
- **`keepalive_timeout 30` / `keepalive_requests 1000`** — persistent connections to reduce TCP overhead
- **`open_file_cache`** — caches file descriptors and metadata to reduce disk I/O

### Compression

Both encodings are enabled simultaneously. Clients that send `Accept-Encoding: br` get Brotli; others fall back to Gzip.

**Gzip:**
- Compression level 4 (good balance of speed vs ratio)
- Minimum body size 256 bytes
- Compresses text, JSON, JS, CSS, XML, SVG

**Brotli:**
- Compression level 4
- `brotli_static on` — serves pre-compressed `.br` files when available
- Same MIME type coverage as Gzip, plus `font/woff2`
- Typically 15-25% better compression ratio than Gzip at equivalent CPU cost

### OpenTelemetry Tracing

Nginx uses the [`ngx_otel_module`](https://github.com/nginxinc/nginx-otel) to generate trace spans for every request and export them to the OTel Collector over gRPC.

**Nginx-side config (`config/nginx.conf`):**

| Directive | Value | Description |
|-----------|-------|-------------|
| `otel_exporter endpoint` | `otel-collector:4317` | gRPC endpoint of the collector |
| `otel_exporter interval` | `5s` | Export interval |
| `otel_exporter batch_size` | `512` | Spans per batch |
| `otel_exporter batch_count` | `4` | Max concurrent batches |
| `otel_service_name` | `nginx` | Service name in traces |
| `otel_trace` | `on` | Enable tracing globally |
| `otel_trace_context` | `propagate` | Propagate W3C `traceparent` / `tracestate` headers |
| `otel_span_name` | `$request_uri` | Span name set to the request URI |
| `otel_span_attr` | `http.server.name $server_name` | Custom span attribute |

The `/health` endpoint has `otel_trace off` to avoid noisy health-check spans.

**Collector-side config (`config/otel-collector-config.yaml`):**

```
Receivers  →  Processors  →  Exporters
  otlp          batch          debug
 (gRPC+HTTP)  (1024/5s)     (stdout)
```

- **Receivers:** OTLP gRPC (`:4317`) and HTTP (`:4318`)
- **Processors:** `batch` — batches 1024 spans or flushes every 5 seconds
- **Exporters:** `debug` — logs trace data to the collector's stdout with detailed verbosity
- **Extensions:** `health_check` on `:13133`

### Rate Limiting

- **1000 requests/sec** per client IP (`limit_req_zone`)
- **Burst allowance of 200** with `nodelay` (absorbs short spikes without queuing)
- **100 concurrent connections** per IP (`limit_conn`)
- `/health` endpoint is excluded from rate limiting

### Security

- `server_tokens off` — hides Nginx version in responses
- `X-Frame-Options: SAMEORIGIN`
- `X-Content-Type-Options: nosniff`
- `X-XSS-Protection: 1; mode=block`
- `Referrer-Policy: no-referrer-when-downgrade`
- Hidden files (dotfiles) return 403

### Kernel Tuning (via docker-compose.yml)

- `nofile` ulimit raised to 65535
- `net.core.somaxconn` set to 4096 (listen backlog)
- `net.ipv4.tcp_tw_reuse` enabled (recycle TIME_WAIT sockets)

## Endpoints

### Nginx

| Port | Path | Description |
|------|------|-------------|
| 8080 | `/` | Serves static files from `/usr/share/nginx/html` |
| 8080 | `/health` | Returns `200 OK` (plain text, no rate limiting, no tracing, no access log) |

### OTel Collector

| Port | Protocol | Description |
|------|----------|-------------|
| 4317 | gRPC | OTLP trace receiver (used by Nginx) |
| 4318 | HTTP | OTLP trace receiver (available for other services) |
| 13133 | HTTP | Health check endpoint |

## Logging

All logs go to stdout/stderr (visible via `docker logs` or `docker compose logs`):

```bash
# Follow Nginx logs
docker compose logs -f nginx

# Follow OTel Collector logs (includes trace data from debug exporter)
docker compose logs -f otel-collector

# Follow both
docker compose logs -f

# Nginx access log format:
# <ip> - <user> [<time>] "<request>" <status> <bytes> "<referer>" "<user-agent>" "<x-forwarded-for>"
```

## Viewing Traces

By default, traces are printed to the collector's stdout via the `debug` exporter:

```bash
# Send a request to generate a trace
curl http://localhost:8080/

# View traces in collector output
docker compose logs otel-collector | grep -A 20 "Span #"
```

### Adding a Trace Backend

To send traces to a real backend, edit `config/otel-collector-config.yaml`. Examples:

**Jaeger:**

```yaml
exporters:
  debug:
    verbosity: detailed
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug, otlp/jaeger]
```

**Grafana Tempo:**

```yaml
exporters:
  debug:
    verbosity: detailed
  otlp/tempo:
    endpoint: tempo:4317
    tls:
      insecure: true

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug, otlp/tempo]
```

**Zipkin:**

```yaml
exporters:
  debug:
    verbosity: detailed
  zipkin:
    endpoint: http://zipkin:9411/api/v2/spans

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug, zipkin]
```

You can list multiple exporters in the pipeline to fan out traces to several backends simultaneously.

## Customization

- **Port** — change the `listen` directive in `config/nginx.conf` and the port mapping in `docker-compose.yml`
- **Rate limit** — adjust `rate=1000r/s` and `burst=200` in `config/nginx.conf`
- **Compression levels** — raise `gzip_comp_level` / `brotli_comp_level` (1-11) for better ratio at the cost of CPU
- **OTel service name** — change `otel_service_name` in `config/nginx.conf`
- **OTel sampling** — add `otel_trace $variable` with a map to sample a percentage of requests
- **Collector exporters** — edit `config/otel-collector-config.yaml` to add backends (see examples above)
- **Static content** — mount your content directory to `/usr/share/nginx/html`

```yaml
# Example: serve your own static site
volumes:
  - ./my-site:/usr/share/nginx/html:ro
```

## Verifying Compression

```bash
# Test Brotli
curl -s -H "Accept-Encoding: br" -D - -o /dev/null http://localhost:8080/

# Test Gzip
curl -s -H "Accept-Encoding: gzip" -D - -o /dev/null http://localhost:8080/

# Look for "Content-Encoding: br" or "Content-Encoding: gzip" in the response headers
```

## Build Notes

The Dockerfile uses a multi-stage build. The builder stage:

1. Starts from `nginx:1.29.5` (to get the exact Nginx binary and headers)
2. Downloads the matching Nginx source and runs `./configure --with-compat`
3. Clones and compiles the **Brotli** filter + static modules
4. Clones and compiles the **OTel** module (this fetches and builds gRPC + OTel C++ SDK from source — expect ~10-15 minutes)

The final stage copies only the three `.so` module files and their runtime dependencies (`libbrotli1`, `libc-ares2`, `libre2-11`) into a clean `nginx:1.29.5` image.
