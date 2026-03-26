# Kubernetes Firewall Scripts

iptables-based firewall scripts to harden a Kubernetes cluster. These scripts protect the control plane, secure worker nodes, lock down SSH access to specific source IPs/CIDRs, and restrict inter-node communication to cluster members only.

All scripts require Linux with `iptables` installed. They must be run as root (or with `sudo -E`). Every script supports a dry-run mode for safe previewing.

## Files

| File | Run on | Purpose |
|------|--------|---------|
| `common.env` | (sourced) | Shared variables, port definitions, and helper functions |
| `control-plane-firewall.sh` | Control plane nodes | Locks down API server, etcd, scheduler, controller manager |
| `worker-node-firewall.sh` | Worker nodes | Locks down kubelet, kube-proxy, NodePorts, CNI overlay |
| `ssh-hardening.sh` | Any node | Restricts SSH, hardens sshd_config, TCP wrappers, fail2ban |
| `inter-node-comms.sh` | Any node | Secures control plane <-> worker traffic, FORWARD chain |

## Prerequisites

- Linux with `iptables` (tested on Ubuntu 20.04+/22.04+, RHEL/CentOS 7+/8+, Debian 11+)
- Root or sudo access
- `conntrack` kernel module loaded (`modprobe nf_conntrack`)
- For rule persistence: `iptables-persistent` (Debian/Ubuntu) or `iptables-services` (RHEL/CentOS)
- For SSH hardening with fail2ban: `fail2ban` package (auto-installed if `SETUP_FAIL2BAN=true`)

## Environment Variables

### Required (all scripts except `ssh-hardening.sh`)

| Variable | Format | Example |
|----------|--------|---------|
| `ALLOWED_SSH_SOURCES` | Comma-separated IPs/CIDRs | `10.0.0.5,192.168.1.0/24,203.0.113.50` |
| `CONTROL_PLANE_IPS` | Comma-separated IPs | `10.0.1.10,10.0.1.11,10.0.1.12` |
| `WORKER_NODE_IPS` | Comma-separated IPs | `10.0.2.10,10.0.2.11,10.0.2.12` |

`ssh-hardening.sh` only requires `ALLOWED_SSH_SOURCES`.

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `POD_CIDR` | `10.244.0.0/16` | Pod network CIDR (Flannel default; adjust for your CNI) |
| `SERVICE_CIDR` | `10.96.0.0/12` | Kubernetes service network CIDR |
| `CNI_PLUGIN` | `flannel` | CNI in use: `flannel`, `calico`, or `weave` |
| `DRY_RUN` | `false` | Set to `true` to print rules without applying |
| `IPTABLES_CMD` | `iptables` | Override the iptables binary path |
| `SSH_PORT` | `22` | SSH port (if using a non-standard port) |
| `NODE_ROLE` | (auto-detect) | `control-plane` or `worker` (for `inter-node-comms.sh`) |
| `NODEPORT_ALLOWED_SOURCES` | (empty = open) | Comma-separated IPs/CIDRs allowed to reach NodePorts |
| `HARDEN_SSHD_CONFIG` | `true` | Set to `false` to skip sshd_config modifications |
| `SETUP_FAIL2BAN` | `false` | Set to `true` to install and configure fail2ban |

## Quick Start

```bash
# 1. Set your cluster details
export ALLOWED_SSH_SOURCES="10.0.0.5,192.168.1.0/24"
export CONTROL_PLANE_IPS="10.0.1.10,10.0.1.11,10.0.1.12"
export WORKER_NODE_IPS="10.0.2.10,10.0.2.11,10.0.2.12"

# 2. Preview what each script will do (safe, no changes applied)
DRY_RUN=true ./control-plane-firewall.sh
DRY_RUN=true ./worker-node-firewall.sh
DRY_RUN=true ./ssh-hardening.sh
DRY_RUN=true ./inter-node-comms.sh

# 3. Apply for real (run on the appropriate nodes as root)
sudo -E ./control-plane-firewall.sh   # on control plane nodes
sudo -E ./worker-node-firewall.sh     # on worker nodes
sudo -E ./ssh-hardening.sh            # on all nodes
sudo -E ./inter-node-comms.sh         # on all nodes
```

## Deployment Order

Run the scripts in this order on each node:

### On control plane nodes

```bash
export ALLOWED_SSH_SOURCES="<your-admin-ips>"
export CONTROL_PLANE_IPS="<cp-node-ips>"
export WORKER_NODE_IPS="<worker-node-ips>"

sudo -E ./ssh-hardening.sh
sudo -E ./control-plane-firewall.sh
sudo -E ./inter-node-comms.sh
```

### On worker nodes

