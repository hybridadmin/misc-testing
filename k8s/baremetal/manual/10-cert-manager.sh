#!/usr/bin/env bash
# =============================================================================
# 10-cert-manager.sh - Install cert-manager with ClusterIssuers
# =============================================================================
# Run on: CONTROL PLANE node only
# Run as: root (sudo -E ./10-cert-manager.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

require_root
require_kubeconfig

log_step "Step 10: Install cert-manager (v${CERT_MANAGER_VERSION})"

# ---- Install via Helm --------------------------------------------------------
log_info "Installing cert-manager..."

helm_repo_add jetstack https://charts.jetstack.io

helm upgrade --install cert-manager jetstack/cert-manager \
    --version "v${CERT_MANAGER_VERSION}" \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true \
    --set prometheus.enabled=true \
    --set prometheus.servicemonitor.enabled=true \
    --wait \
    --timeout 5m

log_info "cert-manager Helm release installed."
wait_for_pods "cert-manager" 120

# ---- Create ClusterIssuers ---------------------------------------------------
log_info "Creating ClusterIssuers..."

# Self-signed issuer (for internal services)
cat > "${CONFIGS_DIR}/cert-manager-issuers.yaml" <<EOF
---
# Self-signed issuer (bootstrap, internal services)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
---
# Internal CA (sign internal certificates from a self-signed root)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: internal-ca-bootstrap
spec:
  selfSigned: {}
---
# Certificate for the internal CA
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: internal-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: "${CLUSTER_NAME}-internal-ca"
  secretName: internal-ca-secret
  duration: 87600h   # 10 years
  renewBefore: 8760h # 1 year
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
---
# Internal CA issuer (use this for internal service TLS)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: internal-ca
spec:
  ca:
    secretName: internal-ca-secret
EOF

# Let's Encrypt issuers (only if email is provided)
if [[ -n "$LETSENCRYPT_EMAIL" ]]; then
    cat >> "${CONFIGS_DIR}/cert-manager-issuers.yaml" <<EOF
---
# Let's Encrypt staging (for testing - not trusted by browsers)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: "${LETSENCRYPT_EMAIL}"
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - http01:
          ingress:
            class: nginx
---
# Let's Encrypt production (rate-limited - use staging first)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "${LETSENCRYPT_EMAIL}"
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
    log_info "Let's Encrypt issuers configured with email: $LETSENCRYPT_EMAIL"
else
    log_warn "LETSENCRYPT_EMAIL not set. Skipping Let's Encrypt issuers."
    log_warn "You can set it later and re-run, or create issuers manually."
fi

kubectl apply -f "${CONFIGS_DIR}/cert-manager-issuers.yaml"

# Wait for issuers to be ready
sleep 10
log_info "ClusterIssuer status:"
kubectl get clusterissuers -o wide

# ---- Summary -----------------------------------------------------------------
echo ""
log_info "=== cert-manager installed ==="
kubectl get pods -n cert-manager -o wide
echo ""
log_info "Available ClusterIssuers:"
kubectl get clusterissuers
echo ""
log_info "Usage in an Ingress annotation:"
log_info '  cert-manager.io/cluster-issuer: "letsencrypt-prod"'
log_info '  cert-manager.io/cluster-issuer: "internal-ca"'
echo ""
log_info "Next: run 11-monitoring.sh"
