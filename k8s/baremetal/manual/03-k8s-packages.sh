#!/usr/bin/env bash
# =============================================================================
# 03-k8s-packages.sh - Install kubeadm, kubelet, kubectl
# =============================================================================
# Run on: BOTH control plane and worker nodes
# Run as: root (sudo -E ./03-k8s-packages.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

require_root

log_step "Step 3: Install Kubernetes packages (v${K8S_VERSION})"

# ---- Add Kubernetes apt repo -------------------------------------------------
log_info "Adding Kubernetes apt repository for v${K8S_VERSION}..."

install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes

cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /
EOF

apt-get update -qq

# ---- Install packages --------------------------------------------------------
log_info "Installing kubeadm, kubelet, kubectl (${K8S_VERSION_FULL})..."

apt-get install -y -qq \
    "kubelet=${K8S_VERSION_FULL}-*" \
    "kubeadm=${K8S_VERSION_FULL}-*" \
    "kubectl=${K8S_VERSION_FULL}-*"

# ---- Pin versions (prevent accidental upgrades) ------------------------------
log_info "Pinning package versions..."
apt-mark hold kubelet kubeadm kubectl

# ---- Enable kubelet (it will crash-loop until kubeadm init/join) -------------
systemctl enable kubelet

# ---- Configure kubelet defaults ----------------------------------------------
log_info "Configuring kubelet defaults..."
mkdir -p /etc/default
cat > /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS="--node-ip=${CONTROL_PLANE_IP:-$(hostname -I | awk '{print $1}')}"
EOF

# ---- Install Helm ------------------------------------------------------------
log_info "Installing Helm..."
if ! command -v helm &>/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
HELM_VER=$(helm version --short 2>/dev/null || echo "unknown")
log_info "Helm installed: $HELM_VER"

# ---- Shell completion --------------------------------------------------------
log_info "Setting up shell completions..."
kubectl completion bash > /etc/bash_completion.d/kubectl 2>/dev/null || true
kubeadm completion bash > /etc/bash_completion.d/kubeadm 2>/dev/null || true
helm completion bash > /etc/bash_completion.d/helm 2>/dev/null || true

# ---- Verify ------------------------------------------------------------------
echo ""
log_info "=== Kubernetes packages installed ==="
log_info "kubeadm: $(kubeadm version -o short)"
log_info "kubelet: $(kubelet --version 2>/dev/null || dpkg -l kubelet | tail -1 | awk '{print $3}')"
log_info "kubectl: $(kubectl version --client -o yaml 2>/dev/null | grep gitVersion | awk '{print $2}')"
log_info "helm:    $HELM_VER"
log_info "Packages held: $(apt-mark showhold | tr '\n' ' ')"
echo ""
log_info "Next: run 04-init-control-plane.sh (on control plane node only)"
