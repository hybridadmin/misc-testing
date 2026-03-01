# PostgreSQL Monitoring Stack

A Docker Compose setup that monitors a PostgreSQL 18 database using Prometheus and Grafana, with a pre-configured datasource and dashboard.

## Architecture

```
PostgreSQL 18 --> postgres_exporter --> Prometheus --> Grafana
   :5432             :9187               :9090        :3000
```

- **PostgreSQL 18** -- the database being monitored
- **postgres_exporter** -- connects to PostgreSQL and exposes metrics at `/metrics` in Prometheus format
- **Prometheus** -- scrapes metrics from postgres_exporter every 15 seconds
- **Grafana** -- visualizes the metrics with a pre-provisioned dashboard and Prometheus datasource

## Project Structure

```
monitoring/
├── docker-compose.yml
├── prometheus/
│   └── prometheus.yml                  # Prometheus scrape configuration
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/
│   │   │   └── datasource.yml          # Auto-provisioned Prometheus datasource
│   │   └── dashboards/
│   │       └── dashboards.yml          # Dashboard file provider config
│   └── dashboards/
│       └── postgresql.json             # PostgreSQL monitoring dashboard
└── README.md
```

## Quick Start

```bash
docker compose up -d
```

Wait a few seconds for all services to become healthy, then open Grafana.

## Stopping

```bash
# Stop and keep data volumes
docker compose down

# Stop and remove all data volumes
docker compose down -v
```

## Access

| Service            | URL                          | Credentials       |
|--------------------|------------------------------|--------------------|
| Grafana            | http://localhost:3000         | `admin` / `admin`  |
| Prometheus         | http://localhost:9090         | --                 |
| postgres_exporter  | http://localhost:9187/metrics | --                 |
| PostgreSQL         | `localhost:5432`             | `postgres` / `postgres` |

## Pre-Configured Datasource

Grafana starts with a **Prometheus** datasource already provisioned and set as the default. No manual datasource configuration is needed. The provisioning file is at `grafana/provisioning/datasources/datasource.yml`.

## Dashboard

The **PostgreSQL Monitoring** dashboard is automatically loaded on startup and includes the following panels:

### Overview

| Panel              | Description                                      |
|--------------------|--------------------------------------------------|
| PostgreSQL Up      | Whether the database is reachable (UP/DOWN)      |
| Uptime             | Time since the postmaster process started         |
| Active Connections | Number of connections in `active` state           |
| Total Connections  | Sum of all connections across all states           |
| Database Size      | Size of the `appdb` database in bytes             |
| Locks Held         | Total number of locks currently held               |

### Connections

- **Connections by State** -- stacked time series of connections grouped by state (active, idle, idle in transaction, etc.)
- **Connections by Database** -- stacked time series of connections grouped by database name

### Database Activity

- **Transactions per Second** -- commit and rollback rates for `appdb`
- **Tuple Operations (Rows/s)** -- rate of fetched, inserted, updated, deleted, and returned rows

### Cache & I/O

- **Cache Hit Ratio** -- proportion of block reads served from shared buffers vs disk (target: close to 1.0)
- **Block Read/Hit Rate** -- bytes/s of disk reads vs cache hits

### Locks & Conflicts

- **Locks by Mode** -- stacked time series of locks grouped by lock mode
- **Deadlocks & Conflicts** -- rate of deadlocks and conflicts per second

### Replication & WAL

- **Database Size Over Time** -- tracks `appdb` size over time
- **Temp Files & Bytes** -- rate of temporary file creation and bytes written

## PostgreSQL Connection

Connect to the database from the host:

```bash
psql -h localhost -U postgres -d appdb
# password: postgres
```

Or from another container on the same Docker network:

```
postgresql://postgres:postgres@postgres:5432/appdb?sslmode=disable
```

## Configuration

### Prometheus

Edit `prometheus/prometheus.yml` to change scrape intervals or add additional targets. The default scrape interval is 15 seconds.

### Grafana

- Datasources are provisioned from `grafana/provisioning/datasources/`
- Dashboard file provider is configured in `grafana/provisioning/dashboards/`
- Dashboard JSON files live in `grafana/dashboards/`

To add more dashboards, drop a JSON file into `grafana/dashboards/` and restart Grafana (or it will be picked up automatically).

### PostgreSQL

Environment variables in `docker-compose.yml` control the database name, user, and password:

| Variable            | Default    |
|---------------------|------------|
| `POSTGRES_USER`     | `postgres` |
| `POSTGRES_PASSWORD` | `postgres` |
| `POSTGRES_DB`       | `appdb`    |

If you change these, also update the `DATA_SOURCE_NAME` in the `postgres-exporter` service.

## Ports

| Port  | Service           |
|-------|-------------------|
| 3000  | Grafana           |
| 5432  | PostgreSQL        |
| 9090  | Prometheus        |
| 9187  | postgres_exporter |

## Notes

- PostgreSQL 18 requires the data volume to be mounted at `/var/lib/postgresql` (not `/var/lib/postgresql/data` as in older versions). See [docker-library/postgres#1259](https://github.com/docker-library/postgres/pull/1259).
- All Grafana provisioning is read-only on startup. Dashboards can still be edited in the UI but changes won't persist to the JSON file on disk.
- Named Docker volumes (`pgdata`, `promdata`, `grafanadata`) persist data across restarts. Use `docker compose down -v` to remove them.
