FROM postgres:18

# Install pglogical extension + keepalived + utilities + pgBackRest (>= 2.55 for PG18)
# No socat needed — keepalived replaces HAProxy agent-check
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-18-pglogical \
    keepalived \
    iproute2 \
    curl \
    jq \
    ca-certificates \
    gnupg \
    lsb-release \
    && sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list' \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/pgdg.gpg \
    && apt-get update \
    && apt-get install -y --no-install-recommends pgbackrest \
    && rm -rf /var/lib/apt/lists/*

# Create pgBackRest directories with correct ownership
RUN mkdir -p /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest /etc/pgbackrest \
    && chown -R postgres:postgres /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest /etc/pgbackrest

# Custom entrypoint that starts PG, keepalived, and watchdog
COPY scripts/pg-entrypoint.sh /usr/local/bin/pg-entrypoint.sh
COPY scripts/setup-replication.sh /usr/local/bin/setup-replication.sh
COPY scripts/pg-healthcheck.sh /usr/local/bin/pg-healthcheck.sh
COPY scripts/keepalived-check.sh /usr/local/bin/keepalived-check.sh
RUN chmod +x /usr/local/bin/pg-entrypoint.sh \
    /usr/local/bin/setup-replication.sh \
    /usr/local/bin/pg-healthcheck.sh \
    /usr/local/bin/keepalived-check.sh

# Ensure postgres user owns config directory
RUN mkdir -p /etc/postgresql && chown -R postgres:postgres /etc/postgresql

# keepalived config directory
RUN mkdir -p /etc/keepalived

EXPOSE 5432

ENTRYPOINT ["pg-entrypoint.sh"]
CMD ["postgres"]
