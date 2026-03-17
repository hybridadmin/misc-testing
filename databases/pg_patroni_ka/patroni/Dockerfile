FROM postgres:18

# Install Patroni + pgBackRest + keepalived + dependencies
# keepalived + iproute2: required for floating VIP management
# pgBackRest >= 2.55 required for PG18 -- install from PGDG apt repo
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    gcc \
    libffi-dev \
    curl \
    jq \
    ca-certificates \
    gnupg \
    lsb-release \
    keepalived \
    iproute2 \
    && sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list' \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/pgdg.gpg \
    && apt-get update \
    && apt-get install -y --no-install-recommends pgbackrest \
    && python3 -m venv /opt/patroni \
    && /opt/patroni/bin/pip install --no-cache-dir \
        patroni[etcd3]==4.0.4 \
        psycopg[binary]==3.2.4 \
    && apt-get purge -y gcc python3-dev libffi-dev \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Add Patroni to PATH
ENV PATH="/opt/patroni/bin:${PATH}"

# Create directories (Patroni + pgBackRest + keepalived)
RUN mkdir -p /etc/patroni /var/lib/postgresql /run/postgresql \
    /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest /etc/pgbackrest \
    /etc/keepalived \
    && chown -R postgres:postgres /var/lib/postgresql /run/postgresql /etc/patroni \
    /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest /etc/pgbackrest

# Copy configuration and scripts
COPY pgbackrest/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY keepalived/keepalived.conf.tmpl /etc/keepalived/keepalived.conf.tmpl
COPY scripts/patroni-entrypoint.sh /usr/local/bin/patroni-entrypoint.sh
COPY scripts/patroni-healthcheck.sh /usr/local/bin/patroni-healthcheck.sh
COPY scripts/post-bootstrap.sh /usr/local/bin/post-bootstrap.sh
COPY scripts/keepalived-check.sh /usr/local/bin/keepalived-check.sh

RUN chmod +x /usr/local/bin/patroni-entrypoint.sh \
    /usr/local/bin/patroni-healthcheck.sh \
    /usr/local/bin/post-bootstrap.sh \
    /usr/local/bin/keepalived-check.sh

EXPOSE 5432 8008

# NOTE: We do NOT switch to USER postgres here because keepalived
# needs root to manage VIPs on eth0. The entrypoint starts keepalived
# as root, then exec's patroni which drops to postgres internally.

ENTRYPOINT ["/usr/local/bin/patroni-entrypoint.sh"]
