#!/usr/bin/env bash
# =============================================================================
# 12-security.sh - Post-install security hardening
# =============================================================================
# Run on: CONTROL PLANE node only
# Run as: root (sudo -E ./12-security.sh)
#
# This script:
#   1. Configures Pod Security Admission (PSA) per namespace
#   2. Creates default-deny NetworkPolicies
#   3. Verifies etcd encryption at rest
#   4. Creates an RBAC-scoped admin user (non-cluster-admin)
#   5. Applies additional security best practices
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

require_root
require_kubeconfig

log_step "Step 12: Security Hardening"

# =============================================================================
# 1. Pod Security Admission (PSA) labels
# =============================================================================
log_info "Configuring Pod Security Admission labels..."

# System namespaces: privileged (they need it)
for ns in kube-system kube-public kube-node-lease calico-system calico-apiserver \
          tigera-operator metallb-system ingress-nginx longhorn-system \
          cert-manager monitoring local-path-storage; do
    if kubectl get namespace "$ns" &>/dev/null; then
        kubectl label namespace "$ns" \
            pod-security.kubernetes.io/enforce=privileged \
            pod-security.kubernetes.io/warn=privileged \
            pod-security.kubernetes.io/audit=privileged \
            --overwrite 2>/dev/null || true
    fi
done

log_info "System namespaces labeled as 'privileged'."

# Create a template for production workload namespaces
cat > "${CONFIGS_DIR}/namespace-restricted-template.yaml" <<'EOF'
# Template: production namespace with restricted PSA
# Usage: copy, rename, and apply
#   kubectl apply -f namespace-restricted-template.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: NAMESPACE_NAME
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
EOF

log_info "Restricted namespace template saved to ${CONFIGS_DIR}/namespace-restricted-template.yaml"

# =============================================================================
# 2. Default-deny NetworkPolicies
# =============================================================================
log_info "Creating default-deny NetworkPolicy templates..."

cat > "${CONFIGS_DIR}/netpol-default-deny.yaml" <<'EOF'
# Default deny all ingress and egress in a namespace.
# Apply per namespace, then create allow policies as needed.
#
# Usage:
#   kubectl apply -f netpol-default-deny.yaml -n <namespace>
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# Allow DNS egress (almost every pod needs this)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to: []
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
# Allow ingress from ingress-nginx controller
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-nginx
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
---
# Allow Prometheus scraping
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9090
        - protocol: TCP
          port: 8080
        - protocol: TCP
          port: 9113
        - protocol: TCP
          port: 9153
EOF

log_info "NetworkPolicy templates saved to ${CONFIGS_DIR}/netpol-default-deny.yaml"
log_info "Apply to production namespaces: kubectl apply -f netpol-default-deny.yaml -n <ns>"

# =============================================================================
# 3. Verify etcd encryption at rest
# =============================================================================
log_info "Verifying etcd encryption at rest..."

if [[ -f /etc/kubernetes/encryption-config.yaml ]]; then
    # Create a test secret, read it from etcd, verify it's encrypted
    kubectl create secret generic encryption-test \
        --from-literal=test=encryption-verification \
        -n default 2>/dev/null || true

    # Check via etcdctl if available
    if command -v etcdctl &>/dev/null || [[ -f /usr/local/bin/etcdctl ]]; then
        ETCDCTL_API=3 etcdctl \
            --endpoints=https://127.0.0.1:2379 \
            --cacert=/etc/kubernetes/pki/etcd/ca.crt \
            --cert=/etc/kubernetes/pki/etcd/server.crt \
            --key=/etc/kubernetes/pki/etcd/server.key \
            get /registry/secrets/default/encryption-test 2>/dev/null | \
            head -c 100 | grep -q "k8s:enc:aescbc" && \
            log_info "etcd encryption verified: secrets are encrypted with aescbc." || \
            log_warn "Could not verify etcd encryption. Check manually."
    else
        log_info "etcdctl not available on host. To verify encryption:"
        log_info "  kubectl exec -n kube-system etcd-$(hostname) -- etcdctl \\"
        log_info "    --endpoints=https://127.0.0.1:2379 \\"
        log_info "    --cacert=/etc/kubernetes/pki/etcd/ca.crt \\"
        log_info "    --cert=/etc/kubernetes/pki/etcd/server.crt \\"
        log_info "    --key=/etc/kubernetes/pki/etcd/server.key \\"
        log_info "    get /registry/secrets/default/encryption-test | hexdump -C | head"
    fi

    # Clean up test secret
    kubectl delete secret encryption-test -n default 2>/dev/null || true
