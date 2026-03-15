###############################################################################
# Stage 1: Build PostgreSQL 18 (patched for Spock) + Spock extension
###############################################################################
FROM debian:bookworm-slim AS builder

ARG PG_VERSION=18.3
ARG PG_TAG=REL_18_3
ARG SPOCK_VERSION=v5.0.6

ENV DEBIAN_FRONTEND=noninteractive

# Build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    bison \
    flex \
    git \
    ca-certificates \
    curl \
    libreadline-dev \
    zlib1g-dev \
    libssl-dev \
    libxml2-dev \
    libxslt1-dev \
    liblz4-dev \
    libzstd-dev \
    libicu-dev \
    libjansson-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# ---------- PostgreSQL source ----------
RUN git clone --depth 1 --branch ${PG_TAG} https://github.com/postgres/postgres.git pg-src

# ---------- Spock source ----------
RUN git clone --depth 1 --branch ${SPOCK_VERSION} https://github.com/pgEdge/spock.git spock-src

# ---------- Apply Spock patches to PostgreSQL ----------
WORKDIR /build/pg-src
RUN for patch in /build/spock-src/patches/18/*.diff; do \
      echo "Applying patch: $patch"; \
      git apply --verbose "$patch" || { echo "WARN: patch $patch failed, trying with 3way"; git apply --3way "$patch" || true; }; \
    done

# ---------- Build PostgreSQL ----------
RUN ./configure \
      --prefix=/usr/local/pgsql \
      --with-openssl \
      --with-libxml \
      --with-libxslt \
      --with-lz4 \
      --with-zstd \
      --with-icu \
    && make -j$(nproc) world-bin \
    && make install-world-bin

# ---------- Build Spock extension ----------
WORKDIR /build/spock-src
ENV PATH="/usr/local/pgsql/bin:${PATH}"
RUN make -j$(nproc) && make install

###############################################################################
# Stage 2: Runtime image
###############################################################################
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/local/pgsql/bin:${PATH}"
ENV PGDATA=/var/lib/postgresql/data
ENV POSTGRES_USER=postgres
ENV POSTGRES_PASSWORD=postgres
ENV POSTGRES_DB=spockdb

# Runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libreadline8 \
    zlib1g \
    libssl3 \
    libxml2 \
    libxslt1.1 \
    liblz4-1 \
    libzstd1 \
    libicu72 \
    locales \
    gosu \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

ENV LANG=en_US.UTF-8

# Copy PostgreSQL + Spock from builder
COPY --from=builder /usr/local/pgsql /usr/local/pgsql

# Create postgres user
RUN groupadd -r postgres && useradd -r -g postgres -d /var/lib/postgresql -s /bin/bash postgres \
    && mkdir -p /var/lib/postgresql/data /var/run/postgresql /docker-entrypoint-initdb.d \
    && chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql

# Copy entrypoint and scripts
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 5432

ENTRYPOINT ["entrypoint.sh"]
CMD ["postgres"]
