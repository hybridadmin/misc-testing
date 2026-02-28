FROM nginx:1.29.5 AS builder

# Install build dependencies for both Brotli and OTel modules
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    gcc \
    g++ \
    make \
    cmake \
    libpcre2-dev \
    zlib1g-dev \
    libbrotli-dev \
    libssl-dev \
    libc-ares-dev \
    libre2-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Download matching Nginx source
RUN NGINX_VERSION=$(nginx -v 2>&1 | sed 's/.*nginx\///' ) && \
    curl -fsSL https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz | tar xz -C /tmp

# Configure Nginx source (generates objs/ needed by both modules)
RUN NGINX_VERSION=$(nginx -v 2>&1 | sed 's/.*nginx\///') && \
    cd /tmp/nginx-${NGINX_VERSION} && \
    ./configure --with-compat

# --- Build Brotli module ---
RUN git clone --depth=1 --recurse-submodules https://github.com/google/ngx_brotli.git /tmp/ngx_brotli

RUN NGINX_VERSION=$(nginx -v 2>&1 | sed 's/.*nginx\///') && \
    cd /tmp/nginx-${NGINX_VERSION} && \
    ./configure --with-compat --add-dynamic-module=/tmp/ngx_brotli && \
    make modules && \
    cp objs/ngx_http_brotli_filter_module.so /tmp/ && \
    cp objs/ngx_http_brotli_static_module.so /tmp/

# --- Build OTel module ---
RUN git clone --depth=1 https://github.com/nginxinc/nginx-otel.git /tmp/nginx-otel

RUN NGINX_VERSION=$(nginx -v 2>&1 | sed 's/.*nginx\///') && \
    mkdir /tmp/nginx-otel/build && \
    cd /tmp/nginx-otel/build && \
    cmake \
        -DNGX_OTEL_NGINX_BUILD_DIR=/tmp/nginx-${NGINX_VERSION}/objs \
        .. && \
    make -j$(nproc) && \
    cp ngx_otel_module.so /tmp/

# --- Final image ---
FROM nginx:1.29.5

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libbrotli1 \
    libc-ares2 \
    libre2-11 \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled modules from builder
COPY --from=builder /tmp/ngx_http_brotli_filter_module.so /usr/lib/nginx/modules/
COPY --from=builder /tmp/ngx_http_brotli_static_module.so /usr/lib/nginx/modules/
COPY --from=builder /tmp/ngx_otel_module.so /usr/lib/nginx/modules/

# Remove default config
RUN rm /etc/nginx/conf.d/default.conf

# Copy custom high-performance configuration
COPY config/nginx.conf /etc/nginx/nginx.conf

# Validate the configuration at build time
RUN nginx -t

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
