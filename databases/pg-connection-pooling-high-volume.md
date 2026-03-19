# PostgreSQL Connection Pooling for High-Volume Workloads

## The Problem: Direct Connections Don't Scale

Benchmarked PostgreSQL running on an **r8g.2xlarge** (8 vCPU + 64GB RAM) with connections ranging from 8 to 2048. There is a clear sweet spot at **64 connections** with degrading performance thereafter.

Applications often need thousands of connections. The answer: **scale with a proxy**.

## Why Direct Connections Degrade

PostgreSQL forks a **separate backend process** for each connection. At high connection counts (beyond the CPU-optimal sweet spot), you get:

- **Context switching overhead** — the OS spends more time switching between hundreds/thousands of processes than doing actual work
- **Lock contention** — internal lightweight locks (e.g., `ProcArrayLock`, `WALWriteLock`) become heavily contended
- **Memory pressure** — each backend consumes ~5-10 MB of RSS, so 2048 connections = 10-20 GB just for connection overhead
- **Cache thrashing** — CPU L1/L2/L3 caches get invalidated constantly

## The Solution: Connection Pooling

### Architecture

```
App instances (1000s of connections)
        |
        v
   Connection Pooler (PgBouncer / PgCat)
   - Accepts 1000s of client connections
   - Maintains ~64 actual PG connections (matching the sweet spot)
        |
        v
   PostgreSQL (r8g.2xlarge)
   - Only sees 64 active backends
   - Operates at peak efficiency
```

### Recommended Poolers

#### PgBouncer (most common)

- Lightweight, single-threaded (run multiple instances if needed)
- Supports **transaction-mode pooling** — a small pool of actual PG connections (e.g., 64) serves thousands of client connections
- Minimal latency overhead (~100us)
- Battle-tested, widely deployed

#### PgCat (newer, Rust-based)

- Multi-threaded, built for high throughput
- Supports load balancing across replicas
- Drop-in replacement for PgBouncer in most cases

#### Supavisor

- Elixir-based, from Supabase
- Multi-tenant aware
- Good fit for serverless / multi-tenant platforms

#### Odyssey

- From Yandex
- Multi-threaded
- Supports transaction pooling

## Pool Sizing Rule of Thumb

The optimal pool size for OLTP workloads is roughly:

```
pool_size = (CPU cores * 2) + effective_spindle_count
```

For an 8 vCPU instance:

| Workload Type | Recommended Pool Size |
|---|---|
| Write-heavy | ~16-20 |
| Mixed / read-heavy | ~48-64 |

This aligns with the benchmark showing **64 as the sweet spot** on an 8 vCPU machine.

## Key Takeaway

The application can open thousands of connections to the pooler. The pooler queues and multiplexes them onto a small, fixed set of real PostgreSQL connections. The database always operates at its optimal concurrency point, regardless of how many app instances or serverless functions are connecting.

## References

- [PgBouncer](https://www.pgbouncer.org/)
- [PgCat](https://github.com/postgresml/pgcat)
- [Supavisor](https://github.com/supabase/supavisor)
- [Odyssey](https://github.com/yandex/odyssey)
