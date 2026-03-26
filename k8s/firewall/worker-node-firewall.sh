#!/usr/bin/env bash
# =============================================================================
# worker-node-firewall.sh
# Configures iptables rules on a K8s WORKER NODE.
#
# Protects: Kubelet API (10250), kube-proxy (10256), NodePort range
#           (30000-32767), CNI overlay ports
#
# Required env vars (see common.env for full docs):
#   ALLOWED_SSH_SOURCES   - Comma-separated IPs/CIDRs for SSH access
#   CONTROL_PLANE_IPS     - Comma-separated control plane node IPs
#   WORKER_NODE_IPS       - Comma-separated worker node IPs
#
# Optional:
#   NODEPORT_ALLOWED_SOURCES - Comma-separated IPs/CIDRs allowed to reach
#                              NodePorts. If unset, NodePorts are open to all.
#   CNI_PLUGIN             - "flannel" (default), "calico", or "weave"
#
# Usage:
#   export ALLOWED_SSH_SOURCES="10.0.0.5,192.168.1.0/24"
#   export CONTROL_PLANE_IPS="10.0.1.10"
#   export WORKER_NODE_IPS="10.0.2.10,10.0.2.11,10.0.2.12"
#   sudo -E ./worker-node-firewall.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.env"

CNI_PLUGIN="${CNI_PLUGIN:-flannel}"
NODEPORT_ALLOWED_SOURCES="${NODEPORT_ALLOWED_SOURCES:-}"

# ---- Validate inputs --------------------------------------------------------
require_var "ALLOWED_SSH_SOURCES"
require_var "CONTROL_PLANE_IPS"
require_var "WORKER_NODE_IPS"
require_root

log_info "=== K8s Worker Node Firewall Configuration ==="
log_info "SSH allowed from:    $ALLOWED_SSH_SOURCES"
log_info "Control plane nodes: $CONTROL_PLANE_IPS"
log_info "Worker nodes:        $WORKER_NODE_IPS"
log_info "Pod CIDR:            $POD_CIDR"
log_info "Service CIDR:        $SERVICE_CIDR"
log_info "CNI Plugin:          $CNI_PLUGIN"
log_info "DRY_RUN:             $DRY_RUN"

# ---- Backup current rules ---------------------------------------------------
backup_iptables

# ---- Create custom chains ---------------------------------------------------
print_section "Creating custom chains"

for chain in K8S-WORKER K8S-SSH-ACCESS K8S-NODEPORTS K8S-CNI; do
    run_ipt -F "$chain" 2>/dev/null || true
    run_ipt -X "$chain" 2>/dev/null || true
done

run_ipt -N K8S-WORKER
run_ipt -N K8S-SSH-ACCESS
run_ipt -N K8S-NODEPORTS
run_ipt -N K8S-CNI
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
    src="$(echo "$src" | xargs)"
    run_ipt -A K8S-SSH-ACCESS -s "$src" -p tcp --dport "$SSH_PORT" -j ACCEPT
    log_info "SSH allowed from $src"
done
run_ipt -A K8S-SSH-ACCESS -p tcp --dport "$SSH_PORT" -j DROP
log_info "SSH access: all other sources DROPPED."

# ---- Kubelet API (10250) -- control plane & local workers -------------------
print_section "Kubelet API (port $KUBELET_API_PORT)"

# Control plane must reach kubelet for logs, exec, port-forward
split_csv "$CONTROL_PLANE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do
    ip="$(echo "$ip" | xargs)"
    run_ipt -A K8S-WORKER -s "$ip" -p tcp --dport "$KUBELET_API_PORT" -j ACCEPT
done

# Other worker nodes (metrics-server, etc.)
split_csv "$WORKER_NODE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do
    ip="$(echo "$ip" | xargs)"
    run_ipt -A K8S-WORKER -s "$ip" -p tcp --dport "$KUBELET_API_PORT" -j ACCEPT
done

log_info "Kubelet API rules applied."

# ---- kube-proxy health check (10256) ----------------------------------------
print_section "kube-proxy health check (port $KUBE_PROXY_METRICS_PORT)"

split_csv "$CONTROL_PLANE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do
    ip="$(echo "$ip" | xargs)"
    run_ipt -A K8S-WORKER -s "$ip" -p tcp --dport "$KUBE_PROXY_METRICS_PORT" -j ACCEPT
done
run_ipt -A K8S-WORKER -s 127.0.0.1 -p tcp --dport "$KUBE_PROXY_METRICS_PORT" -j ACCEPT

log_info "kube-proxy health check rules applied."

# ---- NodePort services (30000-32767) ----------------------------------------
print_section "NodePort range ($NODEPORT_RANGE_START-$NODEPORT_RANGE_END)"

