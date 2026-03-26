#!/usr/bin/env bash
# =============================================================================
# 02-containerd.sh - Install and configure containerd runtime
# =============================================================================
# Run on: BOTH control plane and worker nodes
# Run as: root (sudo -E ./02-containerd.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

require_root

log_step "Step 2: Install containerd"

# ---- Add Docker's official repo (for containerd) ----------------------------
log_info "Adding Docker repository for containerd..."

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

# Debian 13 (trixie) may not have a Docker repo yet; fall back to bookworm
if ! curl -sfL "https://download.docker.com/linux/debian/dists/${CODENAME}/Release" > /dev/null 2>&1; then
    log_warn "Docker repo not available for '$CODENAME', falling back to 'bookworm'."
    CODENAME="bookworm"
fi

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable
EOF

apt-get update -qq

# ---- Install containerd ------------------------------------------------------
log_info "Installing containerd.io..."
if [[ -n "$CONTAINERD_VERSION" ]]; then
    apt-get install -y -qq "containerd.io=${CONTAINERD_VERSION}*"
else
    apt-get install -y -qq containerd.io
fi

# ---- Configure containerd ----------------------------------------------------
log_info "Generating containerd default config..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Enable SystemdCgroup (required for kubelet)
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Set the sandbox (pause) image to match the K8s version
# kubeadm 1.35 uses registry.k8s.io/pause:3.10.2
PAUSE_IMAGE="registry.k8s.io/pause:3.10.2"
sed -i "s|sandbox_image = .*|sandbox_image = \"${PAUSE_IMAGE}\"|" /etc/containerd/config.toml

log_info "containerd configured with SystemdCgroup=true, pause=${PAUSE_IMAGE}"

# ---- Enable and start --------------------------------------------------------
systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd

# Verify
if ! systemctl is-active --quiet containerd; then
    log_error "containerd failed to start. Check: journalctl -xeu containerd"
    exit 1
fi

CONTAINERD_VER=$(containerd --version | awk '{print $3}')
log_info "containerd $CONTAINERD_VER is running."

# ---- Install crictl (CRI CLI) -----------------------------------------------
log_info "Configuring crictl..."
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

log_info "crictl configured."

# ---- Summary -----------------------------------------------------------------
echo ""
log_info "=== containerd installation complete ==="
log_info "Version:  $CONTAINERD_VER"
log_info "Socket:   /run/containerd/containerd.sock"
log_info "Config:   /etc/containerd/config.toml"
echo ""
log_info "Next: run 03-k8s-packages.sh"
