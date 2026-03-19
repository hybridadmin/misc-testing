# TurboAPI Performance Benchmark

A production-ready Docker Compose setup comparing FastAPI vs TurboAPI performance with PostgreSQL 18.3 and Valkey 9 caching.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Docker Network                        │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │   FastAPI    │  │   TurboAPI   │  │     Benchmark    │   │
│  │  (Port 8001) │  │  (Port 8002) │  │     (Locust)     │   │
│  │              │  │              │  │                  │   │
│  │ • 4 workers  │  │ • 8 workers  │  │  • Load testing  │   │
│  │ • Valkey L1  │  │ • In-memory  │  │  • wrk support   │   │
│  │              │  │   L1 + L2    │  │                  │   │
│  └──────┬───────┘  └──────┬───────┘  └──────────────────┘   │
│         │                 │                                   │
│         └────────┬────────┘                                   │
│                  ▼                                            │
│         ┌────────────────┐  ┌────────────────┐              │
│         │   PostgreSQL    │  │     Valkey      │              │
│         │     18.3        │  │      9.0        │              │
│         │                 │  │                 │              │
│         │ • Connection    │  │ • AOF persist   │              │
│         │   pooling       │  │ • LRU eviction  │              │
│         │ • Async I/O    │  │ • Connection    │              │
│         │                 │  │   pooling      │              │
│         └────────────────┘  └────────────────┘              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Features

### PostgreSQL 18.3
- Async connection pooling via `asyncpg`
- Tuned memory settings (shared_buffers, work_mem, etc.)
- `pg_stat_statements` extension for query analysis
- Proper indexing on benchmark tables

### Valkey 9.0 (Redis-compatible)
- AOF persistence for durability
- LRU eviction policy (maxmemory 384MB)
- Connection pooling
- Sub-millisecond cache operations

### FastAPI Service
- Standard async/await patterns
- Direct Valkey caching (L1)
- 4 uvicorn workers
- Rate limiting via slowapi

### TurboAPI Service
- Two-tier caching: In-memory (L1) + Valkey (L2)
- Higher concurrency (8 workers)
- Optimized for repeated queries
- Better cache hit performance

## Quick Start

### 1. Start Services

```bash
# Build and start all services
docker compose up -d

# Verify services are running
docker compose ps
```

### 2. Test Endpoints

```bash
# Health checks
curl http://localhost:8001/health
curl http://localhost:8002/health

# DB latency test
curl http://localhost:8001/db-test
curl http://localhost:8002/db-test

# Cache latency test
curl http://localhost:8001/cache-test
curl http://localhost:8002/cache-test

# Cached endpoint (first call hits DB, subsequent use cache)
curl http://localhost:8001/cached%20endpoint
curl http://localhost:8002/cached%20endpoint

# Complex query
curl "http://localhost:8001/complex-query?n=100"
curl "http://localhost:8002/complex-query?n=100"

# Bulk insert
curl -X POST "http://localhost:8001/bulk-insert?count=1000"
curl -X POST "http://localhost:8002/bulk-insert?count=1000"
```

## Running Benchmarks

### Quick Benchmark (wrk)

**Note:** Use wrk installed on your host machine, not from the benchmark container.

```bash
# Install wrk (macOS)
brew install wrk

# Run the benchmark script
./benchmarks/run_benchmarks.sh

# Or run manually:
wrk -t4 -c100 -d30s http://localhost:8001/health
wrk -t4 -c100 -d30s http://localhost:8002/health
wrk -t4 -c50 -d30s http://localhost:8001/db-test
wrk -t4 -c50 -d30s http://localhost:8002/db-test
```

### Full Load Test (Locust)

```bash
# Start all services including benchmark
docker compose --profile benchmark up -d

# Run Locust headless (from host - requires Locust installed)
locust -f benchmarks/locustfile.py \
  --headless \
  --users 500 \
  --spawn-rate 50 \
  --run-time 60s \
  --host http://localhost:8001

# Or use Docker directly
docker compose run --rm benchmark \
  locust -f locustfile.py \
  --headless \
  --users 500 \
  --spawn-rate 50 \
  --run-time 60s \
  --host http://localhost:8001

# View Locust web UI
# Open http://localhost:8089
```
  --run-time 60s \
  --host http://app_turbo:8002
