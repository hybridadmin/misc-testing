#!/usr/bin/env bash
# =============================================================================
# control-plane-firewall.sh
# Configures iptables rules on a K8s CONTROL PLANE node.
#
# Protects: API Server (6443), etcd (2379-2380), Scheduler (10259),
#           Controller Manager (10257), Kubelet API (10250)
#
# Required env vars (see common.env for full docs):
#   ALLOWED_SSH_SOURCES   - Comma-separated IPs/CIDRs for SSH access
#   CONTROL_PLANE_IPS     - Comma-separated control plane node IPs
#   WORKER_NODE_IPS       - Comma-separated worker node IPs
#
# Usage:
#   export ALLOWED_SSH_SOURCES="10.0.0.5,192.168.1.0/24"
#   export CONTROL_PLANE_IPS="10.0.1.10,10.0.1.11,10.0.1.12"
#   export WORKER_NODE_IPS="10.0.2.10,10.0.2.11,10.0.2.12"
#   sudo -E ./control-plane-firewall.sh
#
#   DRY_RUN=true ./control-plane-firewall.sh   # preview without applying
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.env"

# ---- Validate inputs --------------------------------------------------------
require_var "ALLOWED_SSH_SOURCES"
require_var "CONTROL_PLANE_IPS"
require_var "WORKER_NODE_IPS"
require_root

log_info "=== K8s Control Plane Firewall Configuration ==="
log_info "SSH allowed from:    $ALLOWED_SSH_SOURCES"
log_info "Control plane nodes: $CONTROL_PLANE_IPS"
log_info "Worker nodes:        $WORKER_NODE_IPS"
log_info "Pod CIDR:            $POD_CIDR"
log_info "Service CIDR:        $SERVICE_CIDR"
log_info "DRY_RUN:             $DRY_RUN"

# ---- Backup current rules ---------------------------------------------------
backup_iptables

# ---- Create custom chains ---------------------------------------------------
print_section "Creating custom chains"

# Remove old custom chains if they exist (ignore errors)
for chain in K8S-CONTROL-PLANE K8S-SSH-ACCESS; do
    run_ipt -F "$chain" 2>/dev/null || true
    run_ipt -X "$chain" 2>/dev/null || true
done

run_ipt -N K8S-CONTROL-PLANE
run_ipt -N K8S-SSH-ACCESS
log_info "Custom chains created."

# ---- Loopback & established connections -------------------------------------
print_section "Base rules: loopback & established connections"

run_ipt -A INPUT -i lo -j ACCEPT
run_ipt -A OUTPUT -o lo -j ACCEPT
run_ipt -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
log_info "Base rules applied."

# ---- SSH access (delegated to custom chain) ----------------------------------
print_section "SSH access rules"

run_ipt -A INPUT -p tcp --dport "$SSH_PORT" -j K8S-SSH-ACCESS

split_csv "$ALLOWED_SSH_SOURCES"
for src in "${SPLIT_RESULT[@]}"; do
    src="$(echo "$src" | xargs)"   # trim whitespace
    run_ipt -A K8S-SSH-ACCESS -s "$src" -p tcp --dport "$SSH_PORT" -j ACCEPT
    log_info "SSH allowed from $src"
done
run_ipt -A K8S-SSH-ACCESS -p tcp --dport "$SSH_PORT" -j DROP
log_info "SSH access: all other sources DROPPED."

# ---- API Server (6443) ------------------------------------------------------
print_section "API Server (port $K8S_API_PORT)"

# Allow from all control plane nodes
split_csv "$CONTROL_PLANE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do
    ip="$(echo "$ip" | xargs)"
    run_ipt -A K8S-CONTROL-PLANE -s "$ip" -p tcp --dport "$K8S_API_PORT" -j ACCEPT
done

# Allow from all worker nodes
split_csv "$WORKER_NODE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do
    ip="$(echo "$ip" | xargs)"
    run_ipt -A K8S-CONTROL-PLANE -s "$ip" -p tcp --dport "$K8S_API_PORT" -j ACCEPT
done

# Allow from pod and service networks (pods need to reach the API server)
run_ipt -A K8S-CONTROL-PLANE -s "$POD_CIDR" -p tcp --dport "$K8S_API_PORT" -j ACCEPT
run_ipt -A K8S-CONTROL-PLANE -s "$SERVICE_CIDR" -p tcp --dport "$K8S_API_PORT" -j ACCEPT

# Allow API access from the SSH-allowed locations (admin kubectl access)
split_csv "$ALLOWED_SSH_SOURCES"
for src in "${SPLIT_RESULT[@]}"; do
    src="$(echo "$src" | xargs)"
    run_ipt -A K8S-CONTROL-PLANE -s "$src" -p tcp --dport "$K8S_API_PORT" -j ACCEPT
done

log_info "API Server rules applied."

# ---- etcd (2379-2380) -- control plane peers ONLY ---------------------------
print_section "etcd (ports $ETCD_CLIENT_PORT-$ETCD_PEER_PORT)"

