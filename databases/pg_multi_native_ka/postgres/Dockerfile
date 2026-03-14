FROM postgres:18

# Install keepalived + utilities for health checks and setup scripts
# No pglogical — uses native PG18 logical replication
# No socat — keepalived replaces HAProxy agent-check
RUN apt-get update && apt-get install -y --no-install-recommends \
    keepalived \
    iproute2 \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Custom entrypoint that starts PG, keepalived, and native replication setup
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
