#!/usr/bin/env bash
# =============================================================================
# 00-env.sh - Central configuration for the K8s bare-metal deployment
# =============================================================================
# Source this file from every other script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/00-env.sh"
#
# Override any variable by exporting it before sourcing, or by creating a
# file called "env.local" next to this script (it will be sourced if present).
# =============================================================================

set -euo pipefail

# ---- Cluster identity -------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-k8s-prod}"
K8S_VERSION="${K8S_VERSION:-1.35}"              # minor version (apt repo)
K8S_VERSION_FULL="${K8S_VERSION_FULL:-1.35.3}"  # full version for kubeadm

# ---- Node IPs (MUST be set before running) -----------------------------------
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"        # e.g. 192.168.1.10
CONTROL_PLANE_HOSTNAME="${CONTROL_PLANE_HOSTNAME:-cp1}"
WORKER_IP="${WORKER_IP:-}"                      # e.g. 192.168.1.11
WORKER_HOSTNAME="${WORKER_HOSTNAME:-worker1}"

# ---- Networking -------------------------------------------------------------
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
DNS_DOMAIN="${DNS_DOMAIN:-cluster.local}"

# ---- CNI (Calico) -----------------------------------------------------------
CALICO_VERSION="${CALICO_VERSION:-3.31.4}"
CALICO_MODE="${CALICO_MODE:-vxlan}"              # vxlan or ipip

# ---- MetalLB ----------------------------------------------------------------
METALLB_VERSION="${METALLB_VERSION:-0.15.3}"
METALLB_IP_RANGE="${METALLB_IP_RANGE:-}"         # e.g. 192.168.1.200-192.168.1.210

# ---- Ingress NGINX ----------------------------------------------------------
# NOTE: The kubernetes/ingress-nginx repo was archived on 2026-03-24.
# Chart 4.15.1 is the final release. Consider migrating to an alternative
# ingress controller (e.g., Envoy Gateway, Traefik) for future updates.
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-4.15.1}"  # Helm chart version

# ---- Storage ----------------------------------------------------------------
# Options: "longhorn" or "local-path"
STORAGE_PROVIDER="${STORAGE_PROVIDER:-longhorn}"
LONGHORN_VERSION="${LONGHORN_VERSION:-1.11.1}"

# ---- cert-manager -----------------------------------------------------------
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.20.0}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"        # required for Let's Encrypt

# ---- Monitoring --------------------------------------------------------------
KUBE_PROMETHEUS_STACK_VERSION="${KUBE_PROMETHEUS_STACK_VERSION:-82.14.1}"
LOKI_STACK_VERSION="${LOKI_STACK_VERSION:-2.10.3}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-changeme}"
MONITORING_RETENTION_DAYS="${MONITORING_RETENTION_DAYS:-15}"

# ---- Backup (Velero) --------------------------------------------------------
VELERO_VERSION="${VELERO_VERSION:-12.0.0}"          # Helm chart version
ETCD_BACKUP_DIR="${ETCD_BACKUP_DIR:-/var/backups/etcd}"
ETCD_BACKUP_RETENTION_DAYS="${ETCD_BACKUP_RETENTION_DAYS:-30}"

# ---- Secrets Store CSI Driver (optional) ------------------------------------
SECRETS_STORE_CSI_VERSION="${SECRETS_STORE_CSI_VERSION:-1.5.6}"  # Helm chart version

# ---- Containerd -------------------------------------------------------------
CONTAINERD_VERSION="${CONTAINERD_VERSION:-}"       # empty = latest from repo

# ---- Helm -------------------------------------------------------------------
HELM_VERSION="${HELM_VERSION:-}"                   # empty = latest

# ---- Paths -------------------------------------------------------------------
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CONFIGS_DIR="${SCRIPT_DIR}/configs"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/kubernetes/admin.conf}"

# ---- Load local overrides (if any) ------------------------------------------
if [[ -f "${SCRIPT_DIR}/env.local" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/env.local"
fi

# ---- Helper functions --------------------------------------------------------

log_info() {
    echo -e "\033[0;32m[INFO]\033[0m  $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_warn() {
    echo -e "\033[0;33m[WARN]\033[0m  $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_step() {
    echo ""
    echo -e "\033[1;36m========================================\033[0m"
    echo -e "\033[1;36m  $*\033[0m"
    echo -e "\033[1;36m========================================\033[0m"
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This script must be run as root (or with sudo -E)."
        exit 1
    fi
}

require_var() {
    local var_name="$1"
    if [[ -z "${!var_name:-}" ]]; then
        log_error "Required variable '$var_name' is not set."
        echo "  Set it in env.local or export before running:"
        echo "    export $var_name=\"value\""
        exit 1
    fi
}

require_kubeconfig() {
    if [[ ! -f "$KUBECONFIG_PATH" ]]; then
        # try user kubeconfig
        if [[ -f "$HOME/.kube/config" ]]; then
            export KUBECONFIG="$HOME/.kube/config"
        else
            log_error "No kubeconfig found at $KUBECONFIG_PATH or ~/.kube/config"
            exit 1
        fi
    else
        export KUBECONFIG="$KUBECONFIG_PATH"
    fi
}

wait_for_pods() {
    local namespace="$1"
    local timeout="${2:-300}"
    log_info "Waiting for all pods in '$namespace' to be ready (timeout: ${timeout}s)..."
    kubectl wait --for=condition=Ready pods --all -n "$namespace" \
        --timeout="${timeout}s" 2>/dev/null || {
        log_warn "Some pods in '$namespace' are not ready yet. Check manually:"
        kubectl get pods -n "$namespace" -o wide
    }
}

wait_for_deployment() {
    local namespace="$1"
    local deployment="$2"
    local timeout="${3:-300}"
    log_info "Waiting for deployment '$deployment' in '$namespace' (timeout: ${timeout}s)..."
    kubectl rollout status deployment/"$deployment" -n "$namespace" \
        --timeout="${timeout}s" || {
        log_warn "Deployment '$deployment' not ready. Check: kubectl get deploy $deployment -n $namespace"
    }
}

helm_repo_add() {
    local name="$1"
    local url="$2"
    if ! helm repo list 2>/dev/null | grep -q "^${name}"; then
        helm repo add "$name" "$url"
    fi
    helm repo update "$name"
}

is_control_plane() {
    local my_ip
    my_ip=$(hostname -I | awk '{print $1}')
    [[ "$my_ip" == "$CONTROL_PLANE_IP" ]] || hostname | grep -qi "$CONTROL_PLANE_HOSTNAME"
}
