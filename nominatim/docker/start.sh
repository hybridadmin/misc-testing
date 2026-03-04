#!/bin/bash -ex
#
# Custom start script for Nominatim with an EXTERNAL PostgreSQL database.
# This replaces the default /app/start.sh to skip the internal PostgreSQL
# management that the stock image assumes.
#

tailpid=0
replicationpid=0
GUNICORN_PID_FILE=/tmp/gunicorn.pid
export PYTHONUNBUFFERED=1

stopServices() {
  if [ $replicationpid -ne 0 ]; then
    echo "Shutting down replication process"
    kill $replicationpid 2>/dev/null || true
  fi
  [ $tailpid -ne 0 ] && kill $tailpid 2>/dev/null || true
  [ -f $GUNICORN_PID_FILE ] && cat $GUNICORN_PID_FILE | xargs kill 2>/dev/null || true
  exit 0
}
trap stopServices SIGTERM TERM INT

# ---------- Nominatim config ----------
/app/config.sh

# ---------- Create nominatim user inside the container ----------
if id nominatim >/dev/null 2>&1; then
  echo "user nominatim already exists"
else
  useradd -m -p "${NOMINATIM_PASSWORD}" nominatim
fi

# ---------- Import marker ----------
# Use a local file as the marker (not inside PG data dir since we use external DB)
IMPORT_FINISHED=/nominatim/import-finished

