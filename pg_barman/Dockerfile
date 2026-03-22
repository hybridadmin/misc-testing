FROM postgres:18

# Install barman, cron, and curl
RUN apt-get update && \
    apt-get install -y --no-install-recommends barman cron curl gosu jq && \
    rm -rf /var/lib/apt/lists/*

# Create necessary directories
RUN mkdir -p /etc/barman.d /var/lib/barman /var/log/barman && \
    chown -R postgres:postgres /etc/barman.d /var/lib/barman /var/log/barman

COPY config/barman.conf /etc/barman.conf
COPY config/pg.conf /etc/barman.d/pg.conf
COPY custom-entrypoint.sh /usr/local/bin/custom-entrypoint.sh
COPY barman-launcher.sh /usr/local/bin/barman-launcher.sh

RUN chmod +x /usr/local/bin/custom-entrypoint.sh /usr/local/bin/barman-launcher.sh

ENTRYPOINT ["custom-entrypoint.sh"]