else
    log_warn "Encryption config not found at /etc/kubernetes/encryption-config.yaml"
    log_warn "Secrets are NOT encrypted at rest."
fi

# =============================================================================
# 4. Create a scoped admin ServiceAccount
# =============================================================================
log_info "Creating scoped admin ServiceAccount..."

cat > "${CONFIGS_DIR}/rbac-admin.yaml" <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: admin
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cluster-viewer
  namespace: admin
---
# Read-only access across the cluster (safe for dashboards, debugging)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-viewer-binding
subjects:
  - kind: ServiceAccount
    name: cluster-viewer
    namespace: admin
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f "${CONFIGS_DIR}/rbac-admin.yaml"
log_info "ServiceAccount 'cluster-viewer' created in 'admin' namespace."

# =============================================================================
# 5. Additional hardening
# =============================================================================
log_info "Applying additional hardening..."

# Remove default service account auto-mount in new namespaces
# (best practice: disable automountServiceAccountToken by default)
cat > "${CONFIGS_DIR}/sa-no-automount.yaml" <<'EOF'
# Apply to each namespace's default service account to prevent
# auto-mounting the service account token into pods.
# Usage: kubectl apply -f sa-no-automount.yaml -n <namespace>
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
automountServiceAccountToken: false
EOF

log_info "Service account no-automount template: ${CONFIGS_DIR}/sa-no-automount.yaml"

# Audit policy (if not already set by kubeadm config)
if [[ ! -f /etc/kubernetes/audit-policy.yaml ]]; then
    cat > /etc/kubernetes/audit-policy.yaml <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Don't log read-only requests to system endpoints
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "services/status"]
  # Don't log kubelet health checks
  - level: None
    users: ["kubelet"]
    verbs: ["get"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status"]
  # Don't log watch requests by the system
  - level: None
    verbs: ["watch"]
    users:
      - "system:kube-controller-manager"
      - "system:kube-scheduler"
      - "system:serviceaccount:kube-system:endpoint-controller"
  # Log secret access at Metadata level (who, when, but not the content)
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  # Log everything else at RequestResponse for write operations
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
  # Log other reads at Metadata level
  - level: Metadata
    verbs: ["get", "list", "watch"]
EOF
    log_info "Audit policy created at /etc/kubernetes/audit-policy.yaml"
fi

# ---- Summary -----------------------------------------------------------------
echo ""
log_info "=== Security Hardening complete ==="
echo ""
log_info "Applied:"
log_info "  - PSA labels on system namespaces (privileged)"
log_info "  - Restricted namespace template (${CONFIGS_DIR}/namespace-restricted-template.yaml)"
log_info "  - Default-deny NetworkPolicy templates (${CONFIGS_DIR}/netpol-default-deny.yaml)"
log_info "  - etcd encryption at rest verification"
log_info "  - Scoped RBAC (cluster-viewer ServiceAccount)"
log_info "  - SA no-automount template"
log_info "  - Audit policy"
echo ""
log_info "For new production namespaces, apply:"
log_info "  1. PSA restricted labels"
log_info "  2. Default-deny NetworkPolicies"
log_info "  3. SA no-automount on the default service account"
echo ""
log_info "Next: run 13-backup.sh"
