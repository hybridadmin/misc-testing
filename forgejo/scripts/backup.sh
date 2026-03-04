#!/bin/sh
# =============================================================================
# PostgreSQL Backup Script
# =============================================================================
# Creates compressed backups and removes old ones beyond retention period.
# Designed to run inside the backup container via cron.
# =============================================================================

set -e

BACKUP_DIR="/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/forgejo_${TIMESTAMP}.sql.gz"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

echo "[$(date -Iseconds)] Starting PostgreSQL backup..."

# Wait for PostgreSQL to be ready
until pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -q; do
    echo "[$(date -Iseconds)] Waiting for PostgreSQL..."
    sleep 5
done

# Create backup directory if it doesn't exist
mkdir -p "${BACKUP_DIR}"

# Perform the backup with custom format for efficient compression
pg_dump \
    -h "$PGHOST" \
    -p "$PGPORT" \
    -U "$PGUSER" \
    -d "$PGDATABASE" \
    --no-owner \
    --no-privileges \
    --verbose \
    2>/dev/null | gzip -9 > "${BACKUP_FILE}"

# Verify backup is not empty
BACKUP_SIZE=$(stat -c%s "${BACKUP_FILE}" 2>/dev/null || stat -f%z "${BACKUP_FILE}" 2>/dev/null || echo "0")
if [ "${BACKUP_SIZE}" -lt 100 ]; then
    echo "[$(date -Iseconds)] ERROR: Backup file is suspiciously small (${BACKUP_SIZE} bytes). Possible failure."
    rm -f "${BACKUP_FILE}"
    exit 1
fi

echo "[$(date -Iseconds)] Backup created: ${BACKUP_FILE} (${BACKUP_SIZE} bytes)"

# Remove backups older than retention period
DELETED=$(find "${BACKUP_DIR}" -name "forgejo_*.sql.gz" -type f -mtime "+${RETENTION_DAYS}" -print -delete | wc -l)
if [ "${DELETED}" -gt 0 ]; then
    echo "[$(date -Iseconds)] Cleaned up ${DELETED} backup(s) older than ${RETENTION_DAYS} days."
fi

# Show remaining backups
TOTAL=$(find "${BACKUP_DIR}" -name "forgejo_*.sql.gz" -type f | wc -l)
echo "[$(date -Iseconds)] Backup complete. Total backups retained: ${TOTAL}"