run_ipt -A INPUT -p tcp --dport "$NODEPORT_RANGE_START":"$NODEPORT_RANGE_END" -j K8S-NODEPORTS
run_ipt -A INPUT -p udp --dport "$NODEPORT_RANGE_START":"$NODEPORT_RANGE_END" -j K8S-NODEPORTS

if [[ -n "$NODEPORT_ALLOWED_SOURCES" ]]; then
    split_csv "$NODEPORT_ALLOWED_SOURCES"
    for src in "${SPLIT_RESULT[@]}"; do
        src="$(echo "$src" | xargs)"
        run_ipt -A K8S-NODEPORTS -s "$src" -j ACCEPT
        log_info "NodePort access allowed from $src"
    done
    run_ipt -A K8S-NODEPORTS -j DROP
    log_info "NodePorts restricted to specified sources."
else
    run_ipt -A K8S-NODEPORTS -j ACCEPT
    log_warn "NodePorts open to all sources (set NODEPORT_ALLOWED_SOURCES to restrict)."
fi

# ---- CNI overlay network ports ----------------------------------------------
print_section "CNI overlay network ($CNI_PLUGIN)"

# Build list of all cluster node IPs
ALL_NODE_IPS=""
split_csv "$CONTROL_PLANE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do ALL_NODE_IPS+="$(echo "$ip" | xargs),"; done
split_csv "$WORKER_NODE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do ALL_NODE_IPS+="$(echo "$ip" | xargs),"; done
ALL_NODE_IPS="${ALL_NODE_IPS%,}"  # trim trailing comma

case "$CNI_PLUGIN" in
    flannel)
        split_csv "$ALL_NODE_IPS"
        for ip in "${SPLIT_RESULT[@]}"; do
            ip="$(echo "$ip" | xargs)"
            run_ipt -A K8S-CNI -s "$ip" -p udp --dport "$VXLAN_PORT" -j ACCEPT
        done
        log_info "Flannel VXLAN (UDP $VXLAN_PORT) rules applied."
        ;;
    calico)
        split_csv "$ALL_NODE_IPS"
        for ip in "${SPLIT_RESULT[@]}"; do
            ip="$(echo "$ip" | xargs)"
            run_ipt -A K8S-CNI -s "$ip" -p tcp --dport "$CALICO_BGP_PORT" -j ACCEPT
            run_ipt -A K8S-CNI -s "$ip" -p tcp --dport "$CALICO_TYPHA_PORT" -j ACCEPT
        done
        log_info "Calico BGP ($CALICO_BGP_PORT) and Typha ($CALICO_TYPHA_PORT) rules applied."
        ;;
    weave)
        split_csv "$ALL_NODE_IPS"
        for ip in "${SPLIT_RESULT[@]}"; do
            ip="$(echo "$ip" | xargs)"
            run_ipt -A K8S-CNI -s "$ip" -p tcp --dport "$WEAVE_TCP_PORT" -j ACCEPT
            run_ipt -A K8S-CNI -s "$ip" -p udp --dport "$WEAVE_UDP_PORT" -j ACCEPT
        done
        log_info "Weave (TCP $WEAVE_TCP_PORT, UDP $WEAVE_UDP_PORT) rules applied."
        ;;
    *)
        log_warn "Unknown CNI plugin '$CNI_PLUGIN'. No CNI-specific rules added."
        ;;
esac

run_ipt -A INPUT -j K8S-CNI

# ---- Pod & service network traffic ------------------------------------------
print_section "Pod & service network traffic"

run_ipt -A K8S-WORKER -s "$POD_CIDR" -j ACCEPT
run_ipt -A K8S-WORKER -s "$SERVICE_CIDR" -j ACCEPT

log_info "Pod and service CIDR traffic allowed."

# ---- DNS (allow pod network to reach DNS) ------------------------------------
print_section "DNS (UDP/TCP 53)"

run_ipt -A K8S-WORKER -s "$POD_CIDR" -p udp --dport 53 -j ACCEPT
run_ipt -A K8S-WORKER -s "$POD_CIDR" -p tcp --dport 53 -j ACCEPT

log_info "DNS rules applied."

# ---- ICMP -------------------------------------------------------------------
print_section "ICMP"

run_ipt -A K8S-WORKER -p icmp --icmp-type echo-request -j ACCEPT
run_ipt -A K8S-WORKER -p icmp --icmp-type echo-reply -j ACCEPT

log_info "ICMP rules applied."

# ---- Attach custom chain and set default DROP --------------------------------
print_section "Attach chains & set default policy"

run_ipt -A INPUT -j K8S-WORKER

# Log and drop everything else
run_ipt -A INPUT -m limit --limit 5/min -j LOG --log-prefix "K8S-WORKER-DROPPED: " --log-level 4
run_ipt -A INPUT -j DROP

# Allow all outbound
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
log_info "=== Worker Node firewall configuration complete ==="
