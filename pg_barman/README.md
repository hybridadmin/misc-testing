# Production-Ready All-In-One PostgreSQL 18 & Barman Stack

This repository provides a comprehensive, production-ready Docker Compose environment running **PostgreSQL 18** and **Barman** (Backup and Recovery Manager) inside a **single unified container**. It is configured entirely for **zero-data-loss** streaming backups and WAL archiving.

## Architecture

*   **All-In-One Container**: Combines PostgreSQL 18 with Barman and Cron in a single image. This drastically simplifies deployment by avoiding complex multi-container networking for local backups.
*   **PostgreSQL Configuration**: Runs the core database with explicit settings for replication, streaming WAL, and a dedicated `barman` replication role with explicit backup execution privileges.
    *   **PostgreSQL 18+ Compatibility**: The data volume mounts directly to `/var/lib/postgresql` rather than the old `data` subdirectory. This allows major-version upgrade tools (`pg_upgrade`) to work seamlessly using hard links across volume boundaries.
*   **Storage**: Three separate Docker volumes ensure persistence of data, backups, and logs:
    *   `pg_data`: Primary database files.
    *   `barman_data`: Contains full base backups and streamed WALs.
    *   `barman_logs`: Keeps track of Barman executions and crons.

## Best Practices Implemented

1.  **Least Privilege Authentication**: The `barman` user has only `REPLICATION`, `pg_read_all_settings`, `pg_read_all_stats`, and `pg_read_all_data` roles rather than full superuser permissions.
2.  **Pure Streaming Architecture**: `barman.conf` is configured explicitly for a modern streaming architecture on `localhost`. `archiver = off` disables file-based WAL pushing, and `streaming_archiver = on` completely relies on Barman pulling the stream.
3.  **Near-Zero RPO**: `pg_receivewal` runs continuously as a background daemon inside the container to stream WAL files to the backup directory the moment they are generated using a dedicated physical replication slot (`barman_slot`).
4.  **Automated Scheduling**: Cron is configured to trigger full `basebackups` automatically on a specified schedule (default: 2 AM daily).
5.  **Retention Policies**: A `RECOVERY WINDOW OF 4 WEEKS` is configured to ensure adequate historical backup retention while purging obsolete WALs based on `main` policy constraints.
6.  **Automated Initial Backup**: The container wrapper script automatically triggers a synchronous base backup 15 seconds after booting on a fresh install to immediately satisfy minimum redundancy configurations.
7.  **Container Logs**: The custom entrypoint continuously tails `/var/log/barman/barman.log` directly into the container's standard output, multiplexed seamlessly with PostgreSQL logs.

## Getting Started

### 1. Build and Start the Environment

```bash
docker-compose build
docker-compose up -d
```

### 2. Verify Health

Check if the container is running perfectly:
```bash
docker-compose ps
```

The container automatically takes its first full backup approximately 15 seconds after booting up if no prior backups exist. This ensures you satisfy minimum redundancy configurations immediately.

Verify Barman connections and configurations natively inside the container:
```bash
docker-compose exec postgres gosu postgres barman check pg
```

### 3. Viewing Logs

Watch real-time WAL streaming, PostgreSQL logs, the initial automated backup process, and scheduled cron jobs all streaming directly from the container:

```bash
docker-compose logs -f postgres
```

To list available backups at any time:

```bash
docker-compose exec postgres gosu postgres barman list-backup pg
```

### 4. Database Access

You can access the PostgreSQL database directly via the `psql` interactive terminal inside the container:

```bash
# Connect as the admin user to the production database
docker-compose exec postgres psql -U admin -d proddb
```

Alternatively, you can connect from your local host machine using any standard PostgreSQL client (e.g., pgAdmin, DBeaver, or local `psql`) since port `5432` is exposed:

```bash
psql -h localhost -p 5432 -U admin -d proddb
```

### 5. Customizing Variables

In `docker-compose.yml`, you can customize:
*   `POSTGRES_USER` / `POSTGRES_PASSWORD`
*   `BARMAN_PASSWORD`
*   `BACKUP_SCHEDULE` (Cron format, default: `"0 2 * * *"`)

## Recovery Scenarios

To recover your database, you can use the `barman recover` command. Since this runs inside Docker, the general strategy is to stop the target PostgreSQL instance, perform a remote recovery or local recovery to a staging directory, and mount that directly as `pg_data`.

Example for recovering to a specific timestamp into a staging directory:
```bash
docker-compose exec postgres gosu postgres barman recover --target-time "2026-10-14 15:00:00" pg latest /var/lib/barman/recovery_dest
```
(Be sure to read the official Barman documentation for advanced point-in-time recovery).