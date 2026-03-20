FROM postgres:18
LABEL maintainer="turboapi"

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-18-pglogical \
    && rm -rf /var/lib/apt/lists/*

COPY init.sql /docker-entrypoint-initdb.d/01-init.sql
COPY setup_replication.sh /usr/local/bin/setup_replication.sh

RUN chmod 755 /usr/local/bin/setup_replication.sh

USER postgres

EXPOSE 5432
