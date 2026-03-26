#!/usr/bin/env bash
# =============================================================================
# inter-node-comms.sh
# Secures communication channels between K8s control plane and worker nodes.
#
# This script:
#   1. Restricts inter-node traffic to cluster members only
#   2. Secures CNI overlay network traffic
#   3. Protects kubelet <-> API server communication paths
#   4. Locks down etcd peer traffic to control plane only
#   5. Configures FORWARD chain rules for pod-to-pod traffic
#
# Required env vars:
#   ALLOWED_SSH_SOURCES   - Comma-separated IPs/CIDRs for SSH access
#   CONTROL_PLANE_IPS     - Comma-separated control plane node IPs
#   WORKER_NODE_IPS       - Comma-separated worker node IPs
#
# Optional:
#   CNI_PLUGIN            - "flannel" (default), "calico", or "weave"
#   NODE_ROLE             - "control-plane" or "worker" (auto-detect if unset)
#
# Usage:
#   export ALLOWED_SSH_SOURCES="10.0.0.5"
#   export CONTROL_PLANE_IPS="10.0.1.10"
#   export WORKER_NODE_IPS="10.0.2.10,10.0.2.11"
#   export CNI_PLUGIN="flannel"
#   sudo -E ./inter-node-comms.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.env"

CNI_PLUGIN="${CNI_PLUGIN:-flannel}"
NODE_ROLE="${NODE_ROLE:-}"

# ---- Validate inputs --------------------------------------------------------
require_var "ALLOWED_SSH_SOURCES"
require_var "CONTROL_PLANE_IPS"
require_var "WORKER_NODE_IPS"
require_root

# ---- Detect node role if not specified ---------------------------------------
if [[ -z "$NODE_ROLE" ]]; then
    LOCAL_IPS=$(hostname -I 2>/dev/null || echo "")
    split_csv "$CONTROL_PLANE_IPS"
    for ip in "${SPLIT_RESULT[@]}"; do
        ip="$(echo "$ip" | xargs)"
        if echo "$LOCAL_IPS" | grep -qw "$ip"; then
            NODE_ROLE="control-plane"
            break
        fi
    done
    if [[ -z "$NODE_ROLE" ]]; then
        NODE_ROLE="worker"
    fi
fi

log_info "=== Inter-Node Communication Security ==="
log_info "Node role:           $NODE_ROLE"
log_info "Control plane nodes: $CONTROL_PLANE_IPS"
log_info "Worker nodes:        $WORKER_NODE_IPS"
log_info "Pod CIDR:            $POD_CIDR"
log_info "Service CIDR:        $SERVICE_CIDR"
log_info "CNI Plugin:          $CNI_PLUGIN"
log_info "DRY_RUN:             $DRY_RUN"

# ---- Backup current rules ---------------------------------------------------
backup_iptables

# ---- Build full cluster node list -------------------------------------------
ALL_NODE_IPS=""
split_csv "$CONTROL_PLANE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do ALL_NODE_IPS+="$(echo "$ip" | xargs),"; done
split_csv "$WORKER_NODE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do ALL_NODE_IPS+="$(echo "$ip" | xargs),"; done
ALL_NODE_IPS="${ALL_NODE_IPS%,}"

# ---- Create custom chains ---------------------------------------------------
print_section "Creating custom chains for inter-node traffic"

for chain in K8S-INTERNODE K8S-FORWARD-FILTER; do
    run_ipt -F "$chain" 2>/dev/null || true
    run_ipt -X "$chain" 2>/dev/null || true
done

run_ipt -N K8S-INTERNODE
run_ipt -N K8S-FORWARD-FILTER
log_info "Custom chains created."

# =========================================================================
# SECTION 1: Kubelet <-> API Server communication
# =========================================================================
print_section "Kubelet <-> API Server communication"

