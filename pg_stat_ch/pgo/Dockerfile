FROM registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi9-18.1-2550

ARG TARGETARCH
ARG PG_STAT_CH_VERSION=v0.3.1
ARG PG_MAJOR=18

# Switch to root to install packages and compile
USER root

# Map Docker TARGETARCH (amd64/arm64) to release tarball names
# Release assets use: pg18-linux-amd64 / pg18-linux-arm64
RUN set -eux; \
    apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        libssl3 \
    && rm -rf /var/lib/apt/lists/*; \
    \
    TARBALL="pg_stat_ch-${PG_STAT_CH_VERSION}-pg${PG_MAJOR}-linux-${TARGETARCH}.tar.gz"; \
    URL="https://github.com/ClickHouse/pg_stat_ch/releases/download/${PG_STAT_CH_VERSION}/${TARBALL}"; \
    \
    echo "Downloading ${URL}"; \
    curl -fSL -o /tmp/pg_stat_ch.tar.gz "${URL}"; \
    \
    # Extract and install following the official instructions:
    #   https://github.com/ClickHouse/pg_stat_ch/releases/tag/v0.3.1
    cd /tmp; \
    tar -xzf pg_stat_ch.tar.gz; \
    cd pg_stat_ch-*/; \
    cp pg_stat_ch.so "$(pg_config --pkglibdir)/"; \
    cp pg_stat_ch.control pg_stat_ch--*.sql "$(pg_config --sharedir)/extension/"; \
    \
    # Clean up
    rm -rf /tmp/pg_stat_ch.tar.gz /tmp/pg_stat_ch-*/

EXPOSE 5432

# Switch back to the postgres user (Crunchy uses UID 26)
USER 26
