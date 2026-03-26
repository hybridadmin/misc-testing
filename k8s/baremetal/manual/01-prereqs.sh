#!/usr/bin/env bash
# =============================================================================
# 01-prereqs.sh - OS prerequisites for Kubernetes on Debian 12/13
# =============================================================================
# Run on: BOTH control plane and worker nodes
# Run as: root (sudo -E ./01-prereqs.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

require_root

log_step "Step 1: OS Prerequisites"

# ---- Verify Debian ----------------------------------------------------------
if [[ ! -f /etc/debian_version ]]; then
    log_error "This script is designed for Debian. Detected: $(cat /etc/os-release 2>/dev/null | head -1)"
    exit 1
fi
DEBIAN_VERSION=$(cat /etc/debian_version)
log_info "Detected Debian version: $DEBIAN_VERSION"

# ---- Set hostname if provided -----------------------------------------------
log_info "Configuring hostname..."
MY_IP=$(hostname -I | awk '{print $1}')
if [[ "$MY_IP" == "$CONTROL_PLANE_IP" && -n "$CONTROL_PLANE_HOSTNAME" ]]; then
    hostnamectl set-hostname "$CONTROL_PLANE_HOSTNAME"
    log_info "Hostname set to $CONTROL_PLANE_HOSTNAME"
elif [[ "$MY_IP" == "$WORKER_IP" && -n "$WORKER_HOSTNAME" ]]; then
    hostnamectl set-hostname "$WORKER_HOSTNAME"
    log_info "Hostname set to $WORKER_HOSTNAME"
fi

# ---- Update /etc/hosts ------------------------------------------------------
log_info "Updating /etc/hosts..."
{
    grep -v "$CONTROL_PLANE_HOSTNAME\|$WORKER_HOSTNAME" /etc/hosts || true
    [[ -n "$CONTROL_PLANE_IP" ]] && echo "$CONTROL_PLANE_IP $CONTROL_PLANE_HOSTNAME"
    [[ -n "$WORKER_IP" ]] && echo "$WORKER_IP $WORKER_HOSTNAME"
} > /tmp/hosts.tmp
mv /tmp/hosts.tmp /etc/hosts

# ---- Disable swap permanently ------------------------------------------------
log_info "Disabling swap..."
swapoff -a
# Remove swap entries from fstab
sed -i '/\sswap\s/d' /etc/fstab
# Mask any swap units
systemctl mask --now "$(systemctl list-units --type=swap --no-legend | awk '{print $1}')" 2>/dev/null || true
log_info "Swap disabled and removed from fstab."

# Verify
if free | grep -i swap | awk '{print $2}' | grep -qv '^0$'; then
    log_error "Swap is still active. Please disable it manually."
    free -h
    exit 1
fi

# ---- Load required kernel modules -------------------------------------------
log_info "Loading kernel modules..."

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF

modprobe overlay
modprobe br_netfilter
modprobe ip_vs
modprobe ip_vs_rr
modprobe ip_vs_wrr
modprobe ip_vs_sh
modprobe nf_conntrack

log_info "Kernel modules loaded."

# ---- Sysctl settings for K8s ------------------------------------------------
log_info "Configuring sysctl parameters..."

cat > /etc/sysctl.d/99-kubernetes.conf <<EOF
# Required for K8s networking
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1

# Recommended tuning
net.ipv4.tcp_keepalive_time   = 600
net.ipv4.tcp_keepalive_intvl  = 60
net.ipv4.tcp_keepalive_probes = 5

# Connection tracking (for kube-proxy IPVS mode)
net.netfilter.nf_conntrack_max = 131072

# File descriptor limits
fs.inotify.max_user_watches  = 524288
fs.inotify.max_user_instances = 8192
fs.file-max                   = 2097152

# VM tuning
vm.max_map_count = 262144
vm.swappiness    = 0
EOF

sysctl --system > /dev/null 2>&1

# Verify critical settings
for param in net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward; do
    val=$(sysctl -n "$param")
    if [[ "$val" != "1" ]]; then
        log_error "$param = $val (expected 1)"
        exit 1
    fi
done
log_info "Sysctl parameters applied and verified."

# ---- Install base packages ---------------------------------------------------
log_info "Installing base packages..."

apt-get update -qq
apt-get install -y -qq \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    bash-completion \
    jq \
    yq \
    socat \
    conntrack \
    ipvsadm \
    ipset \
    open-iscsi \
    nfs-common \
    util-linux \
    ebtables \
    ethtool \
    cron \
    logrotate

# open-iscsi is needed for Longhorn
systemctl enable --now iscsid 2>/dev/null || true

log_info "Base packages installed."

# ---- Disable unnecessary services -------------------------------------------
log_info "Disabling unnecessary services..."
for svc in ufw apparmor; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl disable --now "$svc"
        log_info "Disabled $svc"
    fi
done

# ---- Configure time sync (critical for certificates) ------------------------
log_info "Configuring time synchronization..."
apt-get install -y -qq systemd-timesyncd
systemctl enable --now systemd-timesyncd
timedatectl set-ntp true
log_info "Time sync enabled."

# ---- Configure logrotate for k8s logs ----------------------------------------
cat > /etc/logrotate.d/kubernetes <<EOF
/var/log/pods/*/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
/var/log/containers/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
log_info "Logrotate configured for container logs."

# ---- Summary -----------------------------------------------------------------
echo ""
log_info "=== Prerequisites complete ==="
log_info "Hostname:        $(hostname)"
log_info "Swap:            $(swapon --show | wc -l) swap devices (should be 0)"
log_info "IP forwarding:   $(sysctl -n net.ipv4.ip_forward)"
log_info "br_netfilter:    $(lsmod | grep -c br_netfilter) (should be >= 1)"
log_info "IPVS modules:    $(lsmod | grep -c ip_vs) loaded"
echo ""
log_info "Next: run 02-containerd.sh"