```bash
export ALLOWED_SSH_SOURCES="<your-admin-ips>"
export CONTROL_PLANE_IPS="<cp-node-ips>"
export WORKER_NODE_IPS="<worker-node-ips>"
export CNI_PLUGIN="flannel"  # or calico, weave

sudo -E ./ssh-hardening.sh
sudo -E ./worker-node-firewall.sh
sudo -E ./inter-node-comms.sh
```

## What Each Script Does

### control-plane-firewall.sh

Protects the following control plane ports:

| Port | Service | Allowed Sources |
|------|---------|-----------------|
| 6443 | API Server | Control plane nodes, worker nodes, pod/service CIDRs, admin IPs |
| 2379 | etcd client | Control plane nodes only, localhost |
| 2380 | etcd peer | Control plane nodes only |
| 10259 | kube-scheduler | Localhost, control plane nodes |
| 10257 | kube-controller-manager | Localhost, control plane nodes |
| 10250 | Kubelet API | Control plane nodes |
| 9153 | CoreDNS metrics | Pod CIDR, control plane nodes |
| 53 | DNS (TCP/UDP) | Pod CIDR, service CIDR |

Default policy: INPUT DROP with logging (`K8S-CP-DROPPED:`), OUTPUT ACCEPT.

### worker-node-firewall.sh

Protects the following worker node ports:

| Port | Service | Allowed Sources |
|------|---------|-----------------|
| 10250 | Kubelet API | Control plane nodes, worker nodes |
| 10256 | kube-proxy health | Control plane nodes, localhost |
| 30000-32767 | NodePort range | All (or restricted via `NODEPORT_ALLOWED_SOURCES`) |
| CNI ports | Overlay network | All cluster nodes (see CNI section below) |
| 53 | DNS (TCP/UDP) | Pod CIDR |

Default policy: INPUT DROP with logging (`K8S-WORKER-DROPPED:`), OUTPUT ACCEPT.

### ssh-hardening.sh

Applies four layers of SSH protection:

1. **iptables rules** -- Restricts SSH to `ALLOWED_SSH_SOURCES` with rate limiting (max 5 new connections per 60 seconds per source)
2. **TCP wrappers** -- Configures `/etc/hosts.allow` and `/etc/hosts.deny` to restrict `sshd`
3. **sshd_config hardening** -- Applies the following settings:
   - `PermitRootLogin no`
   - `PasswordAuthentication no` (key-only)
   - `PubkeyAuthentication yes`
   - `MaxAuthTries 3`
   - `MaxSessions 3`
   - `LoginGraceTime 30`
   - `ClientAliveInterval 300` / `ClientAliveCountMax 2`
   - `X11Forwarding no`
   - `AllowTcpForwarding no`
   - `AllowAgentForwarding no`
   - `PermitEmptyPasswords no`
   - `PermitUserEnvironment no`
   - Warning banner at `/etc/ssh/banner`
4. **fail2ban** (optional, `SETUP_FAIL2BAN=true`) -- Bans IPs after 3 failed attempts for 1 hour

The script validates `sshd_config` with `sshd -t` before restarting and automatically restores the backup if validation fails.

### inter-node-comms.sh

Secures the communication channels between nodes:

- **Kubelet <-> API Server** -- Limits traffic to cluster members only; role-aware rules based on `NODE_ROLE` (auto-detected or manually set)
- **etcd peer traffic** -- Restricted to control plane nodes; workers are explicitly blocked with DROP rules
- **CNI overlay** -- Allows overlay traffic only between cluster nodes, drops from external sources
- **FORWARD chain** -- Permits pod-to-pod and pod-to-service forwarding within cluster CIDRs; drops and logs non-cluster forwarded traffic (`K8S-FWD-DROPPED:`)
- **Management port lockdown** -- All K8s management ports are blocked for non-cluster sources with per-port logging (`K8S-INTERNODE-DENY[port]:`)

## CNI Plugin Support

| Plugin | Ports Opened | Protocol |
|--------|-------------|----------|
| Flannel | 8472 | UDP (VXLAN) |
| Calico | 179 (BGP), 5473 (Typha) | TCP + IP-in-IP (protocol 4) |
| Weave | 6783 (TCP), 6784 (UDP) | TCP + UDP |

Set the `CNI_PLUGIN` variable to match your cluster's CNI. The default is `flannel`. All CNI ports are restricted to cluster node IPs only.

## Custom iptables Chains

The scripts organize rules into named chains for easier auditing and management:

| Chain | Created by | Purpose |
|-------|-----------|---------|
| `K8S-CONTROL-PLANE` | control-plane-firewall.sh | All control plane service rules |
| `K8S-SSH-ACCESS` | control-plane/worker-firewall.sh | SSH source filtering |
| `K8S-WORKER` | worker-node-firewall.sh | All worker node service rules |
| `K8S-NODEPORTS` | worker-node-firewall.sh | NodePort access filtering |
| `K8S-CNI` | worker-node-firewall.sh | CNI overlay port rules |
| `K8S-SSH-HARDENED` | ssh-hardening.sh | SSH with rate limiting |
| `K8S-INTERNODE` | inter-node-comms.sh | Inter-node traffic filtering |
| `K8S-FORWARD-FILTER` | inter-node-comms.sh | FORWARD chain pod traffic |

