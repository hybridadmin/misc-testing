# Nominatim with External PostgreSQL 18

Docker Compose setup for [Nominatim 5.2](https://github.com/mediagis/nominatim-docker) using an **external PostgreSQL 18 + PostGIS 3.6** database instead of the bundled internal database.

## Architecture

```
┌─────────────────────┐      ┌──────────────────────────┐
│  nominatim           │─────▶│  postgres                 │
│  mediagis/nominatim  │      │  postgis/postgis:18-3.6   │
│  :5.2                │      │                            │
│  Port 8080 (API)     │      │  Port 5432                 │
└─────────────────────┘      └──────────────────────────┘
         │                              │
         ▼                              ▼
  nominatim-data               nominatim-pgdata
  (Docker volume)              (Docker volume)
```

- **Nominatim** handles the OSM data import, geocoding API (search, reverse, lookup), and replication updates. A custom `start.sh` replaces the image's default entrypoint to bypass the internal PostgreSQL management.
- **PostgreSQL 18 + PostGIS 3.6** is the external database. Data persists in a named Docker volume (`nominatim-pgdata`).
- The two services communicate over an internal Docker bridge network (`nominatim-net`).

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Service definitions for Nominatim and PostgreSQL |
| `start.sh` | Custom entrypoint that bypasses the image's internal PostgreSQL and works with the external DB |
| `.env.example` | All configurable environment variables with defaults |
| `init-db.sql` | PostgreSQL init script: creates PostGIS/hstore extensions and the `www-data` role |

## Prerequisites

- Docker Engine 20.10+
- Docker Compose v2+
- Sufficient RAM and disk for your target OSM extract (see [Hardware Requirements](#hardware-requirements))

## Quick Start

```bash
# 1. Clone/copy this directory and create your .env
cp .env.example .env

# 2. (Optional) Edit .env to change the PBF_URL, passwords, tuning, etc.

# 3. Start everything
docker compose up -d

# 4. Follow the import progress
docker compose logs -f nominatim
```

The initial import downloads the PBF file and loads it into PostgreSQL. For Monaco this takes a few minutes; for larger extracts it can take hours or days.

Once import is complete you will see:

```
--> Nominatim is ready to accept requests
```

Test the API:

```bash
curl "http://localhost:8080/search?q=avenue+pasteur&format=json"
```

## Configuration

All configuration is done through environment variables in `.env`. Copy `.env.example` and adjust values.

### Data Source

| Variable | Default | Description |
|---|---|---|
| `PBF_URL` | Monaco extract | URL to an OSM PBF extract from [Geofabrik](https://download.geofabrik.de) or a mirror |
| `REPLICATION_URL` | Monaco updates | URL for replication diffs matching the extract |

To use a **local PBF file** instead of downloading one, remove `PBF_URL` from your `.env`, mount the file into the Nominatim container, and set `PBF_PATH` in the compose environment section. Example:

```yaml
# In docker-compose.yml, under nominatim.volumes:
- /path/to/your/data.osm.pbf:/nominatim/data/data.osm.pbf:ro
# And in environment:
PBF_PATH: /nominatim/data/data.osm.pbf
```

### PostgreSQL Tuning

The PostgreSQL container defaults are conservative (suitable for machines with 4-8 GB RAM). For production or large imports, scale these up proportionally to your available RAM:

| Variable | Default | Notes |
|---|---|---|
| `POSTGRES_SHARED_BUFFERS` | `256MB` | ~25% of available RAM |
| `POSTGRES_MAINTENANCE_WORK_MEM` | `256MB` | Higher = faster import (e.g. 10GB for planet) |
| `POSTGRES_AUTOVACUUM_WORK_MEM` | `128MB` | |
| `POSTGRES_WORK_MEM` | `32MB` | Per-operation memory |
| `POSTGRES_EFFECTIVE_CACHE_SIZE` | `1GB` | ~50-75% of available RAM |
| `POSTGRES_SYNCHRONOUS_COMMIT` | `off` | Faster writes, slight durability tradeoff |
| `POSTGRES_MAX_WAL_SIZE` | `1GB` | Reduce checkpoint frequency |
| `POSTGRES_CHECKPOINT_TIMEOUT` | `10min` | |
| `POSTGRES_CHECKPOINT_COMPLETION_TARGET` | `0.9` | |
| `POSTGRES_MAX_CONNECTIONS` | `200` | Must be >= GUNICORN_WORKERS * NOMINATIM_API_POOL_SIZE |
| `POSTGRES_SHM_SIZE` | `512m` | Docker shared memory for the postgres container |

### Import Options

| Variable | Default | Description |
|---|---|---|
| `IMPORT_STYLE` | `full` | Options: `admin`, `street`, `address`, `full`, `extratags` |
| `IMPORT_WIKIPEDIA` | `false` | Import Wikipedia importance data (improves result ranking) |
| `IMPORT_US_POSTCODES` | `false` | Import US postcode data |
| `IMPORT_GB_POSTCODES` | `false` | Import GB postcode data |
| `IMPORT_TIGER_ADDRESSES` | `false` | Import US TIGER address data |
| `REVERSE_ONLY` | `false` | Only import data needed for reverse geocoding |
| `THREADS` | `4` | Number of import threads |

### Update / Replication

| Variable | Default | Description |
|---|---|---|
| `UPDATE_MODE` | `none` | `continuous`, `once`, `catch-up`, or `none` |
| `REPLICATION_UPDATE_INTERVAL` | `86400` | Seconds between upstream diff publications |
| `REPLICATION_RECHECK_INTERVAL` | `900` | Seconds to wait before rechecking for updates |
| `FREEZE` | `false` | Freeze the database (disables updates, saves space) |

### Runtime / API

| Variable | Default | Description |
|---|---|---|
| `NOMINATIM_PORT` | `8080` | Host port for the Nominatim API |
| `GUNICORN_WORKERS` | `4` | Number of Gunicorn worker processes |
| `WARMUP_ON_STARTUP` | `false` | Pre-load tables into RAM on startup (slower start, faster first queries) |
| `NOMINATIM_SHM_SIZE` | `1g` | Docker shared memory for the nominatim container |

## Hardware Requirements

| Dataset | RAM | Disk | Import Time (approx.) |
|---|---|---|---|
| Monaco | 2 GB | 1 GB | ~2 minutes |
| Small country | 8 GB | 10-50 GB | 30 min - 2 hours |
| Europe | 64 GB | 500 GB+ | 12-24 hours |
| Full planet | 128 GB+ | 1 TB+ | 2-5 days |

For larger imports:
- Enable the flatnode file by uncommenting the `nominatim-flatnode` volume in `docker-compose.yml` (see [Flatnode File](#flatnode-file))
- Increase `POSTGRES_SHM_SIZE` and `NOMINATIM_SHM_SIZE`
- Increase PostgreSQL tuning values proportionally to your RAM

### Flatnode File

The flatnode file is an on-disk lookup table for OSM node coordinates. It significantly speeds up planet-scale imports but pre-allocates a large sparse file (50+ GB). **It is disabled by default.**

For country/region extracts (Monaco, Germany, etc.) it is unnecessary and can cause "No space left on device" errors on smaller disks.

To enable it for planet imports, uncomment these lines in `docker-compose.yml`:

```yaml
# In nominatim.volumes:
- nominatim-flatnode:/nominatim/flatnode

# In the top-level volumes section:
nominatim-flatnode:
  driver: local
```

## Data Persistence

All data is stored in named Docker volumes:

| Volume | Contents |
|---|---|
| `nominatim-pgdata` | PostgreSQL data directory (all imported OSM data) |
| `nominatim-data` | Nominatim project directory (config, import marker) |

To **completely reset** and re-import:

```bash
docker compose down -v   # removes containers AND volumes
docker compose up -d
```

To **stop without losing data**:

```bash
docker compose down      # keeps volumes intact
docker compose up -d     # resumes from existing data
```

## API Endpoints

Once running, the Nominatim API is available at `http://localhost:8080`:

| Endpoint | Description | Example |
|---|---|---|
| `/search` | Forward geocoding | `/search?q=Berlin&format=json` |
| `/reverse` | Reverse geocoding | `/reverse?lat=52.52&lon=13.405&format=json` |
| `/lookup` | Address lookup by OSM ID | `/lookup?osm_ids=R146656&format=json` |
| `/status` | Server status | `/status` |

Full API documentation: https://nominatim.org/release-docs/5.2/api/Overview/

## Connecting to the Database Directly

The PostgreSQL database is exposed on `localhost:5432` (configurable via `POSTGRES_PORT`):

```bash
psql -h localhost -U nominatim -d nominatim
# Password: value of POSTGRES_PASSWORD from .env
```

This is useful for:
- Running custom queries against the geocoding data
- Database backups (`pg_dump`)
- Monitoring and maintenance

## Backup and Restore

### Backup

```bash
docker compose exec postgres pg_dump -U nominatim -Fc nominatim > nominatim_backup.dump
```

### Restore

```bash
# Start only postgres
docker compose up -d postgres

# Restore the dump
docker compose exec -T postgres pg_restore -U nominatim -d nominatim --clean --if-exists < nominatim_backup.dump

# Start nominatim
docker compose up -d nominatim
```

## Updating the Database

To enable continuous replication updates, set in `.env`:

```
UPDATE_MODE=continuous
```

Or run a one-time catch-up:

```bash
docker compose exec nominatim sudo -u nominatim nominatim replication --project-dir /nominatim --catch-up
```

## How It Works

The stock `mediagis/nominatim:5.2` image assumes it manages its own internal PostgreSQL instance (calling `service postgresql start`, `createuser`, etc.). To use an external database, a custom `start.sh` is bind-mounted at `/custom/start.sh` and set as the container entrypoint. This script:

1. Calls `/app/config.sh` from the stock image to set up Nominatim's `.env` project file
2. Waits for the external PostgreSQL to be ready
3. Ensures the required `www-data` role exists
4. Runs `nominatim import` pointing at the external database via `NOMINATIM_DATABASE_DSN`
5. Handles optional data imports (Wikipedia, postcodes, Tiger)
6. Starts Gunicorn to serve the API

The import marker is stored at `/nominatim/import-finished` (inside the `nominatim-data` volume). On subsequent starts, the import is skipped and the API starts immediately.

## Important Notes

1. **Custom entrypoint**: The custom `start.sh` replaces the stock entrypoint to bypass internal PostgreSQL management. The internal PostgreSQL inside the image is never started.

2. **First import only**: The import runs only once. On subsequent container starts, Nominatim detects the existing import marker and skips re-import.

3. **PostGIS requirement**: PostgreSQL must have the PostGIS and hstore extensions. The `init-db.sql` script handles this automatically for the bundled `postgis/postgis:18-3.6` image.

4. **www-data role**: Nominatim requires a `www-data` database role for web query access. The `start.sh` script ensures this role exists before import.

5. **Do NOT set `POSTGRES_DB`**: The Nominatim import creates its own `nominatim` database. If it already exists, the import will fail.

6. **ARM / Apple Silicon**: The `postgis/postgis:18-3.6` image is amd64-only and runs under emulation on ARM Macs. The default memory settings are conservative to avoid shared memory allocation failures under emulation.

7. **Geofabrik rate limits**: Geofabrik limits download speeds. For planet-scale imports, use a [mirror](https://wiki.openstreetmap.org/wiki/Planet.osm#Planet.osm_mirrors).

## Troubleshooting

**Import fails with out-of-memory errors**
- Increase `POSTGRES_SHM_SIZE` and `NOMINATIM_SHM_SIZE`
- Lower `POSTGRES_MAINTENANCE_WORK_MEM` for machines with less RAM

**Import fails with "No space left on device"**
- If using the flatnode volume, ensure you have at least 60 GB free disk space, or disable it for smaller extracts (see [Flatnode File](#flatnode-file))
- Run `docker system df` to check Docker disk usage and `docker system prune` to reclaim space

**Connection refused to database**
- Ensure the `postgres` service is healthy: `docker compose ps`
- Check logs: `docker compose logs postgres`

**Nominatim API returns no results**
- Wait for the import to finish (check logs)
- Verify the correct `PBF_URL` was used
- Check database status: `curl http://localhost:8080/status`

**Slow queries**
- Set `WARMUP_ON_STARTUP=true` to pre-load caches
- Increase `POSTGRES_EFFECTIVE_CACHE_SIZE` and `POSTGRES_SHARED_BUFFERS`
- Increase `GUNICORN_WORKERS`

## References

- [mediagis/nominatim-docker](https://github.com/mediagis/nominatim-docker) -- Docker image source
- [Nominatim documentation](https://nominatim.org/release-docs/5.2/) -- Official docs
- [Nominatim API](https://nominatim.org/release-docs/5.2/api/Overview/) -- API reference
- [Geofabrik downloads](https://download.geofabrik.de) -- OSM data extracts
- [PostGIS Docker](https://hub.docker.com/r/postgis/postgis) -- PostgreSQL + PostGIS image