if [[ "$NODE_ROLE" == "control-plane" ]]; then
    # Control plane: allow worker kubelets to reach API server
    split_csv "$WORKER_NODE_IPS"
    for ip in "${SPLIT_RESULT[@]}"; do
        ip="$(echo "$ip" | xargs)"
        # Workers -> API server
        run_ipt -A K8S-INTERNODE -s "$ip" -p tcp --dport "$K8S_API_PORT" -j ACCEPT
        # API server -> worker kubelet (for exec, logs, port-forward)
        run_ipt -A K8S-INTERNODE -s "$ip" -p tcp --sport "$KUBELET_API_PORT" -j ACCEPT
    done

    # Control plane peers
    split_csv "$CONTROL_PLANE_IPS"
    for ip in "${SPLIT_RESULT[@]}"; do
        ip="$(echo "$ip" | xargs)"
        run_ipt -A K8S-INTERNODE -s "$ip" -p tcp --dport "$K8S_API_PORT" -j ACCEPT
        run_ipt -A K8S-INTERNODE -s "$ip" -p tcp --dport "$KUBELET_API_PORT" -j ACCEPT
    done

    log_info "API server ingress rules applied."

elif [[ "$NODE_ROLE" == "worker" ]]; then
    # Worker: allow control plane to reach kubelet
    split_csv "$CONTROL_PLANE_IPS"
    for ip in "${SPLIT_RESULT[@]}"; do
        ip="$(echo "$ip" | xargs)"
        run_ipt -A K8S-INTERNODE -s "$ip" -p tcp --dport "$KUBELET_API_PORT" -j ACCEPT
    done

    # Worker peers (metrics-server, etc.)
    split_csv "$WORKER_NODE_IPS"
    for ip in "${SPLIT_RESULT[@]}"; do
        ip="$(echo "$ip" | xargs)"
        run_ipt -A K8S-INTERNODE -s "$ip" -p tcp --dport "$KUBELET_API_PORT" -j ACCEPT
    done

    log_info "Kubelet ingress rules applied."
fi

# =========================================================================
# SECTION 2: etcd peer communication (control plane only)
# =========================================================================
if [[ "$NODE_ROLE" == "control-plane" ]]; then
    print_section "etcd peer communication (control plane only)"

    split_csv "$CONTROL_PLANE_IPS"
    for ip in "${SPLIT_RESULT[@]}"; do
        ip="$(echo "$ip" | xargs)"
        run_ipt -A K8S-INTERNODE -s "$ip" -p tcp --dport "$ETCD_CLIENT_PORT" -j ACCEPT
        run_ipt -A K8S-INTERNODE -s "$ip" -p tcp --dport "$ETCD_PEER_PORT" -j ACCEPT
    done

    # Explicitly deny etcd from workers
    split_csv "$WORKER_NODE_IPS"
    for ip in "${SPLIT_RESULT[@]}"; do
        ip="$(echo "$ip" | xargs)"
        run_ipt -A K8S-INTERNODE -s "$ip" -p tcp --dport "$ETCD_CLIENT_PORT" -j DROP
        run_ipt -A K8S-INTERNODE -s "$ip" -p tcp --dport "$ETCD_PEER_PORT" -j DROP
    done

    log_info "etcd locked to control plane peers. Workers explicitly blocked."
fi

# =========================================================================
# SECTION 3: CNI overlay network inter-node traffic
# =========================================================================
print_section "CNI overlay ($CNI_PLUGIN) inter-node traffic"

split_csv "$ALL_NODE_IPS"
case "$CNI_PLUGIN" in
    flannel)
        for ip in "${SPLIT_RESULT[@]}"; do
            ip="$(echo "$ip" | xargs)"
            run_ipt -A K8S-INTERNODE -s "$ip" -p udp --dport "$VXLAN_PORT" -j ACCEPT
            run_ipt -A K8S-INTERNODE -s "$ip" -p udp --sport "$VXLAN_PORT" -j ACCEPT
        done
        # Drop VXLAN from non-cluster sources
        run_ipt -A K8S-INTERNODE -p udp --dport "$VXLAN_PORT" -j DROP
        log_info "Flannel VXLAN inter-node rules applied."
        ;;
    calico)
        for ip in "${SPLIT_RESULT[@]}"; do
            ip="$(echo "$ip" | xargs)"
            run_ipt -A K8S-INTERNODE -s "$ip" -p tcp --dport "$CALICO_BGP_PORT" -j ACCEPT
            run_ipt -A K8S-INTERNODE -s "$ip" -p tcp --dport "$CALICO_TYPHA_PORT" -j ACCEPT
            # Calico IPIP encapsulation
            run_ipt -A K8S-INTERNODE -s "$ip" -p 4 -j ACCEPT
        done
        run_ipt -A K8S-INTERNODE -p tcp --dport "$CALICO_BGP_PORT" -j DROP
        run_ipt -A K8S-INTERNODE -p tcp --dport "$CALICO_TYPHA_PORT" -j DROP
        log_info "Calico inter-node rules applied (BGP + IPIP)."
        ;;
    weave)
        for ip in "${SPLIT_RESULT[@]}"; do
            ip="$(echo "$ip" | xargs)"
            run_ipt -A K8S-INTERNODE -s "$ip" -p tcp --dport "$WEAVE_TCP_PORT" -j ACCEPT
            run_ipt -A K8S-INTERNODE -s "$ip" -p udp --dport "$WEAVE_UDP_PORT" -j ACCEPT
        done
        run_ipt -A K8S-INTERNODE -p tcp --dport "$WEAVE_TCP_PORT" -j DROP
        run_ipt -A K8S-INTERNODE -p udp --dport "$WEAVE_UDP_PORT" -j DROP
        log_info "Weave inter-node rules applied."
        ;;
    *)
        log_warn "Unknown CNI '$CNI_PLUGIN'. Skipping CNI rules."
        ;;