if [ ! -f "${IMPORT_FINISHED}" ]; then
  echo "==> Starting initial import against external database..."

  OSMFILE=${PROJECT_DIR}/data.osm.pbf
  CURL=("curl" "-L" "-A" "${USER_AGENT}" "--fail-with-body")

  # Check if THREADS is set
  if [ -z "$THREADS" ]; then
    THREADS=$(nproc)
  fi

  # ---------- Download optional data ----------
  SCP='sshpass -p DMg5bmLPY7npHL2Q scp -o StrictHostKeyChecking=no u355874-sub1@u355874-sub1.your-storagebox.de'

  if [ "$IMPORT_WIKIPEDIA" = "true" ]; then
    echo "Downloading Wikipedia importance dump"
    ${SCP}:wikimedia-importance.csv.gz ${PROJECT_DIR}/wikimedia-importance.csv.gz
  elif [ -f "$IMPORT_WIKIPEDIA" ]; then
    ln -sf "$IMPORT_WIKIPEDIA" ${PROJECT_DIR}/wikimedia-importance.csv.gz
  else
    echo "Skipping optional Wikipedia importance import"
  fi

  if [ "$IMPORT_SECONDARY_WIKIPEDIA" = "true" ]; then
    echo "Downloading Wikipedia secondary importance dump"
    ${SCP}:wikimedia-secondary-importance.sql.gz ${PROJECT_DIR}/secondary_importance.sql.gz
  elif [ -f "$IMPORT_SECONDARY_WIKIPEDIA" ]; then
    ln -sf "$IMPORT_SECONDARY_WIKIPEDIA" ${PROJECT_DIR}/secondary_importance.sql.gz
  else
    echo "Skipping optional Wikipedia secondary importance import"
  fi

  if [ "$IMPORT_GB_POSTCODES" = "true" ]; then
    ${SCP}:gb_postcodes.csv.gz ${PROJECT_DIR}/gb_postcodes.csv.gz
  elif [ -f "$IMPORT_GB_POSTCODES" ]; then
    ln -sf "$IMPORT_GB_POSTCODES" ${PROJECT_DIR}/gb_postcodes.csv.gz
  else
    echo "Skipping optional GB postcode import"
  fi

  if [ "$IMPORT_US_POSTCODES" = "true" ]; then
    ${SCP}:us_postcodes.csv.gz ${PROJECT_DIR}/us_postcodes.csv.gz
  elif [ -f "$IMPORT_US_POSTCODES" ]; then
    ln -sf "$IMPORT_US_POSTCODES" ${PROJECT_DIR}/us_postcodes.csv.gz
  else
    echo "Skipping optional US postcode import"
  fi

  if [ "$IMPORT_TIGER_ADDRESSES" = "true" ]; then
    ${SCP}:tiger2024-nominatim-preprocessed.csv.tar.gz ${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz
  elif [ -f "$IMPORT_TIGER_ADDRESSES" ]; then
    ln -sf "$IMPORT_TIGER_ADDRESSES" ${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz
  else
    echo "Skipping optional Tiger addresses import"
  fi

  # ---------- Download PBF ----------
  if [ "$PBF_URL" != "" ]; then
    echo "Downloading OSM extract from $PBF_URL"
    "${CURL[@]}" "$PBF_URL" -C - --create-dirs -o "$OSMFILE"
  fi

  if [ "$PBF_PATH" != "" ]; then
    echo "Reading OSM extract from $PBF_PATH"
    OSMFILE=$PBF_PATH
  fi

  # ---------- Ensure roles exist on external DB ----------
  # Use PGPASSWORD + psql to connect to the external database
  export PGHOST="${EXTERNAL_PG_HOST:-postgres}"
  export PGPORT="${EXTERNAL_PG_PORT:-5432}"
  export PGUSER="${POSTGRES_USER:-nominatim}"
  export PGPASSWORD="${POSTGRES_PASSWORD:-${NOMINATIM_PASSWORD}}"

  echo "Waiting for external PostgreSQL at ${PGHOST}:${PGPORT}..."
  for i in $(seq 1 30); do
    if pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" >/dev/null 2>&1; then
      echo "External PostgreSQL is ready."
      break
    fi
    echo "  ...not ready yet, retrying ($i/30)"
    sleep 2
  done

  # Ensure www-data role exists
  psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='www-data'" | grep -q 1 \
    || psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -c \
    "CREATE ROLE \"www-data\" LOGIN PASSWORD '${PGPASSWORD}'"

  # Drop nominatim DB if it exists (clean import)
  psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -c \
    "DROP DATABASE IF EXISTS nominatim"

  # ---------- Run import ----------
  chown -R nominatim:nominatim ${PROJECT_DIR}
  cd ${PROJECT_DIR}

  if [ "$REVERSE_ONLY" = "true" ]; then
    sudo -E -u nominatim nominatim import --osm-file "$OSMFILE" --threads "$THREADS" --reverse-only
  else
    sudo -E -u nominatim nominatim import --osm-file "$OSMFILE" --threads "$THREADS"
  fi

  # Tiger addresses
  if [ -f "${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz" ]; then
    echo "Importing Tiger address data"
    sudo -E -u nominatim nominatim add-data --tiger-data tiger-nominatim-preprocessed.csv.tar.gz
  fi

  # Additional indexing pass
  sudo -E -u nominatim nominatim index --threads "$THREADS"
  sudo -E -u nominatim nominatim admin --check-database

  # Replication init
  if [ "$REPLICATION_URL" != "" ]; then
    sudo -E -u nominatim nominatim replication --init
    if [ "$FREEZE" = "true" ]; then
      echo "Skipping freeze because REPLICATION_URL is not empty"
    fi
  else
    if [ "$FREEZE" = "true" ]; then
      echo "Freezing database"
      sudo -E -u nominatim nominatim freeze
    fi
  fi

  # Warm up
  export NOMINATIM_QUERY_TIMEOUT=600
  export NOMINATIM_REQUEST_TIMEOUT=3600
  if [ "$REVERSE_ONLY" = "true" ]; then
    sudo -H -E -u nominatim nominatim admin --warm --reverse
  else
    sudo -H -E -u nominatim nominatim admin --warm
  fi
  export NOMINATIM_QUERY_TIMEOUT=10
  export NOMINATIM_REQUEST_TIMEOUT=60

  # Analyze for query planner
  sudo -E -u nominatim psql -d nominatim -c "ANALYZE VERBOSE"

  # Cleanup
  echo "Deleting downloaded dumps in ${PROJECT_DIR}"
  rm -f ${PROJECT_DIR}/*sql.gz
  rm -f ${PROJECT_DIR}/*csv.gz
  rm -f ${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz
  if [ "$PBF_URL" != "" ]; then
    rm -f "$OSMFILE"
  fi

  touch "${IMPORT_FINISHED}"
  echo "==> Import complete."
else
  echo "==> Import already completed, skipping."
  chown -R nominatim:nominatim ${PROJECT_DIR}
fi

# ---------- Refresh website / functions ----------
cd ${PROJECT_DIR}
sudo -E -u nominatim nominatim refresh --website --functions

# ---------- Replication ----------
if [ "$REPLICATION_URL" != "" ] && [ "$FREEZE" != "true" ]; then
  sudo -E -u nominatim nominatim replication --project-dir ${PROJECT_DIR} --init
  if [ "$UPDATE_MODE" = "continuous" ]; then
    echo "Starting continuous replication"
    sudo -E -u nominatim nominatim replication --project-dir ${PROJECT_DIR} &> /var/log/replication.log &
    replicationpid=${!}
  elif [ "$UPDATE_MODE" = "once" ]; then
    echo "Starting replication once"
    sudo -E -u nominatim nominatim replication --project-dir ${PROJECT_DIR} --once &> /var/log/replication.log &
    replicationpid=${!}
  elif [ "$UPDATE_MODE" = "catch-up" ]; then
    echo "Starting replication catch-up"
    sudo -E -u nominatim nominatim replication --project-dir ${PROJECT_DIR} --catch-up &> /var/log/replication.log &
    replicationpid=${!}
  else
    echo "Skipping replication"
  fi
fi

# ---------- Warm up (if requested on every startup) ----------
if [ "$WARMUP_ON_STARTUP" = "true" ]; then
  export NOMINATIM_QUERY_TIMEOUT=600
  export NOMINATIM_REQUEST_TIMEOUT=3600
  if [ "$REVERSE_ONLY" = "true" ]; then
    echo "Warming database caches for reverse queries"
    sudo -H -E -u nominatim nominatim admin --warm --reverse > /dev/null
  else
    echo "Warming database caches for search and reverse queries"
    sudo -H -E -u nominatim nominatim admin --warm > /dev/null
  fi
  export NOMINATIM_QUERY_TIMEOUT=10
  export NOMINATIM_REQUEST_TIMEOUT=60
  echo "Warming finished"
else
  echo "Skipping cache warmup"
fi

# ---------- Start Gunicorn ----------
if [ -z "$GUNICORN_WORKERS" ]; then
  GUNICORN_WORKERS=$(nproc)
fi

echo "Starting Gunicorn with $GUNICORN_WORKERS workers"
echo "--> Nominatim is ready to accept requests"

cd "$PROJECT_DIR"
sudo -E -u nominatim gunicorn \
  --bind :8080 \
  --pid $GUNICORN_PID_FILE \
  --workers $GUNICORN_WORKERS \
  --daemon \
  --enable-stdio-inheritance \
  --worker-class uvicorn.workers.UvicornWorker \
  nominatim_api.server.falcon.server:run_wsgi

# Keep container alive
tail -f /dev/null &
tailpid=${!}
wait
