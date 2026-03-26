#!/usr/bin/env bash
# =============================================================================
# 05-cni-calico.sh - Install Calico CNI
# =============================================================================
# Run on: CONTROL PLANE node only
# Run as: root (sudo -E ./05-cni-calico.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

require_root
require_kubeconfig

log_step "Step 5: Install Calico CNI (v${CALICO_VERSION})"

# ---- Install Calico operator via Helm ---------------------------------------
log_info "Installing Calico via Helm..."

helm_repo_add projectcalico https://docs.tigera.io/calico/charts

# ---- Generate values file ----------------------------------------------------
CALICO_ENCAP="VXLANCrossSubnet"
if [[ "$CALICO_MODE" == "ipip" ]]; then
    CALICO_ENCAP="IPIPCrossSubnet"
fi

cat > "${CONFIGS_DIR}/calico-values.yaml" <<EOF
installation:
  enabled: true
  kubernetesProvider: ""
  cni:
    type: Calico
  calicoNetwork:
    bgp: Disabled
    ipPools:
      - cidr: "${POD_CIDR}"
        encapsulation: "${CALICO_ENCAP}"
        natOutgoing: Enabled
        nodeSelector: all()
    nodeAddressAutodetectionV4:
      firstFound: true
  controlPlaneTolerations:
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Exists"
      effect: "NoSchedule"
  typhaDeployment:
    # Typha not needed for < 50 nodes; disable to save resources
    spec:
      template:
        spec:
          containers: []
EOF

log_info "Calico values written to ${CONFIGS_DIR}/calico-values.yaml"

# ---- Install -----------------------------------------------------------------
helm upgrade --install calico projectcalico/tigera-operator \
    --version "v${CALICO_VERSION}" \
    --namespace tigera-operator \
    --create-namespace \
    --values "${CONFIGS_DIR}/calico-values.yaml" \
    --wait \
    --timeout 5m

log_info "Calico Helm release installed."

# ---- Wait for Calico to be ready --------------------------------------------
log_info "Waiting for Calico pods..."
sleep 10

# Wait for calico-system namespace to appear
for i in $(seq 1 30); do
    if kubectl get namespace calico-system &>/dev/null; then
        break
    fi
    sleep 5
done

wait_for_pods "calico-system" 300
wait_for_pods "calico-apiserver" 180 2>/dev/null || true

# ---- Wait for CoreDNS (it was pending until CNI was ready) -------------------
log_info "Waiting for CoreDNS..."
wait_for_pods "kube-system" 120

# ---- Verify node is Ready ---------------------------------------------------
log_info "Verifying node status..."
for i in $(seq 1 20); do
    STATUS=$(kubectl get node "$(hostname)" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "$STATUS" == "True" ]]; then
        log_info "Node $(hostname) is Ready."
        break
    fi
    sleep 5
done

# ---- Summary -----------------------------------------------------------------
echo ""
log_info "=== Calico CNI installed ==="
kubectl get pods -n calico-system -o wide
echo ""
kubectl get pods -n kube-system -o wide
echo ""
kubectl get nodes -o wide
echo ""
log_info "Encapsulation: ${CALICO_ENCAP}"
log_info "Pod CIDR:      ${POD_CIDR}"
echo ""
log_info "Next: copy worker-join-command.sh to the worker and run 06-join-worker.sh"
