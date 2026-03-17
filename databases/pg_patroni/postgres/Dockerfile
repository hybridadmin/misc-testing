FROM postgres:18

# Install Patroni dependencies + pgBackRest
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-dev \
    python3-venv \
    gcc \
    libpq-dev \
    iproute2 \
    iputils-arping \
    iputils-ping \
    curl \
    jq \
    procps \
    pgbouncer \
    ca-certificates \
    gnupg \
    lsb-release \
    && sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list' \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/pgdg.gpg \
    && apt-get update \
    && apt-get install -y --no-install-recommends pgbackrest \
    && rm -rf /var/lib/apt/lists/*

# Install Patroni with etcd3 support into a venv
RUN python3 -m venv /opt/patroni && \
    /opt/patroni/bin/pip install --no-cache-dir \
    patroni[etcd3] \
    psycopg2-binary \
    && ln -s /opt/patroni/bin/patroni /usr/local/bin/patroni \
    && ln -s /opt/patroni/bin/patronictl /usr/local/bin/patronictl

# Create directories (Patroni + pgBackRest)
RUN mkdir -p /etc/patroni /var/lib/postgresql/data /run/postgresql \
    /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest /etc/pgbackrest \
    && chown -R postgres:postgres /var/lib/postgresql /run/postgresql /etc/patroni \
    /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest /etc/pgbackrest

# Copy configuration and scripts
COPY postgres/patroni.yml /etc/patroni/patroni.yml
COPY postgres/pg_hba.conf /etc/postgresql/pg_hba.conf
COPY pgbackrest/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
COPY scripts/patroni-entrypoint.sh /usr/local/bin/patroni-entrypoint.sh
COPY scripts/pg-healthcheck.sh /usr/local/bin/pg-healthcheck.sh
COPY scripts/post-bootstrap.sh /usr/local/bin/post-bootstrap.sh

RUN chmod +x /usr/local/bin/patroni-entrypoint.sh /usr/local/bin/pg-healthcheck.sh /usr/local/bin/post-bootstrap.sh

# Patroni REST API
EXPOSE 5432 8008

USER postgres

ENTRYPOINT ["/usr/local/bin/patroni-entrypoint.sh"]
