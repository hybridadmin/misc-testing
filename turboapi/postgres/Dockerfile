FROM postgres:18.3

USER root

RUN apt-get update && apt-get install -y \
    postgresql-18-pglogical \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /usr/local/bin \
    && chmod 755 /usr/local/bin

COPY setup_replication.sh /usr/local/bin/setup_replication.sh
COPY create_replication_slot.sh /usr/local/bin/create_replication_slot.sh
COPY pg_hba.conf /etc/postgresql/pg_hba.conf
COPY init.sql /docker-entrypoint-initdb.d/01-pglogical.sql

RUN chmod 755 /usr/local/bin/*.sh

USER postgres

EXPOSE 5432

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres"]
