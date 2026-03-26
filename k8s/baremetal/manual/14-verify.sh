#!/usr/bin/env bash
# =============================================================================
# 14-verify.sh - Comprehensive cluster health verification
# =============================================================================
# Run on: CONTROL PLANE node only
# Run as: root (sudo -E ./14-verify.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

require_root
require_kubeconfig

log_step "Cluster Verification"

PASS=0
FAIL=0
WARN=0

check_pass() { echo -e "  \033[0;32m[PASS]\033[0m $*"; ((PASS++)); }
check_fail() { echo -e "  \033[0;31m[FAIL]\033[0m $*"; ((FAIL++)); }
check_warn() { echo -e "  \033[0;33m[WARN]\033[0m $*"; ((WARN++)); }

# =============================================================================
# 1. Cluster basics
# =============================================================================
echo ""
echo "=== Cluster Basics ==="

# API server health
if kubectl get --raw /healthz &>/dev/null; then
    check_pass "API server is healthy"
else
    check_fail "API server health check failed"
fi

# Nodes
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready")
if [[ "$NODE_COUNT" -ge 2 && "$READY_COUNT" -eq "$NODE_COUNT" ]]; then
    check_pass "All $NODE_COUNT nodes are Ready"
else
    check_fail "$READY_COUNT/$NODE_COUNT nodes are Ready"
fi

# Kubernetes version
K8S_VER=$(kubectl version -o yaml 2>/dev/null | grep gitVersion | head -1 | awk '{print $2}')
check_pass "Kubernetes version: $K8S_VER"

# =============================================================================
# 2. Core components
# =============================================================================
echo ""
echo "=== Core Components ==="

# etcd
ETCD_PODS=$(kubectl get pods -n kube-system -l component=etcd --no-headers 2>/dev/null | grep -c Running)
if [[ "$ETCD_PODS" -ge 1 ]]; then
    check_pass "etcd is running ($ETCD_PODS pod(s))"
else
    check_fail "etcd is not running"
fi

# CoreDNS
COREDNS_READY=$(kubectl get deploy coredns -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
if [[ "$COREDNS_READY" -ge 1 ]]; then
    check_pass "CoreDNS is running ($COREDNS_READY replicas)"
else
    check_fail "CoreDNS is not running"
fi

# kube-proxy mode
KPROXY_MODE=$(kubectl get configmap kube-proxy -n kube-system -o jsonpath='{.data.config\.conf}' 2>/dev/null | grep 'mode:' | awk '{print $2}' | tr -d '"')
if [[ "$KPROXY_MODE" == "ipvs" ]]; then
    check_pass "kube-proxy mode: IPVS"
else
    check_warn "kube-proxy mode: ${KPROXY_MODE:-iptables} (IPVS recommended)"
fi

# =============================================================================
# 3. CNI (Calico)
# =============================================================================
echo ""
echo "=== CNI (Calico) ==="

CALICO_PODS=$(kubectl get pods -n calico-system --no-headers 2>/dev/null | grep -c Running)
if [[ "$CALICO_PODS" -ge 1 ]]; then
    check_pass "Calico is running ($CALICO_PODS pod(s) in calico-system)"
else
    check_fail "Calico is not running"
fi

# Pod connectivity test
if kubectl run verify-net-test --image=busybox:1.36 --restart=Never \
    --command -- wget -qO- --timeout=5 https://kubernetes.default.svc/healthz 2>/dev/null; then
    check_pass "Pod-to-API-server connectivity works"
else
    check_warn "Pod connectivity test inconclusive (may need to check manually)"
fi
kubectl delete pod verify-net-test --force --grace-period=0 2>/dev/null || true

# =============================================================================
# 4. MetalLB
# =============================================================================
echo ""
echo "=== MetalLB ==="

if kubectl get namespace metallb-system &>/dev/null; then
    METALLB_PODS=$(kubectl get pods -n metallb-system --no-headers 2>/dev/null | grep -c Running)
    if [[ "$METALLB_PODS" -ge 1 ]]; then
        check_pass "MetalLB is running ($METALLB_PODS pod(s))"
    else
        check_fail "MetalLB pods not running"
    fi

    POOL_COUNT=$(kubectl get ipaddresspool -n metallb-system --no-headers 2>/dev/null | wc -l)
    if [[ "$POOL_COUNT" -ge 1 ]]; then
        check_pass "MetalLB IP pool configured ($POOL_COUNT pool(s))"
    else
        check_fail "No MetalLB IP pools configured"
    fi
else
    check_warn "MetalLB not installed"
fi

# =============================================================================
# 5. Ingress NGINX
# =============================================================================
echo ""
echo "=== Ingress NGINX ==="

if kubectl get namespace ingress-nginx &>/dev/null; then
    INGRESS_PODS=$(kubectl get pods -n ingress-nginx --no-headers 2>/dev/null | grep -c Running)
    if [[ "$INGRESS_PODS" -ge 1 ]]; then
        check_pass "NGINX Ingress Controller is running ($INGRESS_PODS pod(s))"
    else
        check_fail "NGINX Ingress Controller not running"
    fi

    INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [[ -n "$INGRESS_IP" ]]; then
        check_pass "Ingress external IP: $INGRESS_IP"
    else
        check_warn "No external IP assigned to ingress"
    fi
else
    check_warn "ingress-nginx not installed"
fi

# =============================================================================
# 6. Storage
# =============================================================================
echo ""
echo "=== Storage ==="

DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)
if [[ -n "$DEFAULT_SC" ]]; then
    check_pass "Default StorageClass: $DEFAULT_SC"