split_csv "$CONTROL_PLANE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do
    ip="$(echo "$ip" | xargs)"
    run_ipt -A K8S-CONTROL-PLANE -s "$ip" -p tcp --dport "$ETCD_CLIENT_PORT" -j ACCEPT
    run_ipt -A K8S-CONTROL-PLANE -s "$ip" -p tcp --dport "$ETCD_PEER_PORT" -j ACCEPT
done
# Also allow localhost (API server talks to etcd locally)
run_ipt -A K8S-CONTROL-PLANE -s 127.0.0.1 -p tcp --dport "$ETCD_CLIENT_PORT" -j ACCEPT

log_info "etcd rules applied (control plane peers only)."

# ---- Scheduler (10259) -- localhost only ------------------------------------
print_section "Scheduler (port $SCHEDULER_PORT)"

run_ipt -A K8S-CONTROL-PLANE -s 127.0.0.1 -p tcp --dport "$SCHEDULER_PORT" -j ACCEPT
split_csv "$CONTROL_PLANE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do
    ip="$(echo "$ip" | xargs)"
    run_ipt -A K8S-CONTROL-PLANE -s "$ip" -p tcp --dport "$SCHEDULER_PORT" -j ACCEPT
done

log_info "Scheduler rules applied."

# ---- Controller Manager (10257) -- localhost only ---------------------------
print_section "Controller Manager (port $CONTROLLER_MANAGER_PORT)"

run_ipt -A K8S-CONTROL-PLANE -s 127.0.0.1 -p tcp --dport "$CONTROLLER_MANAGER_PORT" -j ACCEPT
split_csv "$CONTROL_PLANE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do
    ip="$(echo "$ip" | xargs)"
    run_ipt -A K8S-CONTROL-PLANE -s "$ip" -p tcp --dport "$CONTROLLER_MANAGER_PORT" -j ACCEPT
done

log_info "Controller Manager rules applied."

# ---- Kubelet API (10250) on control plane -----------------------------------
print_section "Kubelet API (port $KUBELET_API_PORT)"

# API server and other control plane nodes need access
split_csv "$CONTROL_PLANE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do
    ip="$(echo "$ip" | xargs)"
    run_ipt -A K8S-CONTROL-PLANE -s "$ip" -p tcp --dport "$KUBELET_API_PORT" -j ACCEPT
done

log_info "Kubelet API rules applied."

# ---- CoreDNS metrics (9153) -------------------------------------------------
print_section "CoreDNS metrics (port $COREDNS_PORT)"

run_ipt -A K8S-CONTROL-PLANE -s "$POD_CIDR" -p tcp --dport "$COREDNS_PORT" -j ACCEPT
split_csv "$CONTROL_PLANE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do
    ip="$(echo "$ip" | xargs)"
    run_ipt -A K8S-CONTROL-PLANE -s "$ip" -p tcp --dport "$COREDNS_PORT" -j ACCEPT
done

log_info "CoreDNS metrics rules applied."

# ---- DNS (allow pod network to reach CoreDNS) --------------------------------
print_section "DNS (UDP/TCP 53) for pod network"

run_ipt -A K8S-CONTROL-PLANE -s "$POD_CIDR" -p udp --dport 53 -j ACCEPT
run_ipt -A K8S-CONTROL-PLANE -s "$POD_CIDR" -p tcp --dport 53 -j ACCEPT
run_ipt -A K8S-CONTROL-PLANE -s "$SERVICE_CIDR" -p udp --dport 53 -j ACCEPT
run_ipt -A K8S-CONTROL-PLANE -s "$SERVICE_CIDR" -p tcp --dport 53 -j ACCEPT

log_info "DNS rules applied."

# ---- ICMP (allow ping for diagnostics) --------------------------------------
print_section "ICMP"

run_ipt -A K8S-CONTROL-PLANE -p icmp --icmp-type echo-request -j ACCEPT
run_ipt -A K8S-CONTROL-PLANE -p icmp --icmp-type echo-reply -j ACCEPT

log_info "ICMP rules applied."

# ---- Attach custom chain to INPUT and set default DROP -----------------------
print_section "Attach chains & set default policy"

run_ipt -A INPUT -j K8S-CONTROL-PLANE

# Log and drop everything else
run_ipt -A INPUT -m limit --limit 5/min -j LOG --log-prefix "K8S-CP-DROPPED: " --log-level 4
run_ipt -A INPUT -j DROP

# Allow all outbound (control plane needs to reach registries, DNS, etc.)
run_ipt -P OUTPUT ACCEPT

log_info "Default INPUT policy: DROP (with logging)."
log_info "Default OUTPUT policy: ACCEPT."

# ---- Persist rules -----------------------------------------------------------
print_section "Persisting rules"

if [[ "$DRY_RUN" != "true" ]]; then
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
        log_info "Rules saved via netfilter-persistent."
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || \
        log_warn "Could not auto-persist rules. Save manually with: iptables-save > /path/to/rules"
    fi
else
    log_info "[DRY-RUN] Skipping rule persistence."
fi

echo ""
log_info "=== Control Plane firewall configuration complete ==="