```

### Custom Benchmark Script

```bash
# Run the benchmark helper script
./benchmarks/run_benchmarks.sh
```

## API Reference

### Endpoints (Both Services)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check (DB + Cache status) |
| `/` | GET | Basic info |
| `/db-test` | GET | Simple DB query latency |
| `/cache-test` | GET | Cache set/get latency |
| `/cached endpoint` | GET | Cached response (DB hit on first, cache on subsequent) |
| `/complex-query` | GET | Complex query with results (param: n) |
| `/bulk-insert` | POST | Bulk insert test (param: count) |

### Port Mapping

| Service | Internal Port | External Port |
|---------|---------------|---------------|
| FastAPI | 8001 | 8001 |
| TurboAPI | 8002 | 8002 |
| PostgreSQL | 5432 | 5432 |
| Valkey | 6379 | 6379 |

## Database Access

### Connection Details

| Parameter | Value |
|-----------|-------|
| Host | localhost (external) / postgres (internal) |
| Port | 5432 |
| Database | app_db |
| Username | appuser |
| Password | changeme_prod_2024 (or from .env) |

### Connect from Host Machine

```bash
# Using psql (install with: brew install postgresql)
psql -h localhost -p 5432 -U appuser -d app_db

# Using Docker
docker exec -it turboapi_postgres psql -U appuser -d app_db
```

### Connect from Inside Docker Network

```bash
# From any container
docker exec -it turboapi_fastapi psql -h postgres -U appuser -d app_db

# Using inline SQL
docker exec -it turboapi_postgres psql -U appuser -d app_db -c "SELECT version();"
```

### Useful SQL Commands

```sql
-- List tables
\dt

-- List users/roles
\du

-- Show database size
SELECT pg_size_pretty(pg_database_size('app_db'));

-- Show table sizes
SELECT table_name, pg_size_pretty(pg_total_relation_size(quote_ident(table_name)))
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY pg_total_relation_size(quote_ident(table_name)) DESC;

-- Check active connections
SELECT pid, usename, application_name, client_addr, state
FROM pg_stat_activity
WHERE datname = 'app_db';

-- Query statistics (requires pg_stat_statements extension)
SELECT query, calls, mean_time, total_time
FROM pg_stat_statements
ORDER BY total_time DESC
LIMIT 10;

-- Reset statistics
SELECT pg_stat_statements_reset();
```

### Enable Port Forwarding (Optional)

Add to docker-compose.yml if you want external PostgreSQL access:

```yaml
services:
  postgres:
    ports:
      - "5432:5432"
```

### Valkey/Redis Access

```bash
# Connect via CLI
docker exec -it turboapi_valkey valkey-cli

# Or from host (if port 6379 is exposed)
valkey-cli -h localhost -p 6379

# Useful commands
valkey-cli ping           # Test connection
valkey-cli info stats     # Statistics
valkey-cli dbsize         # Number of keys
valkey-cli keys '*'       # List all keys
valkey-cli flushall       # Clear all keys (careful!)
```

## Environment Variables

Create a `.env` file (copy from `.env.example`). All settings are configurable:

### Database Settings
| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_USER` | appuser | PostgreSQL username |
| `POSTGRES_PASSWORD` | changeme_prod_2024 | PostgreSQL password |
| `DATABASE_POOL_SIZE` | 20 | Database connection pool size |
| `DATABASE_MAX_OVERFLOW` | 10 | Max overflow connections |

### Cache Settings
| Variable | Default | Description |
|----------|---------|-------------|
| `VALKEY_HOST` | valkey | Valkey/Redis host |
| `VALKEY_PORT` | 6379 | Valkey/Redis port |
| `CACHE_DEFAULT_TTL` | 300 | Default cache TTL in seconds |

### Uvicorn Server Settings
| Variable | Default | Description |
|----------|---------|-------------|
| `UVICORN_WORKERS` | 4 | Number of worker processes |
| `UVICORN_HOST` | 0.0.0.0 | Host to bind to |
| `UVICORN_PORT` | 8001/8002 | Port to bind to |
| `UVICORN_TIMEOUT_KEEP_ALIVE` | 65 | Keep-alive timeout (seconds) |
| `UVICORN_LIMIT_CONCURRENCY` | 1000/2000 | Max concurrent connections |
| `UVICORN_LIMIT_MAX_REQUESTS` | 10000 | Max requests per worker before restart |
| `UVICORN_ACCESS_LOG` | false | Enable/disable access logging |

### Example .env Configuration

```env
# PostgreSQL Configuration
POSTGRES_USER=appuser
POSTGRES_PASSWORD=changeme_prod_2024

# Valkey (Redis) Configuration
VALKEY_HOST=valkey
VALKEY_PORT=6379

# Application Settings
LOG_LEVEL=INFO
DEBUG=false

# Database Pool Settings
DATABASE_POOL_SIZE=20
DATABASE_MAX_OVERFLOW=10
CACHE_DEFAULT_TTL=300

# Uvicorn Server Settings
UVICORN_WORKERS=4
UVICORN_HOST=0.0.0.0
UVICORN_TIMEOUT_KEEP_ALIVE=65
UVICORN_LIMIT_CONCURRENCY=1000
UVICORN_LIMIT_MAX_REQUESTS=10000
UVICORN_ACCESS_LOG=false

# Benchmark URLs
FASTAPI_URL=http://app_fastapi:8001
TURBOAPI_URL=http://app_turbo:8002
```

