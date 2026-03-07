# Bare-Metal Kubernetes Cluster

Production-ready Kubernetes cluster deployment on bare-metal hardware using Ansible and kubeadm.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Bare-Metal Cluster                       │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │  cp-01       │  │  worker-01   │  │  worker-02   │          │
│  │  Control     │  │              │  │              │          │
│  │  Plane       │  │  Workloads   │  │  Workloads   │          │
│  │  + etcd      │  │  + Longhorn  │  │  + Longhorn  │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
│                                                                 │
│  Networking: Calico CNI + MetalLB (L2) + NGINX Ingress         │
│  Storage:    Longhorn (replicated across workers)               │
│  Security:   PodSecurity admission, RBAC, audit logging         │
│  Certs:      cert-manager + Let's Encrypt                       │
│  Monitoring: Prometheus + Grafana + Alertmanager                │
│  GitOps:     ArgoCD                                             │
└─────────────────────────────────────────────────────────────────┘
```

## Components

| Layer | Component | Purpose |
|-------|-----------|---------|
| OS | Ubuntu 22.04/24.04 | Base operating system |
| Runtime | containerd | Container runtime (CRI) |
| K8s | kubeadm v1.31 | Cluster bootstrapping |
| CNI | Calico | Pod networking + network policy |
| LB | MetalLB | Bare-metal LoadBalancer (L2 mode) |
| Ingress | NGINX Ingress | HTTP routing + TLS termination |
| Storage | Longhorn | Distributed block storage |
| Certs | cert-manager | Automated TLS via Let's Encrypt |
| Monitoring | kube-prometheus-stack | Prometheus + Grafana + Alertmanager |
| GitOps | ArgoCD | Declarative continuous delivery |

## Prerequisites

**On your control machine (where you run Ansible):**
```bash
# Install Ansible
pip install ansible

# Install required collections
ansible-galaxy collection install ansible.posix
```

**On all target nodes:**
- Ubuntu 22.04 or 24.04 (fresh install)
- SSH access with key-based authentication
- User with passwordless sudo
- Minimum 2 CPU, 4 GB RAM per node (4 CPU / 8 GB recommended)
- Unique hostname, MAC address, and product_uuid per node
- Network connectivity between all nodes (same L2 segment for MetalLB)

## Quick Start

### 1. Configure inventory

Edit `inventory/hosts.yml` with your node IPs:

```yaml
all:
  children:
    control_plane:
      hosts:
        cp-01:
          ansible_host: 192.168.1.10
    workers:
      hosts:
        worker-01:
          ansible_host: 192.168.1.11
        worker-02:
          ansible_host: 192.168.1.12
```

### 2. Configure variables

Edit `inventory/group_vars/all.yml`:

```yaml
# MUST change these:
metallb_ip_range: "192.168.1.200-192.168.1.220"  # Unused IPs on your network
acme_email: "admin@yourdomain.com"
grafana_admin_password: "your-secure-password"

# Optional - adjust versions, CIDRs, etc.
```

### 3. Test connectivity

```bash
ansible all -m ping
```

### 4. Deploy the cluster

```bash
# Full deployment
ansible-playbook playbooks/site.yml

# Deploy with verbose output
ansible-playbook playbooks/site.yml -v
```

### 5. Access the cluster

```bash
# SSH to control plane and use kubectl
ssh ubuntu@192.168.1.10
kubectl get nodes

# Or copy kubeconfig locally
scp ubuntu@192.168.1.10:~/.kube/config ~/.kube/config-baremetal
export KUBECONFIG=~/.kube/config-baremetal
```

## Playbooks

| Playbook | Purpose | Command |
|----------|---------|---------|
| `site.yml` | Full cluster deploy | `ansible-playbook playbooks/site.yml` |
| `addons.yml` | Addons only (cluster exists) | `ansible-playbook playbooks/addons.yml` |
| `reset.yml` | Tear down cluster | `ansible-playbook playbooks/reset.yml` |

### Selective deployment with tags

```bash
# Only prepare nodes (OS + containerd)
ansible-playbook playbooks/site.yml --tags "prepare"

# Only deploy control plane + workers (skip addons)
ansible-playbook playbooks/site.yml --tags "control-plane,workers,cni"

# Only deploy specific addons
ansible-playbook playbooks/addons.yml --tags "monitoring,argocd"

# Deploy everything except monitoring
ansible-playbook playbooks/site.yml --skip-tags "monitoring"
```

## Project Structure

```
.
├── ansible.cfg                          # Ansible configuration
├── inventory/
│   ├── hosts.yml                        # Node inventory
│   └── group_vars/
│       ├── all.yml                      # Global variables
│       ├── control_plane.yml            # CP-specific vars
│       └── workers.yml                  # Worker-specific vars
├── playbooks/
│   ├── site.yml                         # Full cluster deploy
│   ├── addons.yml                       # Addons only
│   └── reset.yml                        # Cluster teardown
└── roles/
    ├── common/                          # OS prerequisites
    ├── containerd/                      # Container runtime
    ├── kubeadm-control-plane/           # CP init + kubeconfig
    ├── kubeadm-worker/                  # Worker join
    ├── cni-calico/                      # Pod networking
    ├── metallb/                         # LoadBalancer
    ├── ingress-nginx/                   # Ingress controller
    ├── longhorn/                        # Persistent storage
    ├── cert-manager/                    # TLS certificates
    ├── monitoring/                      # Prometheus + Grafana
    └── argocd/                          # GitOps
```

## Post-Install

### Access Grafana
```bash
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# Open http://localhost:3000 (admin / <grafana_admin_password>)
```

### Access ArgoCD
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
# Username: admin
# Password: printed during deployment, or:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

### Access Longhorn UI
```bash
kubectl port-forward svc/longhorn-frontend -n longhorn-system 8081:80
# Open http://localhost:8081
```

## Security Hardening Applied

- Swap disabled (kubelet requirement)
- Kernel modules: `overlay`, `br_netfilter` loaded
- Sysctl: bridge-nf-call, ip_forward enabled
- containerd: SystemdCgroup driver
- kubeadm: `PodSecurity` admission plugin enabled
- kubeadm: `NodeRestriction` admission plugin
- API server: audit logging enabled
- API server: profiling disabled
- etcd: metrics endpoint exposed for monitoring
- Core dumps disabled
- NTP synchronisation (chrony)
- Ingress: HSTS, TLS 1.2+, server tokens hidden
