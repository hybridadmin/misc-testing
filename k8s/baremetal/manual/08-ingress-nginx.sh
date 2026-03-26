#!/usr/bin/env bash
# =============================================================================
# 08-ingress-nginx.sh - Install NGINX Ingress Controller
# =============================================================================
# Run on: CONTROL PLANE node only
# Run as: root (sudo -E ./08-ingress-nginx.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

require_root
require_kubeconfig

log_step "Step 8: Install NGINX Ingress Controller"

# ---- Install via Helm --------------------------------------------------------
log_info "Installing ingress-nginx..."

helm_repo_add ingress-nginx https://kubernetes.github.io/ingress-nginx

cat > "${CONFIGS_DIR}/ingress-nginx-values.yaml" <<EOF
controller:
  # Use LoadBalancer (MetalLB will assign an IP)
  service:
    type: LoadBalancer
    externalTrafficPolicy: Local

  # Run on worker nodes
  nodeSelector:
    kubernetes.io/os: linux
  tolerations: []

  # Resource limits for a small cluster
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi

  # Security headers and hardening
  config:
    # Security
    hide-server-tokens: "true"
    ssl-redirect: "true"
    force-ssl-redirect: "true"
    hsts: "true"
    hsts-max-age: "31536000"
    hsts-include-subdomains: "true"

    # Performance
    use-gzip: "true"
    gzip-types: "application/json application/javascript text/css text/plain"
    worker-processes: "auto"
    keep-alive: "75"

    # Logging
    log-format-upstream: '\$remote_addr - \$remote_user [\$time_local] "\$request" \$status \$body_bytes_sent "\$http_referer" "\$http_user_agent" \$request_length \$request_time [\$proxy_upstream_name] [\$proxy_alternative_upstream_name] \$upstream_addr \$upstream_response_length \$upstream_response_time \$upstream_status \$req_id'

    # Proxy settings
    proxy-body-size: "50m"
    proxy-connect-timeout: "10"
    proxy-read-timeout: "120"
    proxy-send-timeout: "120"

  # Admission webhooks
  admissionWebhooks:
    enabled: true

  # Metrics for Prometheus
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      namespace: monitoring

  # Pod disruption budget
  minAvailable: 0

defaultBackend:
  enabled: true
  resources:
    requests:
      cpu: 10m
      memory: 20Mi
    limits:
      cpu: 50m
      memory: 64Mi
EOF

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --version "${INGRESS_NGINX_VERSION}" \
    --namespace ingress-nginx \
    --create-namespace \
    --values "${CONFIGS_DIR}/ingress-nginx-values.yaml" \
    --wait \
    --timeout 5m

log_info "ingress-nginx Helm release installed."

# ---- Wait for pods and external IP -------------------------------------------
wait_for_pods "ingress-nginx" 180

log_info "Waiting for LoadBalancer IP..."
for i in $(seq 1 30); do
    EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [[ -n "$EXTERNAL_IP" ]]; then
        break
    fi
    sleep 5
done

# ---- Summary -----------------------------------------------------------------
echo ""
log_info "=== NGINX Ingress Controller installed ==="
kubectl get pods -n ingress-nginx -o wide
echo ""
kubectl get svc -n ingress-nginx
echo ""
if [[ -n "$EXTERNAL_IP" ]]; then
    log_info "External IP: $EXTERNAL_IP"
    log_info "Point your DNS records to this IP."
else
    log_warn "No external IP assigned yet. Check MetalLB configuration."
fi
echo ""
log_info "Next: run 09-storage.sh"
