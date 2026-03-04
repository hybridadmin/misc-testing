# Forgejo Production Docker Setup

A production-ready, security-hardened Docker Compose deployment for
[Forgejo](https://forgejo.org) -- the self-hosted Git forge.

## Architecture

```
                    ┌─────────────────────────────────────────────────────┐
                    │                  frontend network                   │
    :3000 (HTTP) ───┤                                                     │
    :2222 (SSH)  ───┤          ┌──────────────────────┐                   │
                    │          │      Forgejo          │                   │
                    │          │  (rootless, v14)      │                   │
                    │          └───────┬─────┬─────────┘                   │
                    └─────────────────┼─────┼─────────────────────────────┘
                                      │     │
                    ┌─────────────────┼─────┼─────────────────────────────┐
                    │                 │     │    backend network           │
                    │                 │     │    (internal, no egress)     │
                    │                 ▼     ▼                              │
                    │  ┌──────────────────┐  ┌─────────────────────┐      │
                    │  │  PostgreSQL 18   │  │    Valkey 9         │      │
                    │  │  (Trixie)        │  │    (Alpine)         │      │
                    │  │  :5432           │  │    :6379            │      │
                    │  └────────┬─────────┘  └─────────────────────┘      │
                    │           │                                          │
                    │           ▼                                          │
                    │  ┌──────────────────┐                                │
                    │  │  Backup sidecar  │                                │
                    │  │  (pg_dump daily) │──▶  backup-data volume         │
                    │  └──────────────────┘                                │
                    └─────────────────────────────────────────────────────┘
```

### Services

| Service | Image | Role | Ports |
|---------|-------|------|-------|
| **forgejo** | `codeberg.org/forgejo/forgejo:14-rootless` | Git forge server | `3000` (HTTP), `2222` (SSH) |
| **postgres** | `postgres:18-trixie` | Primary database | None (internal only) |
| **valkey** | `valkey/valkey:9-alpine` | Cache, sessions, and queue | None (internal only) |
| **backup** | `postgres:18-trixie` | Automated daily pg_dump | None |

### Networks

| Network | Type | Purpose |
|---------|------|---------|
| `frontend` | bridge | Public-facing; only Forgejo is attached and publishes ports |
| `backend` | bridge, **internal** | Database and cache; no internet access, no published ports |

### Volumes

| Volume | Used by | Contents |
|--------|---------|----------|
| `forgejo-data` | forgejo | Repositories, LFS objects, avatars, actions artifacts |
| `forgejo-config` | forgejo | `app.ini` configuration and custom templates |
| `postgres-data` | postgres | PostgreSQL data directory (`PGDATA`) |
| `valkey-data` | valkey | AOF + RDB persistence files |
| `backup-data` | backup | Compressed SQL backup archives |

---

## Quick Start

```bash
# 1. Clone and enter the directory
cd forgejo

# 2. Create your .env from the template
cp .env.example .env

# 3. Generate all required secrets
# Forgejo tokens (64-char hex strings)
openssl rand -hex 32   # --> FORGEJO_SECRET_KEY
openssl rand -hex 32   # --> FORGEJO_INTERNAL_TOKEN
openssl rand -hex 32   # --> FORGEJO_LFS_JWT_SECRET

# Database and cache passwords
openssl rand -base64 24   # --> POSTGRES_PASSWORD
openssl rand -base64 24   # --> VALKEY_PASSWORD

# 4. Edit .env with your generated values
$EDITOR .env

# 5. Start the stack
docker compose up -d

# 6. Follow startup logs
docker compose logs -f forgejo

# 7. Open Forgejo
open http://localhost:3000
```

The first user you register will automatically become the administrator.

---

## File Structure

```
forgejo/
├── .env                         # Secrets and configuration (git-ignored)
├── .env.example                 # Safe-to-commit template for .env
├── .gitignore                   # Excludes .env and runtime data dirs
├── docker-compose.yml           # Full stack definition
├── config/
│   ├── postgres-initdb.sh       # One-time DB initialization (extensions)
│   └── valkey.conf              # Production-tuned Valkey configuration
└── scripts/
    └── backup.sh                # Automated pg_dump with retention cleanup
```

---

## Environment Variables

All configuration is driven through the `.env` file. No secrets are hardcoded.

### General

| Variable | Default | Description |
|----------|---------|-------------|
| `COMPOSE_PROJECT_NAME` | `forgejo` | Docker Compose project name (prefixes container names) |

### Forgejo

| Variable | Default | Description |
|----------|---------|-------------|
| `FORGEJO_IMAGE` | `codeberg.org/forgejo/forgejo:14-rootless` | Container image to use |
| `FORGEJO_HTTP_PORT` | `3000` | Host port for the web UI and API |
| `FORGEJO_SSH_PORT` | `2222` | Host port for Git-over-SSH |
| `USER_UID` | `1000` | UID the Forgejo process runs as |
| `USER_GID` | `1000` | GID the Forgejo process runs as |
| `FORGEJO_ROOT_URL` | `http://localhost:3000` | Public-facing URL (set to your `https://` domain) |
| `FORGEJO_DOMAIN` | `localhost` | Domain shown in clone URLs |
| `FORGEJO_SSH_DOMAIN` | `localhost` | Domain shown in SSH clone URLs |
| `FORGEJO_SECRET_KEY` | -- | **Required.** Signs authentication tokens. Generate: `openssl rand -hex 32` |
| `FORGEJO_INTERNAL_TOKEN` | -- | **Required.** Signs internal API tokens. Generate: `openssl rand -hex 32` |
| `FORGEJO_LFS_JWT_SECRET` | -- | **Required.** Signs LFS JWT tokens. Generate: `openssl rand -hex 32` |

### PostgreSQL

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_USER` | `forgejo` | Database username |
| `POSTGRES_PASSWORD` | -- | **Required.** Database password. Generate: `openssl rand -base64 24` |
| `POSTGRES_DB` | `forgejo` | Database name |

### Valkey

| Variable | Default | Description |
|----------|---------|-------------|
| `VALKEY_PASSWORD` | -- | **Required.** Cache authentication password. Generate: `openssl rand -base64 24` |

### Backup

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_INTERVAL_SECONDS` | `86400` | Seconds between backups (86400 = 24 hours) |
| `BACKUP_RETENTION_DAYS` | `30` | Backups older than this are automatically deleted |

---

## Security Best Practices Applied

### Container Security

| Practice | Implementation |
|----------|---------------|
| **Rootless image** | Uses `forgejo:14-rootless` -- no process ever runs as root |
| **no-new-privileges** | Set on every container via `security_opt`, prevents privilege escalation |
| **Non-root user** | Forgejo runs as `1000:1000` (configurable via `USER_UID`/`USER_GID`) |
| **Resource limits** | CPU and memory caps on all containers prevent runaway consumption |
| **Log rotation** | `json-file` driver with `max-size` and `max-file` on every service |
| **Restart policy** | `unless-stopped` for automatic crash recovery without boot-time starts |

### Network Security

| Practice | Implementation |
|----------|---------------|
| **Network isolation** | `backend` network is `internal: true` -- no outbound internet access |
| **Minimal port exposure** | Only Forgejo publishes ports; Postgres and Valkey are never reachable from the host |
| **Separate networks** | `frontend` (public) and `backend` (private) prevent lateral movement |

### Authentication and Secrets

| Practice | Implementation |
|----------|---------------|
| **Strong passwords** | Minimum 12 characters, must include lower + upper + digit + special |
| **HaveIBeenPwned check** | `PASSWORD_CHECK_PWN=true` rejects passwords found in breach databases |
| **SCRAM-SHA-256** | PostgreSQL uses `scram-sha-256` password encryption (not MD5) |
| **Secrets in .env** | All tokens and passwords live in `.env`, which is git-ignored |
| **Disabled Valkey commands** | `FLUSHDB`, `FLUSHALL`, `DEBUG`, `CONFIG` are all disabled |
| **INSTALL_LOCK** | Prevents the setup wizard from being accessible after initial deployment |

### Privacy

| Practice | Implementation |
|----------|---------------|
| **Offline mode** | `OFFLINE_MODE=true` -- no external calls for Gravatar, CDNs, etc. |
| **Email privacy** | `DEFAULT_KEEP_EMAIL_PRIVATE=true` for new users |
| **Hidden version** | Footer does not expose the Forgejo version or render time |
| **Limited visibility** | Default user visibility is `limited` (not public) |

---

## PostgreSQL 18 Configuration

The database is tuned for a small-to-medium Forgejo instance via command-line flags.

### Connection

| Setting | Value | Rationale |
|---------|-------|-----------|
| `max_connections` | `200` | Headroom for Forgejo connection pool + admin connections |

### Memory

| Setting | Value | Rationale |
|---------|-------|-----------|
| `shared_buffers` | `256MB` | ~25% of the 1GB container memory limit |
| `effective_cache_size` | `768MB` | ~75% of container memory; guides query planner |
| `work_mem` | `4MB` | Per-operation sort/hash memory |
| `maintenance_work_mem` | `128MB` | VACUUM, CREATE INDEX operations |

### WAL

| Setting | Value | Rationale |
|---------|-------|-----------|
| `wal_buffers` | `16MB` | Matches shared_buffers scale |
| `checkpoint_completion_target` | `0.9` | Spreads I/O over checkpoint interval |
| `wal_level` | `replica` | Enables streaming replication and PITR if needed later |

### Logging

| Setting | Value | Rationale |
|---------|-------|-----------|
| `log_min_duration_statement` | `1000ms` | Logs slow queries (> 1 second) |
| `log_checkpoints` | `on` | Audit checkpoint frequency |
| `log_connections` | `on` | Track connection activity |
| `log_disconnections` | `on` | Track disconnection activity |
| `log_lock_waits` | `on` | Surface lock contention |

### Security

| Setting | Value | Rationale |
|---------|-------|-----------|
| `password_encryption` | `scram-sha-256` | Strongest built-in auth method |

### PGDATA Directory

PostgreSQL 18 changed the default `PGDATA` to `/var/lib/postgresql/data/pgdata`
(a subdirectory). This avoids the `initdb` error when the volume mount root contains
`lost+found` or other filesystem artifacts. Both the volume mount and the `PGDATA`
environment variable are set explicitly to this path.

### Init Script

`config/postgres-initdb.sh` runs once on first volume initialization:

- Enables `pg_trgm` extension (trigram-based text search acceleration)
- Sets `default_text_search_config` to English
- Sets `client_encoding` to UTF-8

---

## Valkey 9 Configuration

Valkey serves three roles for Forgejo, each on a separate database:

| Database | Role | Connection |
|----------|------|------------|
| `db0` | **Cache** | Page cache, computed values |
| `db1` | **Sessions** | User login sessions |
| `db2` | **Queue** | Background job queue |

### Key Settings (`config/valkey.conf`)

| Setting | Value | Rationale |
|---------|-------|-----------|
| `maxmemory` | `200mb` | Bounded within the 256MB container limit |
| `maxmemory-policy` | `allkeys-lru` | Evict least-recently-used keys when full |
| `maxclients` | `10000` | High ceiling for connection pooling |
| `appendonly` | `yes` | AOF persistence for session/queue durability |
| `appendfsync` | `everysec` | Flush to disk every second (balance of safety and speed) |
| `save 900 1` / `300 10` / `60 10000` | -- | RDB snapshots as a backup safety net |
| `timeout` | `300` | Close idle connections after 5 minutes |
| `tcp-keepalive` | `60` | Detect dead connections every 60 seconds |
| `latency-monitor-threshold` | `100ms` | Track operations slower than 100ms |
| `slowlog-log-slower-than` | `10ms` | Log commands slower than 10ms |
| Disabled commands | `FLUSHDB`, `FLUSHALL`, `DEBUG`, `CONFIG` | Prevents accidental data wipe or config tampering |

The password is injected via the `--requirepass` flag on the command line rather than
being written into the config file, so `valkey.conf` contains no secrets and can be
safely committed to version control.

---

## Forgejo Application Configuration

Configuration is set entirely through environment variables using the
`FORGEJO__[section]__[key]` naming convention. These are written to `app.ini`
on first start and can be overridden by editing the file directly inside the
`forgejo-config` volume.

### Enabled Features

| Feature | Setting | Notes |
|---------|---------|-------|
| **Git LFS** | `LFS_START_SERVER=true` | Large file storage with JWT auth |
| **Actions (CI/CD)** | `ACTIONS__ENABLED=true` | Requires a [Forgejo Runner](https://forgejo.org/docs/latest/admin/actions/runner-installation/) |
| **Repository indexing** | `REPO_INDEXER_ENABLED=true` | Full-text code search (bleve engine) |
| **Issue indexing** | `ISSUE_INDEXER_TYPE=bleve` | Full-text issue/PR search |
| **Captcha** | `ENABLE_CAPTCHA=true` | Protects registration from bots |
| **Cron jobs** | `ENABLED=true` | Repository maintenance, cleanup tasks |

### Mailer (Disabled by Default)

Email is commented out in `docker-compose.yml`. To enable, uncomment and configure:

```yaml
- FORGEJO__mailer__ENABLED=true
- FORGEJO__mailer__PROTOCOL=smtps
- FORGEJO__mailer__SMTP_ADDR=smtp.example.com
- FORGEJO__mailer__SMTP_PORT=465
- FORGEJO__mailer__USER=noreply@example.com
- FORGEJO__mailer__PASSWD=your_smtp_password
- FORGEJO__mailer__FROM=noreply@example.com
```

---

## Automated Backups

The `backup` sidecar runs inside the same `backend` network as PostgreSQL and
performs automated `pg_dump` backups on a configurable interval.

### How It Works

1. On container start, an immediate backup is taken
2. The container then sleeps for `BACKUP_INTERVAL_SECONDS` (default: 24 hours)
3. After each sleep cycle, a new backup is created
4. Backups older than `BACKUP_RETENTION_DAYS` are automatically deleted

### Backup Format

- **File name pattern:** `forgejo_YYYYMMDD_HHMMSS.sql.gz`
- **Compression:** gzip level 9
- **Flags:** `--no-owner --no-privileges` for portability across environments
- **Validation:** Each backup is checked for a minimum size to catch empty/failed dumps

### Viewing Backups

```bash
# List all backups
docker compose exec backup ls -lh /backups/

# Check backup container logs
docker compose logs backup
```

### Manual Backup

```bash
docker compose exec backup /usr/local/bin/backup.sh
```

### Restoring from Backup

```bash
# 1. Stop Forgejo to prevent writes
docker compose stop forgejo

# 2. Copy backup from container to host
docker compose cp backup:/backups/forgejo_20260304_020000.sql.gz ./restore.sql.gz

# 3. Decompress
gunzip restore.sql.gz

# 4. Drop and recreate the database
docker compose exec postgres psql -U forgejo -c "DROP DATABASE forgejo;"
docker compose exec postgres psql -U forgejo -c "CREATE DATABASE forgejo;"

# 5. Restore
docker compose exec -T postgres psql -U forgejo -d forgejo < restore.sql

# 6. Restart Forgejo
docker compose start forgejo
```

---

## Resource Limits

Every container has CPU and memory constraints to prevent runaway resource usage.

| Service | CPU Limit | Memory Limit | CPU Reserved | Memory Reserved |
|---------|-----------|-------------|--------------|-----------------|
| forgejo | 2.0 | 1536 MB | 0.5 | 512 MB |
| postgres | 1.5 | 1024 MB | 0.25 | 256 MB |
| valkey | 0.5 | 256 MB | 0.1 | 64 MB |
| backup | 0.25 | 128 MB | -- | -- |

**Total maximum:** 4.25 CPUs, ~2.9 GB RAM

Adjust these in `docker-compose.yml` under `deploy.resources` to match your host.

---

## Health Checks

All primary services have health checks. Forgejo will not start until both
Postgres and Valkey report healthy.

| Service | Check | Interval | Timeout | Retries | Start Period |
|---------|-------|----------|---------|---------|-------------|
| forgejo | `curl http://localhost:3000/api/healthz` | 30s | 10s | 5 | 60s |
| postgres | `pg_isready -U forgejo -d forgejo` | 10s | 5s | 5 | 30s |
| valkey | `valkey-cli ping` (with auth) | 10s | 5s | 5 | 10s |

---

## Common Operations

### View Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f forgejo
docker compose logs -f postgres
```

### Access the Forgejo CLI

```bash
docker compose exec forgejo forgejo admin user list
docker compose exec forgejo forgejo admin user create \
  --username admin \
  --password 'YourStr0ng!Pass' \
  --email admin@example.com \
  --admin
```

### Connect to PostgreSQL

```bash
docker compose exec postgres psql -U forgejo -d forgejo
```

### Monitor Valkey

```bash
# Real-time commands
docker compose exec valkey valkey-cli -a "$VALKEY_PASSWORD" --no-auth-warning monitor

# Memory usage
docker compose exec valkey valkey-cli -a "$VALKEY_PASSWORD" --no-auth-warning info memory

# Connected clients
docker compose exec valkey valkey-cli -a "$VALKEY_PASSWORD" --no-auth-warning info clients
```

### Upgrade Forgejo

```bash
# 1. Pull the new image
docker compose pull forgejo

# 2. Recreate the container (data volumes are preserved)
docker compose up -d forgejo

# 3. Check logs for migration output
docker compose logs -f forgejo
```

Major version upgrades (e.g. v14 to v15) require reading the
[upgrade guide](https://forgejo.org/docs/latest/admin/upgrade/) first.

### Stop Everything

```bash
# Stop but keep volumes
docker compose down

# Stop and remove volumes (DESTROYS ALL DATA)
docker compose down -v
```

---

## Production Checklist

Before exposing this to the internet:

- [ ] **Set `FORGEJO_ROOT_URL`** to your actual `https://` domain
- [ ] **Set `FORGEJO__session__COOKIE_SECURE=true`** (in docker-compose.yml) when behind HTTPS
- [ ] **Place a reverse proxy** (Nginx, Caddy, or Traefik) in front for TLS termination
- [ ] **Enable the mailer** for email notifications and password resets
- [ ] **Set `FORGEJO__service__DISABLE_REGISTRATION=true`** after creating your admin account
- [ ] **Mount `backup-data`** to external or remote storage for disaster recovery
- [ ] **Regenerate all secrets** in `.env` -- do not reuse the example values
- [ ] **Set up a Forgejo Runner** if you want to use Forgejo Actions (CI/CD)
- [ ] **Configure firewall rules** to restrict access to ports 3000 and 2222
- [ ] **Set up monitoring** (Prometheus metrics available at `/metrics` when enabled)
- [ ] **Test backup restore** at least once before relying on it

---

## Reverse Proxy Examples

### Caddy (simplest -- automatic HTTPS)

```
git.example.com {
    reverse_proxy localhost:3000
}
```

### Nginx

```nginx
server {
    listen 443 ssl http2;
    server_name git.example.com;

    ssl_certificate     /etc/ssl/certs/git.example.com.pem;
    ssl_certificate_key /etc/ssl/private/git.example.com.key;

    client_max_body_size 512M;  # For large Git pushes and LFS

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

---

## Troubleshooting

### Forgejo won't start

```bash
# Check dependency health first
docker compose ps
docker compose logs postgres
docker compose logs valkey

# Then check Forgejo logs
docker compose logs forgejo
```

Common causes:
- Postgres or Valkey not healthy yet (check `depends_on` conditions)
- Wrong `redis://` URL scheme (must not be `redis+cluster://` for standalone Valkey)
- Incorrect `PGDATA` path for PostgreSQL 18

### Permission denied on volumes

The Forgejo rootless image requires volume ownership matching `USER_UID:USER_GID`:

```bash
# Check current ownership
docker compose exec forgejo ls -la /var/lib/gitea/
docker compose exec forgejo ls -la /etc/gitea/

# If using bind mounts instead of named volumes:
sudo chown -R 1000:1000 ./forgejo ./conf
```

### Backup container keeps restarting

Check logs for errors:

```bash
docker compose logs backup
```

Common causes:
- PostgreSQL not healthy when backup runs (the script retries automatically)
- Permissions on the backup volume

### Database connection refused

Verify PostgreSQL is running and healthy:

```bash
docker compose exec postgres pg_isready -U forgejo -d forgejo
```

---

## References

- [Forgejo Docker Installation Guide](https://forgejo.org/docs/latest/admin/installation/docker/)
- [Forgejo Configuration Cheat Sheet](https://forgejo.org/docs/latest/admin/config-cheat-sheet/)
- [Forgejo Reverse Proxy Setup](https://forgejo.org/docs/latest/admin/setup/reverse-proxy/)
- [Forgejo Actions Runner Installation](https://forgejo.org/docs/latest/admin/actions/runner-installation/)
- [Forgejo Upgrade Guide](https://forgejo.org/docs/latest/admin/upgrade/)
- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/18/release-18.html)
- [Valkey Documentation](https://valkey.io/docs/)
