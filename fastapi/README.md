# High-Performance Nginx + FastAPI Docker Setup

Dockerized **Nginx** reverse proxy with a **FastAPI** backend, **PostgreSQL 18** database, and **Valkey** cache — tuned for high throughput (~1000 connections/sec) with **Gzip** and **Brotli** compression, plus **OpenTelemetry** distributed tracing exported to an OTel Collector.

## Architecture

```
                 :8080                    :8000 (internal)
┌────────┐      ┌─────────────┐          ┌──────────────────┐        ┌──────────────┐
│ Client ├─────►│    Nginx    ├─proxy───►│  Uvicorn/FastAPI │───────►│ PostgreSQL 18│
└────────┘      │ (brotli+gz) │          │  (OTel SDK)      │        │  :5432       │
                └─────────────┘          └───────┬──┬───────┘        └──────────────┘
                                          traces │  │ cache
                                     :4317 (gRPC)│  │ :6379
                                         ┌───────▼┐ ▼──────────┐
                                         │  OTel  │ │   Valkey  │
                                         │Collector│ │(auth+AOF) │
                                         └────────┘ └───────────┘
```

Nginx listens on `:8080`, proxies `/api/`, `/docs`, `/redoc`, `/openapi.json`, and `/health` to the FastAPI backend running on Uvicorn (`:8000` inside the container). Read endpoints are cached in Valkey; write operations automatically invalidate related cache keys. Static file serving is still handled directly by Nginx. The FastAPI app is instrumented with the OpenTelemetry Python SDK, which exports trace spans over gRPC to the OTel Collector.

## Stack

