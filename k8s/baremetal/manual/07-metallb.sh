#!/usr/bin/env bash
# =============================================================================
# 07-metallb.sh - Install MetalLB L2 load balancer
# =============================================================================
# Run on: CONTROL PLANE node only
# Run as: root (sudo -E ./07-metallb.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

require_root
require_kubeconfig
require_var "METALLB_IP_RANGE"

log_step "Step 7: Install MetalLB (v${METALLB_VERSION})"

# ---- kube-proxy strictARP (already set in kubeadm config, verify) -----------
log_info "Verifying kube-proxy strictARP..."
CURRENT_MODE=$(kubectl get configmap kube-proxy -n kube-system -o jsonpath='{.data.config\.conf}' 2>/dev/null | grep -A1 'ipvs:' | grep strictARP | awk '{print $2}')
if [[ "$CURRENT_MODE" != "true" ]]; then
    log_info "Patching kube-proxy for strictARP..."
    kubectl get configmap kube-proxy -n kube-system -o yaml | \
        sed -e 's/strictARP: false/strictARP: true/' | \
        kubectl apply -f - 2>/dev/null || true
    kubectl rollout restart daemonset kube-proxy -n kube-system
fi

# ---- Install MetalLB via Helm ------------------------------------------------
log_info "Installing MetalLB..."

helm_repo_add metallb https://metallb.github.io/metallb

helm upgrade --install metallb metallb/metallb \
    --version "${METALLB_VERSION}" \
    --namespace metallb-system \
    --create-namespace \
    --wait \
    --timeout 5m

log_info "MetalLB Helm release installed."

# ---- Wait for pods -----------------------------------------------------------
wait_for_pods "metallb-system" 120

# ---- Configure L2 address pool -----------------------------------------------
log_info "Configuring MetalLB L2 address pool: ${METALLB_IP_RANGE}"

# MetalLB needs its webhooks to be ready before accepting CRDs
log_info "Waiting for MetalLB webhook to be ready..."
sleep 15
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/component=controller \
    -n metallb-system --timeout=120s

cat > "${CONFIGS_DIR}/metallb-pool.yaml" <<EOF
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - "${METALLB_IP_RANGE}"
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
EOF

kubectl apply -f "${CONFIGS_DIR}/metallb-pool.yaml"

log_info "MetalLB L2 pool configured."

# ---- Summary -----------------------------------------------------------------
echo ""
log_info "=== MetalLB installed ==="
kubectl get pods -n metallb-system -o wide
echo ""
log_info "IP range:  ${METALLB_IP_RANGE}"
log_info "Mode:      L2"
echo ""
log_info "Test: create a LoadBalancer service and check for an external IP:"
log_info "  kubectl create deployment test-lb --image=nginx --port=80"
log_info "  kubectl expose deployment test-lb --type=LoadBalancer --port=80"
log_info "  kubectl get svc test-lb"
echo ""
log_info "Next: run 08-ingress-nginx.sh"
