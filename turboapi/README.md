# TurboAPI Performance Benchmark

A unified Docker Compose setup comparing **FastAPI** vs **TurboAPI** performance, backed by a **3-node PostgreSQL 18 cluster** with bidirectional pglogical replication and a **Valkey HA cluster** (primary + replicas + sentinels) for caching.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            Docker Network (172.28.0.0/16)                   │
│                                                                             │
│  ┌──────────────┐  ┌──────────────┐              ┌──────────────────┐      │
│  │   FastAPI     │  │   TurboAPI   │              │     Benchmark    │      │
│  │  (Port 8001)  │  │  (Port 8002) │              │   (wrk / Locust) │      │
│  │               │  │              │              │   --profile flag │      │
│  │ • 4 workers   │  │ • 4 workers  │              └──────────────────┘      │
│  │ • Valkey L1   │  │ • In-memory  │                                        │
│  │               │  │   L1 + L2    │                                        │
│  └──────┬────────┘  └──────┬───────┘                                        │
│         │ writes           │ writes                                          │
│         ▼                  ▼                                                 │
│  ┌────────────┐    ┌────────────┐    ┌────────────┐                         │
│  │  pg_node1  │◄──►│  pg_node2  │◄──►│  pg_node3  │                         │
│  │ (FastAPI   │    │ (TurboAPI  │    │  (mesh     │                         │
│  │  primary)  │◄────────────────────►│  member)   │                         │
│  └────────────┘    └────────────┘    └────────────┘                         │
│       pglogical bidirectional full-mesh (6 subscriptions)                   │
│                                                                             │
│  ┌─────────┐   ┌──────────────┐  ┌──────────────┐                          │
│  │  Valkey  │──►│   Replica 1  │  │   Replica 2  │                          │
│  │ Primary  │──►│  (read-only) │  │  (read-only) │                          │
│  └─────────┘   └──────────────┘  └──────────────┘                          │
│       ▲  monitored by                                                       │
│  ┌────┴──────┐  ┌────────────┐  ┌────────────┐                             │
│  │ Sentinel 1│  │ Sentinel 2 │  │ Sentinel 3 │                             │
│  └───────────┘  └────────────┘  └────────────┘                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Services (12 total + 1 one-shot setup)

| Service | Container | Role |
|---------|-----------|------|
| `pg_node1` | `turboapi_pg_node1` | PostgreSQL 18 — FastAPI writes here |
| `pg_node2` | `turboapi_pg_node2` | PostgreSQL 18 — TurboAPI writes here |
| `pg_node3` | `turboapi_pg_node3` | PostgreSQL 18 — mesh participant |
| `pg_setup` | `turboapi_pg_setup` | One-shot: creates pglogical nodes + subscriptions |
| `valkey` | `turboapi_valkey` | Valkey primary (port 6379) |
| `valkey_replica1` | `turboapi_valkey_replica1` | Valkey read-only replica |
| `valkey_replica2` | `turboapi_valkey_replica2` | Valkey read-only replica |
| `valkey_sentinel1` | `turboapi_valkey_sentinel1` | Sentinel (port 26379) |
| `valkey_sentinel2` | `turboapi_valkey_sentinel2` | Sentinel |
| `valkey_sentinel3` | `turboapi_valkey_sentinel3` | Sentinel |
| `app_fastapi` | `turboapi_fastapi` | FastAPI app (port 8001) |
| `app_turbo` | `turboapi_turbo` | TurboAPI app (port 8002) |
| `benchmark` | `turboapi_benchmark` | Benchmark runner (profile: benchmark) |

## Quick Start

### 1. Configure environment

```bash
cp .env.example .env
# Edit .env if you want to change defaults (passwords, pool sizes, etc.)
```

### 2. Start all services

```bash
docker compose up -d --build

# Watch startup progress (pg_setup must complete before apps start)
docker compose logs -f pg_setup

# Verify everything is healthy
docker compose ps
```

### 3. Test endpoints

```bash
# Health checks
curl http://localhost:8001/health
curl http://localhost:8002/health

# DB latency
curl http://localhost:8001/db-test
curl http://localhost:8002/db-test

# Cache latency
curl http://localhost:8001/cache-test
curl http://localhost:8002/cache-test

# Cached endpoint (DB on first call, cache on subsequent)
curl http://localhost:8001/cached-endpoint
curl http://localhost:8002/cached-endpoint

# Complex query
curl "http://localhost:8001/complex-query?n=100"
curl "http://localhost:8002/complex-query?n=100"

# Bulk insert
curl -X POST "http://localhost:8001/bulk-insert?count=1000"
curl -X POST "http://localhost:8002/bulk-insert?count=1000"
```

## API Endpoints

Both apps expose the same routes:

| Endpoint | Method | Description |
|---|---|---|
| `/health` | GET | Health check (DB + cache status) |
| `/` | GET | Basic service info |
| `/db-test` | GET | Simple DB query latency |
| `/cache-test` | GET | Cache set/get latency |
| `/cached-endpoint` | GET | DB-backed response with cache (TTL-based) |
| `/complex-query` | GET | Parameterized query (`?n=100`) |
| `/bulk-insert` | POST | Bulk insert test (`?count=1000`) |

### Port mapping

| Service | Port |
|---|---|
| FastAPI | 8001 |
| TurboAPI | 8002 |

PostgreSQL and Valkey ports are **not exposed** to the host by default (internal only on the `backend` network).

## Running Benchmarks

### wrk (recommended for quick A/B comparison)

```bash
# Install wrk
brew install wrk    # macOS
# apt install wrk   # Debian/Ubuntu

# Run the benchmark script (sequential: FastAPI first, then TurboAPI)
./benchmarks/run_benchmarks.sh

# Custom duration and concurrency
./benchmarks/run_benchmarks.sh -d 15 -c 200 -t 8
```

Results are saved to `benchmarks/results/`.

### Locust (distributed / web UI)

```bash
# Start the benchmark container alongside all services
docker compose --profile benchmark up -d

# Run inside the container against FastAPI
docker compose exec benchmark \
  locust -f locustfile.py --headless \
  --users 500 --spawn-rate 50 --run-time 60s \
  --host http://app_fastapi:8001

# Run against TurboAPI
docker compose exec benchmark \
  locust -f locustfile.py --headless \
  --users 500 --spawn-rate 50 --run-time 60s \
  --host http://app_turbo:8002
```

## PostgreSQL Cluster

### pglogical bidirectional replication

The 3 PostgreSQL nodes form a **full-mesh** bidirectional replication topology using the `pglogical` extension. This means every node can accept writes and changes propagate to all other nodes.

**6 subscriptions** (one in each direction for every pair):

```
node1 ──► node2     node2 ──► node1
node1 ──► node3     node3 ──► node1
node2 ──► node3     node3 ──► node2
```

All subscriptions use `forward_origins := '{}'` to prevent infinite replication loops.

### How it works

1. `postgres/init.sql` runs on each node via `docker-entrypoint-initdb.d`, creating the schema, extensions (`pglogical`, `pg_stat_statements`, `uuid-ossp`), and tables with primary keys (default PK-based replica identity).
2. After all 3 nodes are healthy, the `pg_setup` one-shot container runs `postgres/setup_replication.sh`:
   - Creates a pglogical node on each host
   - Adds all public tables to the `default` replication set on each node
   - Creates 6 bidirectional subscriptions
   - Staggers SERIAL sequences per node (`INCREMENT BY 3`, offsets 1/2/3) to prevent PK conflicts in multi-master writes
   - Runs a smoke test (insert on each node, verify convergence across all 3)

### Verify replication

```bash
# Check subscription status on all nodes
docker exec turboapi_pg_node1 psql -U appuser -d app_db -c \
  "SELECT subscription_name, status FROM pglogical.show_subscription_status();"

docker exec turboapi_pg_node2 psql -U appuser -d app_db -c \
  "SELECT subscription_name, status FROM pglogical.show_subscription_status();"

docker exec turboapi_pg_node3 psql -U appuser -d app_db -c \
  "SELECT subscription_name, status FROM pglogical.show_subscription_status();"

# Insert on one node, verify it appears on the others
docker exec turboapi_pg_node1 psql -U appuser -d app_db -c \
  "INSERT INTO benchmark_table (data) VALUES ('test_from_node1');"

sleep 3

docker exec turboapi_pg_node2 psql -U appuser -d app_db -c \
  "SELECT * FROM benchmark_table WHERE data = 'test_from_node1';"

docker exec turboapi_pg_node3 psql -U appuser -d app_db -c \
  "SELECT * FROM benchmark_table WHERE data = 'test_from_node1';"
```

### PostgreSQL tuning

All nodes share the same tuning parameters (defined as `x-pg-tuning` in `docker-compose.yml`):

| Parameter | Value | Purpose |
|---|---|---|
| `shared_preload_libraries` | `pglogical,pg_stat_statements` | Required extensions |
| `wal_level` | `logical` | Required for pglogical |
| `max_connections` | 200 | Connection headroom |
| `shared_buffers` | 256MB | In-memory page cache |
| `effective_cache_size` | 512MB | Planner hint |
| `work_mem` | 16MB | Per-operation sort/hash memory |
| `max_replication_slots` | 10 | Enough for 6 subscriptions + headroom |
| `max_wal_senders` | 10 | Matching replication slots |
| `max_wal_size` | 2GB | WAL retention |
| `wal_keep_size` | 1GB | Prevents WAL recycling before replicas catch up |
| `statement_timeout` | 300s | Kill runaway queries |
| `idle_in_transaction_session_timeout` | 60s | Kill idle transactions |

### Connect to a node from host

```bash
# The PG ports are not exposed by default. Use docker exec:
docker exec -it turboapi_pg_node1 psql -U appuser -d app_db
docker exec -it turboapi_pg_node2 psql -U appuser -d app_db
docker exec -it turboapi_pg_node3 psql -U appuser -d app_db

# Useful queries
docker exec turboapi_pg_node1 psql -U appuser -d app_db -c "SELECT version();"
docker exec turboapi_pg_node1 psql -U appuser -d app_db -c "\dt"
docker exec turboapi_pg_node1 psql -U appuser -d app_db -c \
  "SELECT query, calls, mean_exec_time, total_exec_time
   FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;"
```

## Valkey HA Cluster

### Architecture

- **1 primary** — read/write, AOF + RDB persistence, 384MB maxmemory with LRU eviction
- **2 replicas** — read-only, async replication from primary
- **3 sentinels** — monitor the primary, quorum of 2 for automatic failover

The apps connect via **Sentinel-aware clients** (`redis.asyncio.sentinel.Sentinel`), so they automatically follow failovers.

### Verify Valkey cluster

```bash
# Check primary info
docker exec turboapi_valkey valkey-cli info replication

# Check sentinel status
docker exec turboapi_valkey_sentinel1 valkey-cli -p 26379 sentinel master valkey-primary

# List replicas known to sentinel
docker exec turboapi_valkey_sentinel1 valkey-cli -p 26379 sentinel replicas valkey-primary

# Check key count
docker exec turboapi_valkey valkey-cli dbsize

# Flush all cache (careful!)
docker exec turboapi_valkey valkey-cli flushall
```

## Environment Variables

Copy `.env.example` to `.env`. All values have sensible defaults in `docker-compose.yml`.

| Variable | Default | Description |
|---|---|---|
| `POSTGRES_USER` | `appuser` | PostgreSQL username (all nodes) |
| `POSTGRES_PASSWORD` | `changeme_prod_2024` | PostgreSQL password |
| `POSTGRES_DB` | `app_db` | Database name |
| `DATABASE_POOL_SIZE` | `20` | SQLAlchemy async pool size |
| `DATABASE_MAX_OVERFLOW` | `10` | Pool overflow connections |
| `CACHE_DEFAULT_TTL` | `300` | Default cache TTL (seconds) |
| `UVICORN_WORKERS` | `4` | Workers per app |
| `UVICORN_TIMEOUT_KEEP_ALIVE` | `65` | Keep-alive timeout |
| `UVICORN_LIMIT_CONCURRENCY` | `1000` | Max concurrent connections |
| `UVICORN_ACCESS_LOG` | `false` | Access log toggle |
| `VALKEY_MAX_CONNECTIONS` | `100` | Max Valkey connections per app |
| `LOG_LEVEL` | `INFO` | Application log level |

### Tuning for higher load

```bash
# In .env:
UVICORN_WORKERS=8
UVICORN_LIMIT_CONCURRENCY=5000
DATABASE_POOL_SIZE=50
DATABASE_MAX_OVERFLOW=20
VALKEY_MAX_CONNECTIONS=200
```

## Project Structure

```
turboapi/
├── docker-compose.yml               # Single unified compose file
├── .env                              # Environment variables
├── .env.example                      # Environment template
├── postgres/
│   ├── Dockerfile                    # PG 18 + pglogical extension
│   ├── init.sql                      # Schema, extensions, tables (all nodes)
│   ├── pg_hba.conf                   # Auth config (covers 172.28.0.0/16)
│   └── setup_replication.sh          # 3-node full-mesh pglogical setup
├── valkey/
│   └── sentinel.conf                 # Sentinel monitoring config
├── app_fastapi/
│   ├── Dockerfile
│   ├── main.py                       # FastAPI app (sentinel-aware Valkey)
│   ├── config.py                     # Settings via pydantic-settings
│   ├── entrypoint.sh                 # Uvicorn startup script
│   └── requirements.txt
├── app_turbo/
│   ├── Dockerfile
│   ├── main.py                       # TurboAPI app (L1 TTL cache + sentinel)
│   ├── config.py                     # Settings
│   ├── entrypoint.sh                 # Uvicorn startup script
│   └── requirements.txt
├── benchmarks/
│   ├── Dockerfile                    # wrk + locust image
│   ├── locustfile.py                 # Single APIUser class, --host flag
│   ├── run_benchmarks.sh             # wrk-based sequential A/B comparison
│   ├── requirements.txt
│   └── results/                      # Benchmark output (git-ignored)
└── README.md
```

## Troubleshooting

### Check logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f pg_node1
docker compose logs -f pg_setup
docker compose logs -f app_fastapi
docker compose logs -f valkey_sentinel1
```

### pg_setup failed or replication not working

```bash
# Re-run setup (tear down volumes first for a clean slate)
docker compose down -v
docker compose up -d --build

# Or just re-run the setup container
docker compose up pg_setup
```

### Apps can't connect to database

The apps depend on `pg_setup` completing successfully. If `pg_setup` failed, the apps won't start. Check `docker compose logs pg_setup` for errors.

### Clear all data and start fresh

```bash
docker compose down -v --remove-orphans
docker compose up -d --build
```

### Sentinel can't find primary after restart

If Valkey containers were stopped uncleanly, sentinel state may be stale. Remove volumes:

```bash
docker compose down -v
docker compose up -d
```

## Key Design Decisions

- **pglogical over native PG logical replication**: pglogical's `forward_origins` parameter is essential for preventing infinite loops in bidirectional/multi-master topologies. Native PG logical replication does not have an equivalent.
- **`forward_origins := '{}'`**: Each subscription only replicates rows that originated locally on the provider, preventing replication loops in the 3-node mesh.
- **`REPLICA IDENTITY` using default (PK)**: All replicated tables have primary keys, so pglogical uses PK-based identity for UPDATE/DELETE replication. No need for `REPLICA IDENTITY FULL`.
- **Staggered SERIAL sequences**: Each node uses `INCREMENT BY 3` with different start offsets (node1=1, node2=2, node3=3) so concurrent multi-master writes never produce conflicting primary keys (node1: 1,4,7..., node2: 2,5,8..., node3: 3,6,9...).
- **Sentinel over Valkey Cluster**: Sentinel provides HA failover for a single primary, which is simpler and sufficient for this caching use case. Valkey Cluster (sharding) would be overkill.
- **Single `docker-compose.yml`**: All infrastructure in one file, no multi-file confusion. The benchmark service uses a Docker Compose profile (`--profile benchmark`) so it only starts on demand.

## License

MIT
