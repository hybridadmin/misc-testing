###############################################################################
# Nginx 1.29 + Filebeat 8.17 — combined image
#
# Runs both processes via a simple bash entrypoint script.
# Nginx serves HTTP; Filebeat ships JSON access logs to Kafka.
###############################################################################
FROM nginx:1.29-trixie

ARG FILEBEAT_VERSION=8.17.0
ARG TARGETARCH

# Install Filebeat
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    curl -fsSL https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-${FILEBEAT_VERSION}-linux-${TARGETARCH}.tar.gz \
      | tar xz --strip-components=1 -C /usr/local/bin filebeat-${FILEBEAT_VERSION}-linux-${TARGETARCH}/filebeat && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create directories for Filebeat data (registry) and logs
RUN mkdir -p /etc/filebeat /var/lib/filebeat /var/log/nginx

# Copy entrypoint
COPY nginx/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
