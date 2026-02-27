FROM nginx:1.29.5

# Remove default config
RUN rm /etc/nginx/conf.d/default.conf

# Copy custom high-performance configuration
COPY nginx.conf /etc/nginx/nginx.conf

# Validate the configuration at build time
RUN nginx -t

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