| Component | Version / Source |
|-----------|-----------------|
| Nginx | `nginx:1.29.5-trixie` (Debian Trixie) |
| Brotli module | Dynamic module compiled from [google/ngx_brotli](https://github.com/google/ngx_brotli) |
| OTel Python SDK | `opentelemetry-sdk` 1.39+ with auto-instrumentation for FastAPI, SQLAlchemy, and Redis |
| OTel Collector | `otel/opentelemetry-collector-contrib:latest` |
| FastAPI | `0.115.12` with Uvicorn `0.34.2` |
| Python packaging | [uv](https://docs.astral.sh/uv/) (lockfile-based, replaces pip + venv) |
| PostgreSQL | `postgres:18` |
| SQLAlchemy | `2.0.40` (async with `asyncpg`) |
| Valkey | `valkey/valkey:9` (Redis-compatible cache) |
| redis-py | `5.3.0` with `hiredis` (async client for Valkey) |

## Quick Start

```bash
# Build and start
docker compose up -d --build

# Verify everything is running
curl http://localhost:8080/health

# Verify OTel Collector is running
curl http://localhost:13133/

# Open the interactive API docs
open http://localhost:8080/docs

# Stop
docker compose down

# Stop and remove the database volume
docker compose down -v
```

## Files

| File | Purpose |
|------|---------|
| `app/main.py` | FastAPI application entrypoint with lifespan handler (auto-creates DB tables, initialises cache, sets up OTel tracing) |
| `app/config.py` | App settings via `pydantic-settings` (reads DB + cache + app config from env) |
| `app/database.py` | Async SQLAlchemy engine and session factory |
| `app/cache.py` | Valkey connection pool and cache helpers (get, set, delete, pattern delete) |
| `app/models.py` | SQLAlchemy models: `Item` and `Note` |
| `app/schemas.py` | Pydantic request/response schemas |
| `app/routes.py` | CRUD API routes for items and notes (with Valkey caching) |
| `app/telemetry.py` | OpenTelemetry SDK setup: TracerProvider, OTLP exporter, auto-instrumentation for FastAPI, SQLAlchemy, Redis |
| `pyproject.toml` | Project metadata and Python dependencies (used by uv) |
| `uv.lock` | Lockfile for reproducible dependency installs |
| `config/nginx.conf` | Nginx config: reverse proxy, performance tuning, gzip, brotli, rate limiting, security headers |
| `config/otel-collector-config.yaml` | OTel Collector config: OTLP receivers, batch processor, debug exporter, health check |
| `config/valkey.conf` | Valkey config: auth, memory limits, LRU eviction, AOF persistence, security hardening |
| `entrypoint.sh` | Container entrypoint: starts Uvicorn in the background, then Nginx in the foreground |
| `Dockerfile` | Multi-stage build — compiles Brotli dynamic modules, installs Python + OTel SDK + FastAPI app |
| `docker-compose.yml` | Four services: `nginx` + `postgres` + `valkey` + `otel-collector`, with kernel tuning |

## API Reference

All API endpoints are served through Nginx on port `8080`. Interactive documentation is available at `/docs` (Swagger UI) and `/redoc` (ReDoc).

### Items

Full CRUD for a simple item with a name and optional description.

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/items` | List items (supports `?skip=` and `?limit=` query params) |
| `POST` | `/api/items` | Create an item |
| `GET` | `/api/items/{id}` | Get a single item |
| `PATCH` | `/api/items/{id}` | Partially update an item |
| `DELETE` | `/api/items/{id}` | Delete an item |

### Notes

Simple notes with a title and content body.

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/notes` | List notes (supports `?skip=` and `?limit=` query params) |
| `POST` | `/api/notes` | Create a note |
| `GET` | `/api/notes/{id}` | Get a single note |
| `DELETE` | `/api/notes/{id}` | Delete a note |

### Other Endpoints

| Port | Path | Description |
|------|------|-------------|
| 8080 | `/health` | Health check (proxied to FastAPI, no rate limiting, excluded from tracing) |
| 8080 | `/docs` | Swagger UI (interactive API docs) |
| 8080 | `/redoc` | ReDoc (alternative API docs) |
| 8080 | `/openapi.json` | OpenAPI schema |
| 8080 | `/` | Static files from `/usr/share/nginx/html` |

## API Usage Examples

### Create an item

```bash
curl -s -X POST http://localhost:8080/api/items \
  -H "Content-Type: application/json" \
  -d '{"name": "Widget", "description": "A test widget"}' | jq
```

```json
{
  "id": 1,
  "name": "Widget",
  "description": "A test widget",
  "created_at": "2026-02-28T12:00:00+00:00",
  "updated_at": "2026-02-28T12:00:00+00:00"
}
```

### List all items

```bash
curl -s http://localhost:8080/api/items | jq
```

### Get a specific item

```bash
curl -s http://localhost:8080/api/items/1 | jq
```

### Update an item

```bash
curl -s -X PATCH http://localhost:8080/api/items/1 \
  -H "Content-Type: application/json" \
  -d '{"description": "Updated description"}' | jq
```

### Delete an item

```bash
curl -s -X DELETE http://localhost:8080/api/items/1 -w "%{http_code}\n"
# 204
```

### Create a note

```bash
curl -s -X POST http://localhost:8080/api/notes \
  -H "Content-Type: application/json" \
  -d '{"title": "Meeting notes", "content": "Discussed project timeline and milestones."}' | jq
```

### List all notes

```bash
curl -s http://localhost:8080/api/notes | jq
```

### Delete a note

```bash
curl -s -X DELETE http://localhost:8080/api/notes/1 -w "%{http_code}\n"
# 204
```

### Health check

```bash
curl -s http://localhost:8080/health | jq
```

```json
{
  "status": "ok"
}
```

## Configuration Overview

### Nginx Reverse Proxy

Nginx proxies API traffic to the Uvicorn backend running on `127.0.0.1:8000` (both processes run in the same container via `entrypoint.sh`).

| Location | Backend | Notes |
|----------|---------|-------|
| `/api/` | `http://backend` | Rate limited, full proxy headers, 30s read timeout |
| `/docs`, `/redoc`, `/openapi.json` | `http://backend` | FastAPI interactive docs |
| `/health` | `http://backend` | No access log, excluded from OTel tracing |
| `/` | static files | Served directly by Nginx |

The upstream block uses `keepalive 32` for persistent connections to Uvicorn.

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

The FastAPI application is instrumented with the [OpenTelemetry Python SDK](https://opentelemetry.io/docs/languages/python/), which exports trace spans directly to the OTel Collector over gRPC. All configuration uses standard OTel environment variables set in `docker-compose.yml`.

**Instrumented libraries (`app/telemetry.py`):**

| Instrumentor | What it traces |
|---------------|----------------|
| `FastAPIInstrumentor` | HTTP request/response spans for every API call |
| `SQLAlchemyInstrumentor` | Database query spans (SELECT, INSERT, UPDATE, DELETE) |
| `RedisInstrumentor` | Valkey/Redis command spans (GET, SET, DEL, SCAN, etc.) |

The `/health` endpoint is excluded from tracing to avoid noisy health-check spans.

**Environment variables (set on the `nginx` service in `docker-compose.yml`):**

| Variable | Value | Description |
|----------|-------|-------------|
| `OTEL_SERVICE_NAME` | `fastapi-app` | Service name in trace data |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector:4317` | gRPC endpoint of the collector |
| `OTEL_TRACES_EXPORTER` | `otlp` | Use OTLP protocol for export |

The SDK reads these automatically — no application code changes are needed to reconfigure the endpoint or service name.

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

### PostgreSQL 18

- Credentials: `appuser` / `apppass` / `appdb` (set via environment in `docker-compose.yml`)
- Data volume mounted at `/var/lib/postgresql` (PG 18 data directory layout)
- Healthcheck via `pg_isready` — the nginx container waits for Postgres to be healthy before starting
- Tables are auto-created by SQLAlchemy on first startup (guarded by a PostgreSQL advisory lock to handle concurrent Uvicorn workers)

### Valkey (Cache)

Production-ready [Valkey](https://valkey.io/) instance (Redis-compatible) configured via `config/valkey.conf`. The auth password is **not** baked into the config file — it is passed at runtime via the `VALKEY_PASSWORD` env var on the valkey service, which feeds `--requirepass` on the command line. The FastAPI app reads it from `APP_CACHE_PASS`.

| Setting | Value | Description |
|---------|-------|-------------|
| `VALKEY_PASSWORD` (env) | `valkeyS3cret!` | Password authentication required for all clients (passed via `--requirepass`) |
| `VALKEY_LOGLEVEL` (env) | `notice` | Log verbosity (passed via `--loglevel`; set to `debug` in compose for development) |
| `maxmemory` | `256mb` | Memory ceiling |
| `maxmemory-policy` | `allkeys-lru` | Evicts least-recently-used keys when memory is full |
| `appendonly` | `yes` | AOF persistence enabled |
| `appendfsync` | `everysec` | Fsync once per second (good durability/performance trade-off) |
| `save` | `900 1` / `300 10` / `60 10000` | RDB snapshots as a safety net alongside AOF |
| `maxclients` | `10000` | Max concurrent connections |
| `rename-command` | `FLUSHDB ""` / `FLUSHALL ""` / `DEBUG ""` | Dangerous commands disabled |
| `slowlog-log-slower-than` | `10000` (10ms) | Slow query logging threshold |

**Cache strategy in the API:**

- **GET** endpoints (list, get by ID) check Valkey first; on miss they query Postgres and populate the cache
- **POST/PATCH/DELETE** endpoints invalidate related cache keys so subsequent reads get fresh data
- Cache keys follow the pattern `items:{id}`, `items:list:{skip}:{limit}`, `notes:{id}`, `notes:list:{skip}:{limit}`
- Default TTL is 60 seconds (configurable via `APP_CACHE_TTL`)
- All cache operations are wrapped in try/except — if Valkey is unavailable the API continues to work (cache miss falls through to Postgres)

### Database Models

**Items** (`items` table):

| Column | Type | Notes |
|--------|------|-------|
| `id` | `SERIAL` | Primary key |
| `name` | `VARCHAR(255)` | Required, indexed |
| `description` | `TEXT` | Optional |
| `created_at` | `TIMESTAMPTZ` | Auto-set on create |
| `updated_at` | `TIMESTAMPTZ` | Auto-set on create and update |

**Notes** (`notes` table):

| Column | Type | Notes |
|--------|------|-------|
| `id` | `SERIAL` | Primary key |
| `title` | `VARCHAR(255)` | Required |
| `content` | `TEXT` | Required |
| `created_at` | `TIMESTAMPTZ` | Auto-set on create |

## Logging

All logs go to stdout/stderr (visible via `docker logs` or `docker compose logs`):

```bash
# Follow Nginx logs
docker compose logs -f nginx

# Follow OTel Collector logs (includes trace data from debug exporter)
docker compose logs -f otel-collector

# Follow all services
docker compose logs -f

# Nginx access log format:
# <ip> - <user> [<time>] "<request>" <status> <bytes> "<referer>" "<user-agent>" "<x-forwarded-for>"
```

## Viewing Traces

By default, traces are printed to the collector's stdout via the `debug` exporter:

```bash
# Send a request to generate a trace
curl http://localhost:8080/api/items

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
- **OTel service name** — change `OTEL_SERVICE_NAME` in `docker-compose.yml`
- **OTel endpoint** — change `OTEL_EXPORTER_OTLP_ENDPOINT` in `docker-compose.yml` to point to a different collector
- **Collector exporters** — edit `config/otel-collector-config.yaml` to add backends (see examples above)
- **Static content** — mount your content directory to `/usr/share/nginx/html`
- **Database credentials** — change `APP_DB_USER`, `APP_DB_PASS`, `APP_DB_HOST`, `APP_DB_PORT`, `APP_DB_NAME` in `docker-compose.yml` (and keep `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` in sync on the postgres service)
- **Uvicorn workers** — set `UVICORN_WORKERS` in `docker-compose.yml` (default: 2)
- **Uvicorn log level** — set `UVICORN_LOG_LEVEL` in `docker-compose.yml` (default: info)
- **Cache password** — change `VALKEY_PASSWORD` on the valkey service and `APP_CACHE_PASS` on the nginx service in `docker-compose.yml` (keep both in sync)
- **Cache TTL** — set `APP_CACHE_TTL` in `docker-compose.yml` (default: 60 seconds)
- **Cache memory** — adjust `maxmemory` in `config/valkey.conf`

```yaml
# Example: serve your own static site
volumes:
  - ./my-site:/usr/share/nginx/html:ro
```

## Verifying Compression

```bash
# Test Brotli
curl -s -H "Accept-Encoding: br" -D - -o /dev/null http://localhost:8080/api/items

# Test Gzip
curl -s -H "Accept-Encoding: gzip" -D - -o /dev/null http://localhost:8080/api/items

# Look for "Content-Encoding: br" or "Content-Encoding: gzip" in the response headers
```

## Build Notes

The Dockerfile uses a multi-stage build. The builder stage:

1. Starts from `nginx:1.29.5-trixie`
2. Downloads the matching Nginx source and runs `./configure --with-compat`
3. Clones and compiles the **Brotli** filter + static modules

The final stage copies the two Brotli `.so` module files into a clean `nginx:1.29.5-trixie` image, installs [uv](https://docs.astral.sh/uv/) from its official container image, then runs `uv sync --frozen` against the `pyproject.toml` and `uv.lock` to create a virtual environment with all Python dependencies (including `redis[hiredis]` for Valkey and the OpenTelemetry SDK with auto-instrumentation packages) using the system Python 3.13 that ships with Trixie. The app source is copied into `/srv/app/`. The container starts via `entrypoint.sh`, which launches Uvicorn in the background and Nginx in the foreground.

## Environment Variables

All application env vars use the `APP_` prefix (consumed by `pydantic-settings`). Uvicorn vars are read directly by `entrypoint.sh`.

| Variable | Default | Description |
|----------|---------|-------------|
| `UVICORN_WORKERS` | `2` | Number of Uvicorn worker processes |
| `UVICORN_LOG_LEVEL` | `info` | Uvicorn log level (`debug`, `info`, `warning`, `error`, `critical`) |
| `APP_DB_USER` | **required** | PostgreSQL username |
| `APP_DB_PASS` | **required** | PostgreSQL password |
| `APP_DB_HOST` | **required** | PostgreSQL hostname |
| `APP_DB_PORT` | **required** | PostgreSQL port |
| `APP_DB_NAME` | **required** | PostgreSQL database name |
| `APP_CACHE_HOST` | **required** | Valkey hostname |
| `APP_CACHE_PORT` | **required** | Valkey port |
| `APP_CACHE_PASS` | **required** | Valkey auth password (must match `VALKEY_PASSWORD` on the valkey service) |
| `APP_CACHE_DB` | **required** | Valkey database index |
| `APP_CACHE_TTL` | `60` | Default cache TTL in seconds |
| `OTEL_SERVICE_NAME` | `fastapi-app` | Service name in trace data |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4317` | OTLP gRPC endpoint for the OTel Collector |
| `OTEL_TRACES_EXPORTER` | `otlp` | Traces exporter type |
| `VALKEY_PASSWORD` | `valkeyS3cret!` | Valkey server auth password (set on the valkey service, passed via `--requirepass`) |
| `VALKEY_LOGLEVEL` | `notice` | Valkey log level (`debug`, `verbose`, `notice`, `warning`) |
