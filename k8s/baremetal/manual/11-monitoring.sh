#!/usr/bin/env bash
# =============================================================================
# 11-monitoring.sh - Install kube-prometheus-stack + Loki
# =============================================================================
# Run on: CONTROL PLANE node only
# Run as: root (sudo -E ./11-monitoring.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

require_root
require_kubeconfig

log_step "Step 11: Install Monitoring Stack"

# ---- Create monitoring namespace ---------------------------------------------
kubectl create namespace monitoring 2>/dev/null || true

# =============================================================================
# Part 1: kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
# =============================================================================
log_info "Installing kube-prometheus-stack..."

helm_repo_add prometheus-community https://prometheus-community.github.io/helm-charts

cat > "${CONFIGS_DIR}/prometheus-stack-values.yaml" <<EOF
# -- Grafana --
grafana:
  enabled: true
  adminPassword: "${GRAFANA_ADMIN_PASSWORD}"
  persistence:
    enabled: true
    size: 5Gi
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  sidecar:
    dashboards:
      enabled: true
      searchNamespace: ALL
    datasources:
      enabled: true
  # Additional datasource for Loki
  additionalDataSources:
    - name: Loki
      type: loki
      url: http://loki.monitoring.svc.cluster.local:3100
      access: proxy
      isDefault: false

# -- Prometheus --
prometheus:
  prometheusSpec:
    retention: "${MONITORING_RETENTION_DAYS}d"
    retentionSize: "10GB"
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: "1"
        memory: 2Gi
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi
    # Scrape all ServiceMonitors in all namespaces
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false

# -- Alertmanager --
alertmanager:
  alertmanagerSpec:
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 128Mi
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 2Gi

# -- Node exporter (runs on all nodes) --
nodeExporter:
  enabled: true

# -- kube-state-metrics --
kubeStateMetrics:
  enabled: true

# -- Scrape targets for etcd, scheduler, controller-manager --
kubeEtcd:
  enabled: true
  endpoints:
    - ${CONTROL_PLANE_IP}
  service:
    port: 2381
    targetPort: 2381

kubeScheduler:
  enabled: true
  endpoints:
    - ${CONTROL_PLANE_IP}

kubeControllerManager:
  enabled: true
  endpoints:
    - ${CONTROL_PLANE_IP}

kubeProxy:
  enabled: true
  endpoints:
    - ${CONTROL_PLANE_IP}
EOF

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --version "${KUBE_PROMETHEUS_STACK_VERSION}" \
    --namespace monitoring \
    --values "${CONFIGS_DIR}/prometheus-stack-values.yaml" \
    --wait \
    --timeout 10m

log_info "kube-prometheus-stack installed."

# =============================================================================
# Part 2: Loki + Promtail (log aggregation)
# =============================================================================
log_info "Installing Loki stack..."

helm_repo_add grafana https://grafana.github.io/helm-charts

cat > "${CONFIGS_DIR}/loki-stack-values.yaml" <<EOF
loki:
  enabled: true
  persistence:
    enabled: true
    size: 10Gi
  config:
    limits_config:
      retention_period: "${MONITORING_RETENTION_DAYS}d"
    table_manager:
      retention_deletes_enabled: true
      retention_period: "${MONITORING_RETENTION_DAYS}d"
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi

promtail:
  enabled: true
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 256Mi

grafana:
  enabled: false  # already installed via kube-prometheus-stack
EOF

helm upgrade --install loki grafana/loki-stack \
    --version "${LOKI_STACK_VERSION}" \
    --namespace monitoring \
    --values "${CONFIGS_DIR}/loki-stack-values.yaml" \
    --wait \
    --timeout 5m

log_info "Loki stack installed."

# ---- Wait for everything -----------------------------------------------------
wait_for_pods "monitoring" 300

# ---- Summary -----------------------------------------------------------------
echo ""
log_info "=== Monitoring Stack installed ==="
kubectl get pods -n monitoring -o wide
echo ""
log_info "Grafana:"
log_info "  Port-forward: kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
log_info "  Username:     admin"
log_info "  Password:     ${GRAFANA_ADMIN_PASSWORD}"
echo ""
log_info "Prometheus:"
log_info "  Port-forward: kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring"
echo ""
log_info "Alertmanager:"
log_info "  Port-forward: kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 -n monitoring"
echo ""
log_info "Retention: ${MONITORING_RETENTION_DAYS} days"
echo ""
log_info "Next: run 12-security.sh"
