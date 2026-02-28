FROM nginx:1.29.5-trixie AS builder

# Install build dependencies for Brotli module
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    gcc \
    g++ \
    make \
    libpcre2-dev \
    zlib1g-dev \
    libbrotli-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Download matching Nginx source
RUN NGINX_VERSION=$(nginx -v 2>&1 | sed 's/.*nginx\///' ) && \
    curl -fsSL https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz | tar xz -C /tmp

# Configure Nginx source and build Brotli module
RUN git clone --depth=1 --recurse-submodules https://github.com/google/ngx_brotli.git /tmp/ngx_brotli

RUN NGINX_VERSION=$(nginx -v 2>&1 | sed 's/.*nginx\///') && \
    cd /tmp/nginx-${NGINX_VERSION} && \
    ./configure --with-compat --add-dynamic-module=/tmp/ngx_brotli && \
    make modules && \
    cp objs/ngx_http_brotli_filter_module.so /tmp/ && \
    cp objs/ngx_http_brotli_static_module.so /tmp/

# --- Final image ---
FROM nginx:1.29.5-trixie

# Install runtime dependencies for Brotli + Python 3.13 (ships with Trixie)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libbrotli1 \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Install uv (standalone binary — manages venv + deps)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Copy compiled Brotli modules from builder
COPY --from=builder /tmp/ngx_http_brotli_filter_module.so /usr/lib/nginx/modules/
COPY --from=builder /tmp/ngx_http_brotli_static_module.so /usr/lib/nginx/modules/

# Remove default config
RUN rm /etc/nginx/conf.d/default.conf

# Copy custom high-performance configuration
COPY config/nginx.conf /etc/nginx/nginx.conf

# Install Python dependencies with uv (uses system Python 3.13)
ENV UV_PROJECT_ENVIRONMENT="/opt/venv"
COPY pyproject.toml uv.lock /srv/
RUN uv sync --frozen --no-dev --no-install-project --directory /srv
ENV PATH="/opt/venv/bin:$PATH"

# Copy the FastAPI application
COPY app/ /srv/app/

WORKDIR /srv

# Copy and set entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Validate the nginx configuration at build time
RUN nginx -t

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
