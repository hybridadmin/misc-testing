FROM postgres:18

# Install Patroni + dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    gcc \
    libffi-dev \
    curl \
    jq \
    && python3 -m venv /opt/patroni \
    && /opt/patroni/bin/pip install --no-cache-dir \
        patroni[etcd3]==4.0.4 \
        psycopg[binary]==3.2.4 \
    && apt-get purge -y gcc python3-dev libffi-dev \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Add Patroni to PATH
ENV PATH="/opt/patroni/bin:${PATH}"

# Patroni config will be mounted
RUN mkdir -p /etc/patroni

# Health check script
COPY scripts/patroni-healthcheck.sh /usr/local/bin/patroni-healthcheck.sh
RUN chmod +x /usr/local/bin/patroni-healthcheck.sh

# Ensure postgres user owns the data directory and Patroni config dir
RUN mkdir -p /var/lib/postgresql && chown -R postgres:postgres /var/lib/postgresql /etc/patroni

EXPOSE 5432 8008

USER postgres

ENTRYPOINT ["patroni"]
CMD ["/etc/patroni/patroni.yml"]