### Tuning for High Performance

For production benchmarks, you can increase workers and concurrency:

```env
UVICORN_WORKERS=8
UVICORN_LIMIT_CONCURRENCY=5000
DATABASE_POOL_SIZE=50
```

## Production Considerations

### Database Tuning
- `shared_buffers`: 256MB (1/4 of available RAM)
- `work_mem`: 16MB per operation
- `maintenance_work_mem`: 128MB for maintenance
- Connection pool: 20-30 connections per worker

### Cache Configuration
- Maxmemory: 384MB with LRU eviction
- AOF persistence every second
- Connection pooling with 50 max connections

### Application Settings
- Health checks with 10s interval
- Resource limits and reservations
- Non-root users in containers
- Graceful shutdown handling

## Troubleshooting

### Services won't start
```bash
# Check logs
docker compose logs postgres
docker compose logs valkey
docker compose logs app_fastapi
docker compose logs app_turbo
```

### Database connection issues
```bash
# Remove volumes and restart fresh
docker compose down -v
docker compose up -d
```

### Clear all data
```bash
docker compose down -v --remove-orphans
docker compose up -d
```

## Project Structure

```
.
├── docker-compose.yml          # Main orchestration
├── app_fastapi/               # FastAPI service
│   ├── main.py               # Application code
│   ├── config.py             # Settings
│   ├── Dockerfile
│   └── requirements.txt
├── app_turbo/                # TurboAPI service
│   ├── main.py               # Application code
│   ├── config.py             # Settings
│   ├── Dockerfile
│   └── requirements.txt
├── postgres/
│   └── init.sql              # Database initialization
├── valkey/
│   └── valkey.conf           # Redis/Valkey config
├── benchmarks/
│   ├── locustfile.py         # Locust test file
│   ├── run_benchmarks.sh     # Benchmark runner
│   └── Dockerfile
├── .env                      # Environment variables
└── README.md
```

## Sample Benchmark Results

### Single Request Latency (ms)

| Endpoint | FastAPI | TurboAPI | Winner |
|----------|---------|----------|--------|
| `/health` | ~5-10 | ~5-10 | Tie |
| `/db-test` | 15-25 | 40-60 | FastAPI |
| `/cache-test` | 10-15 | 10-15 | Tie |
| `/complex-query` | 25-35 | 60-80 | FastAPI |
| `/bulk-insert` | 20-25 | 40-55 | FastAPI |

### wrk Load Test Results (10s, 50 concurrent connections)

#### Health Endpoint (No DB/Cache)
```
FastAPI:
  Requests/sec:    1164.81
  Avg Latency:     69.00ms
  Max Latency:     774.54ms
  Transfer/sec:    263.65KB

TurboAPI:
  Requests/sec:    1872.59 (+61%)
  Avg Latency:     42.53ms (-38%)
  Max Latency:     1070ms
  Transfer/sec:    425.64KB (+61%)
```

**Winner: TurboAPI** - 61% higher throughput, 38% lower latency

#### Cache Test Endpoint
```
FastAPI:
  Requests/sec:    975.32
  Avg Latency:     118.66ms
  Max Latency:     868.43ms

TurboAPI:
  Requests/sec:    336.85 (-65%)
  Avg Latency:     314.59ms (+165%)
  Max Latency:     1310ms
```

**Winner: FastAPI** - Higher throughput at cache-only operations

#### Database Query Endpoint
```
FastAPI:
  Requests/sec:    463.48
  Avg Latency:     100.08ms
  Max Latency:     1890ms
  Timeouts:        40

TurboAPI:
  Requests/sec:    741.98 (+60%)
  Avg Latency:     131.55ms
  Max Latency:     1990ms
  Timeouts:        7 (-83%)
```

**Winner: TurboAPI** - 60% higher throughput, 83% fewer timeouts

### Analysis

1. **Health Checks**: TurboAPI with 8 workers handles non-blocking requests 61% better
2. **Database Operations**: TurboAPI's higher concurrency and cache optimization reduces connection exhaustion
3. **Cache Operations**: FastAPI's simpler architecture is faster for pure cache hits
4. **Overall**: TurboAPI's two-tier caching and higher concurrency wins for mixed workloads

## License

MIT