List rules in a specific chain:

```bash
sudo iptables -L K8S-CONTROL-PLANE -n -v --line-numbers
```

## Backups and Rollback

Every script automatically backs up iptables rules before making changes:

```
/var/backups/iptables/iptables-backup-YYYYMMDD_HHMMSS.rules
```

`ssh-hardening.sh` also backs up `sshd_config`:

```
/etc/ssh/sshd_config.bak.YYYYMMDD_HHMMSS
```

To restore from a backup:

```bash
# Restore iptables rules
sudo iptables-restore < /var/backups/iptables/iptables-backup-YYYYMMDD_HHMMSS.rules

# Restore sshd_config
sudo cp /etc/ssh/sshd_config.bak.YYYYMMDD_HHMMSS /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl restart sshd
```

To flush all rules and reset to defaults:

```bash
sudo iptables -F
sudo iptables -X
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT
```

## Rule Persistence

Rules are automatically persisted after application:

- **Debian/Ubuntu**: via `netfilter-persistent save` or written to `/etc/iptables/rules.v4`
- **RHEL/CentOS**: written to `/etc/sysconfig/iptables`

If auto-persistence fails, a warning is logged. Save manually:

```bash
sudo iptables-save > /etc/iptables/rules.v4      # Debian/Ubuntu
sudo iptables-save > /etc/sysconfig/iptables      # RHEL/CentOS
```

## Logging

All scripts log dropped packets with identifiable prefixes for easy filtering:

| Log Prefix | Source |
|------------|--------|
| `K8S-CP-DROPPED:` | Control plane firewall -- unmatched inbound traffic |
| `K8S-WORKER-DROPPED:` | Worker firewall -- unmatched inbound traffic |
| `SSH-DENIED:` | SSH hardening -- denied SSH connection attempt |
| `K8S-FWD-DROPPED:` | Inter-node -- non-cluster forwarded traffic |
| `K8S-INTERNODE-DENY[port]:` | Inter-node -- blocked management port access |

View dropped packets in real time:

```bash
sudo journalctl -f -k | grep "K8S-"
# or
sudo tail -f /var/log/kern.log | grep "K8S-"
```

## Troubleshooting

### Locked out of SSH

If you lose SSH access after running the scripts:

1. Access the node via out-of-band console (cloud provider console, IPMI, physical access)
2. Flush the iptables rules: `iptables -F && iptables -X && iptables -P INPUT ACCEPT`
3. Restore the sshd_config backup if modified: `cp /etc/ssh/sshd_config.bak.* /etc/ssh/sshd_config && systemctl restart sshd`

**Prevention**: Always run with `DRY_RUN=true` first and verify your `ALLOWED_SSH_SOURCES` includes your current IP.

### Nodes cannot communicate

Check that `CONTROL_PLANE_IPS` and `WORKER_NODE_IPS` contain the correct IPs (the IPs nodes use to communicate with each other, not public IPs if you are behind NAT).

```bash
# Verify what rules are active
sudo iptables -L -n -v --line-numbers

# Check a specific chain
sudo iptables -L K8S-INTERNODE -n -v

# Test connectivity from another node
nc -zv <target-ip> 6443    # API server
nc -zv <target-ip> 10250   # kubelet
```

### Pod networking broken

Ensure `POD_CIDR` and `SERVICE_CIDR` match your cluster configuration:

```bash
kubectl cluster-info dump | grep -m 1 cluster-cidr
kubectl cluster-info dump | grep -m 1 service-cluster-ip-range
```

Ensure `CNI_PLUGIN` matches your actual CNI. Check if FORWARD rules are correct:

```bash
sudo iptables -L FORWARD -n -v --line-numbers
sudo iptables -L K8S-FORWARD-FILTER -n -v
```

### NodePorts unreachable

By default, NodePorts (30000-32767) are open to all sources. If you set `NODEPORT_ALLOWED_SOURCES`, verify it includes your load balancer or client IPs.

## Security Notes

- All scripts use a default-deny INPUT policy. Only explicitly allowed traffic is accepted.
- OUTPUT is set to ACCEPT because nodes need outbound access (container registries, DNS, package repos). Restrict OUTPUT manually if your environment requires it.
- etcd is the most sensitive component and is locked to control plane peers only. Workers never have access.
- The scripts do not configure TLS. Kubernetes components should already use TLS for all communication (kubeadm sets this up by default). These firewall rules are a defense-in-depth layer.
- Regularly audit the active rules: `sudo iptables -L -n -v --line-numbers`
