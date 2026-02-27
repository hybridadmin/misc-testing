# RustFS + PostgreSQL 18 with pgbackrest WAL Archiving

A Docker Compose setup running [RustFS](https://rustfs.com) (S3-compatible object storage) with TLS, and PostgreSQL 18 with [pgbackrest](https://pgbackrest.org) continuous WAL archiving to an S3 bucket hosted in RustFS.

## Architecture

```
+-----------+       HTTPS (port 9000)       +------------------+
|           | <---------------------------  |                  |
|  RustFS   |   WAL archive-push (S3 API)   |  PostgreSQL 18   |
|  (S3/TLS) | <---------------------------  |  + pgbackrest    |
|           |                               |                  |
+-----------+                               +------------------+
   ^
   |  bucket creation (rc CLI)
   |
+------------------+
|  create-buckets  |
|  (init container)|
+------------------+
```

**Services:**

| Service | Description | Ports |
|---|---|---|
| `rustfs` | S3-compatible object storage with TLS | `9000` (S3 API), `9001` (console) |
| `create-buckets` | Init container that creates the `pg-bucket` S3 bucket | (exits after completion) |
| `postgres` | PostgreSQL 18.2 with pgbackrest for WAL archiving to RustFS | `5432` |

## Prerequisites

- Docker and Docker Compose
- [mkcert](https://github.com/FiloSottile/mkcert) for generating TLS certificates

## Directory Structure

```
.
├── README.md
├── docker-compose.yml
├── cacert/
│   └── rootCA.pem            # mkcert root CA certificate
├── certs/
│   ├── rustfs_cert.pem       # TLS server certificate
│   └── rustfs_key.pem        # TLS server private key
└── pgbackrest/
    └── conf/
        └── pgbackrest.conf   # pgbackrest configuration
```

## TLS Certificate Setup

RustFS requires TLS certificates. Generate them using mkcert:

```bash
# Install the local CA (if not already done)
mkcert -install

# Create the certs directory
mkdir -p certs cacert

# Generate the server certificate with SANs matching the Docker service name
mkcert -cert-file certs/rustfs_cert.pem \
       -key-file certs/rustfs_key.pem \
       rustfs minio localhost 127.0.0.1 ::1

# Copy the root CA so containers can verify the server certificate
cp "$(mkcert -CAROOT)/rootCA.pem" cacert/rootCA.pem
```

The certificate SANs must include `rustfs` since that is the Docker service hostname that other containers use to reach the S3 API. RustFS expects the cert and key filenames to contain `cert` and `key` respectively.

## Configuration

### RustFS Credentials

Default credentials (override via environment variables):

| Variable | Default |
|---|---|
| `RUSTFS_ROOT_USER` | `rustfsadmin` |
| `RUSTFS_ROOT_PASSWORD` | `rustfsadmin` |

### PostgreSQL

| Variable | Default |
|---|---|
| `POSTGRES_USER` | `postgres` |
| `POSTGRES_PASSWORD` | `postgres` |
| `POSTGRES_DB` | `postgres` |

PostgreSQL 18 uses `/var/lib/postgresql/18/docker` as its `PGDATA` directory in the official Docker image.

### pgbackrest

Configuration is in `pgbackrest/conf/pgbackrest.conf`. Key settings:

| Setting | Value | Description |
|---|---|---|
| `repo1-type` | `s3` | S3-compatible storage backend |
| `repo1-s3-bucket` | `pg-bucket` | Bucket name in RustFS |
| `repo1-s3-endpoint` | `rustfs` | Docker service hostname |
| `repo1-storage-port` | `9000` | S3 API port (not console port 9001) |
| `repo1-s3-uri-style` | `path` | Path-style S3 URLs (required for RustFS) |
| `repo1-storage-verify-tls` | `y` | Verify TLS certificates |
| `repo1-storage-ca-file` | `/opt/cacert/rootCA.pem` | mkcert root CA for TLS verification |
| `archive-async` | `y` | Async WAL archiving for better throughput |
| `compress-type` | `bz2` | Compression algorithm |
| `repo1-bundle` | `y` | Bundle small files to reduce S3 object count |
| `repo1-block` | `y` | Block-level incremental backups |

PostgreSQL is started with:
- `archive_mode=on`
- `archive_command=pgbackrest --stanza=default archive-push %p`
- `wal_level=replica`

## Usage

### Start the Stack

```bash
docker compose up -d --build
```

On first start, the sequence is:

1. **rustfs** starts and waits for healthy status
2. **create-buckets** creates the `pg-bucket` S3 bucket, then exits
3. **postgres** builds its image (installs pgbackrest from apt), starts PostgreSQL, and automatically runs `pgbackrest stanza-create` in the background once PG is ready

### Clean Start (reset all data)

```bash
docker compose down -v && docker compose up -d --build
```

### Verify WAL Archiving

Check that the stanza was created and archiving is working:

```bash
# Check postgres logs for stanza creation
docker compose logs postgres | grep pgbackrest-init

# Check pgbackrest info
docker exec postgres pgbackrest --stanza=default info

# Check postgres archiving status
docker exec postgres psql -U postgres -c "SELECT * FROM pg_stat_archiver;"
```

### Manual Backup

```bash
# Full backup
docker exec postgres pgbackrest --stanza=default --type=full backup

# Differential backup
docker exec postgres pgbackrest --stanza=default --type=diff backup
```

### Access RustFS Console

The RustFS web console is available at `https://localhost:9001` (login with the credentials above). Since the certificate is signed by mkcert's local CA, your browser should trust it if you've run `mkcert -install`.

## Startup Order

The services have explicit dependency ordering:

```
rustfs (healthy) -> create-buckets (completed) -> postgres
```

The postgres container uses a wrapper entrypoint that:
1. Spawns a background process waiting for PostgreSQL to accept connections
2. Execs into the standard `docker-entrypoint.sh` (PostgreSQL runs as PID 1)
3. Once PG is ready, the background process runs `pgbackrest stanza-create`
4. WAL archiving begins automatically after the stanza is created

## Troubleshooting

### Port 9001 vs 9000

RustFS exposes two ports:
- **9000**: S3 API (this is what pgbackrest and the `rc` CLI connect to)
- **9001**: Web console

pgbackrest must use port `9000`. Using `9001` will result in connection failures (exit code 46).

### TLS Certificate Errors

If pgbackrest or the `rc` CLI can't verify the RustFS certificate:
- Ensure `cacert/rootCA.pem` is the root CA that signed the server certificate
- Ensure the certificate has a SAN for `rustfs` (the Docker service hostname)
- For the `rc` CLI, set `SSL_CERT_FILE=/opt/cacert/rootCA.pem` (the `--insecure` flag in alias config is not applied to subsequent commands like `rc mb`)

### Stale Containers

If RustFS reports HTTP instead of HTTPS after config changes, or pgbackrest uses old settings:
```bash
docker compose down -v && docker compose up -d --build
```

### pgbackrest Version Compatibility

The `postgres:18.2` image is based on Debian Trixie. The pgbackrest package from the Debian repository must support PostgreSQL 18. If it doesn't (error: `unexpected control version`), pgbackrest needs to be built from source from the `main` branch.
