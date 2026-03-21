FROM postgres:18
LABEL maintainer="turboapi"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-18-pglogical \
        pgbackrest \
        lz4 \
        gosu \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest /etc/pgbackrest \
    && chown -R postgres:postgres /var/lib/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest /etc/pgbackrest

COPY init.sql /docker-entrypoint-initdb.d/01-init.sql
COPY setup_replication.sh /usr/local/bin/setup_replication.sh
COPY pg-entrypoint.sh /usr/local/bin/pg-entrypoint.sh

RUN chmod 755 /usr/local/bin/setup_replication.sh /usr/local/bin/pg-entrypoint.sh

EXPOSE 5432

ENTRYPOINT ["/usr/local/bin/pg-entrypoint.sh"]
CMD ["postgres"]
