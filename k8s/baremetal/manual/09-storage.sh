#!/usr/bin/env bash
# =============================================================================
# 09-storage.sh - Install storage provisioner (Longhorn or local-path)
# =============================================================================
# Run on: CONTROL PLANE node only
# Run as: root (sudo -E ./09-storage.sh)
#
# Set STORAGE_PROVIDER to "longhorn" (default) or "local-path"
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

require_root
require_kubeconfig

log_step "Step 9: Install Storage Provider (${STORAGE_PROVIDER})"

# =============================================================================
install_longhorn() {
    log_info "Installing Longhorn v${LONGHORN_VERSION}..."

    # ---- Verify prerequisites on nodes ---
    log_info "Checking Longhorn prerequisites..."
    for cmd in iscsiadm mount.nfs; do
        if ! command -v "$cmd" &>/dev/null; then
            log_warn "'$cmd' not found locally. Ensure it's installed on all nodes."
        fi
    done

    helm_repo_add longhorn https://charts.longhorn.io

    cat > "${CONFIGS_DIR}/longhorn-values.yaml" <<EOF
defaultSettings:
  # 2 replicas for a 2-node cluster
  defaultReplicaCount: 2
  # Storage reservation
  storageOverProvisioningPercentage: 100
  storageMinimalAvailablePercentage: 15
  # Backup
  backupTarget: ""
  # Node drain
  nodeDrainPolicy: "block-if-contains-last-replica"
  # Auto-salvage replicas
  autoSalvage: true
  # Guaranteed engine CPU
  guaranteedInstanceManagerCPU: 12

persistence:
  defaultClass: true
  defaultFsType: ext4
  defaultClassReplicaCount: 2
  reclaimPolicy: Retain

ingress:
  enabled: false

longhornUI:
  replicas: 1

resources:
  requests:
    cpu: 25m
    memory: 64Mi
  limits:
    cpu: 250m
    memory: 256Mi
EOF

    helm upgrade --install longhorn longhorn/longhorn \
        --version "${LONGHORN_VERSION}" \
        --namespace longhorn-system \
        --create-namespace \
        --values "${CONFIGS_DIR}/longhorn-values.yaml" \
        --wait \
        --timeout 10m

    log_info "Longhorn installed."
    wait_for_pods "longhorn-system" 300

    echo ""
    kubectl get pods -n longhorn-system -o wide
    echo ""
    log_info "Longhorn UI: kubectl port-forward svc/longhorn-frontend 8080:80 -n longhorn-system"
}

# =============================================================================
install_local_path() {
    log_info "Installing local-path-provisioner..."

    LOCAL_PATH_VERSION="v0.0.30"
    kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"

    # Set as default StorageClass
    kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

    log_info "local-path-provisioner installed."
    wait_for_pods "local-path-storage" 120

    echo ""
    kubectl get pods -n local-path-storage -o wide
    echo ""
    log_warn "local-path-provisioner uses node-local storage with NO replication."
    log_warn "Data is lost if the node dies. Only use for non-critical workloads"
    log_warn "or applications that handle their own replication."
}

# =============================================================================
case "$STORAGE_PROVIDER" in
    longhorn)
        install_longhorn
        ;;
    local-path)
        install_local_path
        ;;
    *)
        log_error "Unknown STORAGE_PROVIDER: '$STORAGE_PROVIDER'. Use 'longhorn' or 'local-path'."
        exit 1
        ;;
esac

# ---- Verify default StorageClass ---------------------------------------------
echo ""
log_info "=== Storage Provider installed ==="
kubectl get storageclass
echo ""
log_info "Default StorageClass:"
kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}'
echo ""
log_info "Next: run 10-cert-manager.sh"