else
    check_fail "No default StorageClass configured"
fi

if kubectl get namespace longhorn-system &>/dev/null; then
    LH_PODS=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null | grep -c Running)
    check_pass "Longhorn is running ($LH_PODS pod(s))"
elif kubectl get namespace local-path-storage &>/dev/null; then
    check_pass "local-path-provisioner is installed"
else
    check_warn "No storage provider detected"
fi

# =============================================================================
# 7. cert-manager
# =============================================================================
echo ""
echo "=== cert-manager ==="

if kubectl get namespace cert-manager &>/dev/null; then
    CM_PODS=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -c Running)
    if [[ "$CM_PODS" -ge 3 ]]; then
        check_pass "cert-manager is running ($CM_PODS pod(s))"
    else
        check_warn "cert-manager: $CM_PODS running (expected 3)"
    fi

    ISSUERS=$(kubectl get clusterissuers --no-headers 2>/dev/null | wc -l)
    check_pass "$ISSUERS ClusterIssuer(s) configured"
else
    check_warn "cert-manager not installed"
fi

# =============================================================================
# 8. Monitoring
# =============================================================================
echo ""
echo "=== Monitoring ==="

if kubectl get namespace monitoring &>/dev/null; then
    PROM_PODS=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c Running)
    GRAFANA_PODS=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | grep -c Running)
    LOKI_PODS=$(kubectl get pods -n monitoring -l app=loki --no-headers 2>/dev/null | grep -c Running)

    [[ "$PROM_PODS" -ge 1 ]] && check_pass "Prometheus is running" || check_fail "Prometheus not running"
    [[ "$GRAFANA_PODS" -ge 1 ]] && check_pass "Grafana is running" || check_fail "Grafana not running"
    [[ "$LOKI_PODS" -ge 1 ]] && check_pass "Loki is running" || check_warn "Loki not running"
else
    check_warn "Monitoring stack not installed"
fi

# =============================================================================
# 9. Security
# =============================================================================
echo ""
echo "=== Security ==="

# etcd encryption
if [[ -f /etc/kubernetes/encryption-config.yaml ]]; then
    check_pass "etcd encryption config present"
else
    check_fail "etcd encryption config missing"
fi

# Anonymous auth
ANON_AUTH=$(kubectl get pods -n kube-system -l component=kube-apiserver -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null | grep -c "anonymous-auth=false" || echo 0)
if [[ "$ANON_AUTH" -ge 1 ]]; then
    check_pass "Anonymous auth disabled on API server"
else
    check_warn "Anonymous auth may be enabled"
fi

# PSA labels on kube-system
PSA_LABEL=$(kubectl get namespace kube-system -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
if [[ -n "$PSA_LABEL" ]]; then
    check_pass "PSA enforce label on kube-system: $PSA_LABEL"
else
    check_warn "No PSA enforce label on kube-system"
fi

# Audit logging
if kubectl get pods -n kube-system -l component=kube-apiserver -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null | grep -q "audit-log-path"; then
    check_pass "API server audit logging enabled"
else
    check_warn "Audit logging not detected"
fi

# =============================================================================
# 10. Backup
# =============================================================================
echo ""
echo "=== Backup ==="

if crontab -l 2>/dev/null | grep -q "etcd-backup.sh"; then
    check_pass "etcd backup cron job configured"
else
    check_warn "No etcd backup cron job found"
fi

BACKUP_COUNT=$(find "$ETCD_BACKUP_DIR" -name "etcd-snapshot-*.db.gz" 2>/dev/null | wc -l)
if [[ "$BACKUP_COUNT" -ge 1 ]]; then
    LATEST=$(ls -t "$ETCD_BACKUP_DIR"/etcd-snapshot-*.db.gz 2>/dev/null | head -1)
    check_pass "etcd backups found: $BACKUP_COUNT (latest: $(basename "$LATEST"))"
else
    check_warn "No etcd backup snapshots found in $ETCD_BACKUP_DIR"
fi

# =============================================================================
# 11. Problem pods
# =============================================================================
echo ""
echo "=== Pod Health ==="

PROBLEM_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)
if [[ "$PROBLEM_PODS" -eq 0 ]]; then
    check_pass "All pods are Running or Completed"
else
    check_fail "$PROBLEM_PODS pod(s) in unhealthy state:"
    kubectl get pods -A --no-headers | grep -v "Running\|Completed" | head -10
fi

TOTAL_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
check_pass "Total pods running: $TOTAL_PODS"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=========================================="
echo "  Verification Summary"
echo "=========================================="
echo -e "  \033[0;32mPASS: $PASS\033[0m"
echo -e "  \033[0;31mFAIL: $FAIL\033[0m"
echo -e "  \033[0;33mWARN: $WARN\033[0m"
echo "=========================================="
echo ""

if [[ "$FAIL" -eq 0 ]]; then
    log_info "Cluster is healthy."
else
    log_error "$FAIL check(s) failed. Review the output above."
fi

# ---- Full status dump --------------------------------------------------------
echo ""
log_info "Full cluster overview:"
echo ""
kubectl get nodes -o wide
echo ""
kubectl get pods -A -o wide
echo ""
kubectl get svc -A
echo ""
kubectl get storageclass
echo ""
kubectl get clusterissuers 2>/dev/null || true
