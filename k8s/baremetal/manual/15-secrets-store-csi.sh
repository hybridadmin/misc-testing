#!/usr/bin/env bash
# =============================================================================
# 15-secrets-store-csi.sh - Install Secrets Store CSI Driver (optional)
# =============================================================================
# Run on: CONTROL PLANE node only
# Run as: root (sudo -E ./15-secrets-store-csi.sh)
#
# This installs the base CSI Secrets Store Driver only (no provider).
# After installation, install the provider for your secrets backend:
#
#   HashiCorp Vault:  https://github.com/hashicorp/vault-csi-provider
#   AWS Secrets Mgr:  https://github.com/aws/secrets-store-csi-driver-provider-aws
#   Azure Key Vault:  https://github.com/Azure/secrets-store-csi-driver-provider-azure
#   GCP Secret Mgr:   https://github.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

require_root
require_kubeconfig

log_step "Step 15 (optional): Install Secrets Store CSI Driver (v${SECRETS_STORE_CSI_VERSION})"

# ---- Install via Helm --------------------------------------------------------
log_info "Adding secrets-store-csi-driver Helm repo..."

helm_repo_add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts

log_info "Installing secrets-store-csi-driver..."

# Generate values file for auditability
cat > "${CONFIGS_DIR}/secrets-store-csi-values.yaml" <<'EOF'
# Secrets Store CSI Driver - Helm values
# Docs: https://secrets-store-csi-driver.sigs.k8s.io/

# Sync mounted secrets as Kubernetes Secret objects
# Required if workloads need env vars from secrets (not just volume mounts)
syncSecret:
  enabled: true

# Enable secret auto-rotation (polls providers for updated secrets)
enableSecretRotation: true

# Rotation poll interval (default: 2m)
rotationPollInterval: "2m"

# Log verbosity (0=normal, higher=more verbose)
logVerbosity: 0

# Resource limits for the driver daemonset
linux:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi

# Prometheus metrics
filteredWatchSecret: true
EOF

helm upgrade --install secrets-store-csi-driver \
    secrets-store-csi-driver/secrets-store-csi-driver \
    --version "${SECRETS_STORE_CSI_VERSION}" \
    --namespace kube-system \
    --values "${CONFIGS_DIR}/secrets-store-csi-values.yaml" \
    --wait \
    --timeout 5m

log_info "Secrets Store CSI Driver Helm release installed."

# ---- Wait for daemonset to be ready -----------------------------------------
log_info "Waiting for CSI driver daemonset to be ready..."
kubectl rollout status daemonset/secrets-store-csi-driver -n kube-system \
    --timeout=120s || {
    log_warn "Daemonset not fully ready. Check: kubectl get ds -n kube-system"
}

# ---- Verify CRDs are installed -----------------------------------------------
log_info "Verifying SecretProviderClass CRD..."
if kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io &>/dev/null; then
    log_info "CRD 'secretproviderclasses.secrets-store.csi.x-k8s.io' is present."
else
    log_warn "CRD not found. The driver may still be initializing."
fi

# ---- Summary -----------------------------------------------------------------
echo ""
log_info "=== Secrets Store CSI Driver installed ==="
kubectl get daemonset -n kube-system -l app.kubernetes.io/name=secrets-store-csi-driver
echo ""
log_info "CRDs installed:"
kubectl get crd | grep secrets-store || true
echo ""
log_info "Next steps:"
log_info "  1. Install a provider for your secrets backend (Vault, AWS, Azure, GCP)"
log_info "  2. Create SecretProviderClass resources pointing to your secrets"
log_info "  3. Mount secrets in pods via CSI volume or sync to K8s Secrets"
echo ""
log_info "Example SecretProviderClass (Vault):"
cat <<'EXAMPLE'
  apiVersion: secrets-store.csi.x-k8s.io/v1
  kind: SecretProviderClass
  metadata:
    name: vault-db-creds
  spec:
    provider: vault
    parameters:
      vaultAddress: "https://vault.example.com:8200"
      roleName: "my-app-role"
      objects: |
        - objectName: "db-password"
          secretPath: "secret/data/myapp/db"
          secretKey: "password"
EXAMPLE
echo ""
log_info "Docs: https://secrets-store-csi-driver.sigs.k8s.io/"
