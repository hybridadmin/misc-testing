FROM postgres:18

# Install utilities for health checks and setup scripts
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    socat \
    && rm -rf /var/lib/apt/lists/*

# Custom entrypoint that starts PG and then configures logical replication
COPY scripts/pg-entrypoint.sh /usr/local/bin/pg-entrypoint.sh
COPY scripts/setup-replication.sh /usr/local/bin/setup-replication.sh
COPY scripts/pg-healthcheck.sh /usr/local/bin/pg-healthcheck.sh
COPY scripts/pg-repl-health-agent.sh /usr/local/bin/pg-repl-health-agent.sh
RUN chmod +x /usr/local/bin/pg-entrypoint.sh \
    /usr/local/bin/setup-replication.sh \
    /usr/local/bin/pg-healthcheck.sh \
    /usr/local/bin/pg-repl-health-agent.sh

# Ensure postgres user owns config directory
RUN mkdir -p /etc/postgresql && chown -R postgres:postgres /etc/postgresql

EXPOSE 5432 5480

# We use the stock postgres entrypoint but with our custom config
# The pg-entrypoint.sh wraps the default entrypoint, adding replication setup
ENTRYPOINT ["pg-entrypoint.sh"]
CMD ["postgres"]