esac

# =========================================================================
# SECTION 4: FORWARD chain -- pod-to-pod traffic between nodes
# =========================================================================
print_section "FORWARD chain: pod-to-pod traffic"

# Allow forwarding for pod CIDR traffic (required for cross-node pod comms)
run_ipt -A K8S-FORWARD-FILTER -s "$POD_CIDR" -d "$POD_CIDR" -j ACCEPT
run_ipt -A K8S-FORWARD-FILTER -s "$POD_CIDR" -d "$SERVICE_CIDR" -j ACCEPT
run_ipt -A K8S-FORWARD-FILTER -s "$SERVICE_CIDR" -d "$POD_CIDR" -j ACCEPT

# Allow established/related forwarded connections
run_ipt -A K8S-FORWARD-FILTER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow forwarding from cluster nodes
split_csv "$ALL_NODE_IPS"
for ip in "${SPLIT_RESULT[@]}"; do
    ip="$(echo "$ip" | xargs)"
    run_ipt -A K8S-FORWARD-FILTER -s "$ip" -j ACCEPT
    run_ipt -A K8S-FORWARD-FILTER -d "$ip" -j ACCEPT
done

# Drop and log non-cluster forwarded traffic
run_ipt -A K8S-FORWARD-FILTER -m limit --limit 5/min \
    -j LOG --log-prefix "K8S-FWD-DROPPED: " --log-level 4
run_ipt -A K8S-FORWARD-FILTER -j DROP

# Attach to FORWARD chain
run_ipt -A FORWARD -j K8S-FORWARD-FILTER

log_info "FORWARD chain rules applied."

# =========================================================================
# SECTION 5: Block non-cluster sources on K8s ports
# =========================================================================
print_section "Block non-cluster sources on K8s management ports"

# Build a list of protected ports based on role
PROTECTED_PORTS="$KUBELET_API_PORT"
if [[ "$NODE_ROLE" == "control-plane" ]]; then
    PROTECTED_PORTS+=",$ETCD_CLIENT_PORT,$ETCD_PEER_PORT,$SCHEDULER_PORT,$CONTROLLER_MANAGER_PORT"
fi

# For each protected port, drop traffic from non-cluster sources
# (Cluster sources were already ACCEPTed above in K8S-INTERNODE)
IFS=',' read -ra PORTS <<< "$PROTECTED_PORTS"
for port in "${PORTS[@]}"; do
    run_ipt -A K8S-INTERNODE -p tcp --dport "$port" \
        -m limit --limit 3/min -j LOG \
        --log-prefix "K8S-INTERNODE-DENY[$port]: " --log-level 4
    run_ipt -A K8S-INTERNODE -p tcp --dport "$port" -j DROP
done

log_info "Non-cluster traffic blocked on management ports."

# ---- Attach inter-node chain to INPUT ----------------------------------------
run_ipt -A INPUT -j K8S-INTERNODE

# ---- Persist rules -----------------------------------------------------------
print_section "Persisting rules"

if [[ "$DRY_RUN" != "true" ]]; then
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
        log_info "Rules saved via netfilter-persistent."
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || \
        log_warn "Could not auto-persist rules. Save manually."
    fi
else
    log_info "[DRY-RUN] Skipping rule persistence."
fi

echo ""
log_info "=== Inter-Node Communication Security complete ==="
