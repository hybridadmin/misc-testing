#!/usr/bin/env bash
# =============================================================================
# 04-init-control-plane.sh - Initialize the K8s control plane with kubeadm
# =============================================================================
# Run on: CONTROL PLANE node only
# Run as: root (sudo -E ./04-init-control-plane.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

require_root
require_var "CONTROL_PLANE_IP"

log_step "Step 4: Initialize Control Plane"

# ---- Check if already initialized -------------------------------------------
if [[ -f /etc/kubernetes/admin.conf ]]; then
    log_warn "Cluster appears to be already initialized (/etc/kubernetes/admin.conf exists)."
    log_warn "If you want to reinitialize, run: kubeadm reset -f"
    read -rp "Continue anyway? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        exit 0
    fi
fi

# ---- Generate kubeadm config ------------------------------------------------
log_info "Generating kubeadm configuration..."

cat > "${CONFIGS_DIR}/kubeadm-config.yaml" <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${CONTROL_PLANE_IP}"
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  taints:
    - key: "node-role.kubernetes.io/control-plane"
      effect: "NoSchedule"
skipPhases: []
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: "${CLUSTER_NAME}"
kubernetesVersion: "v${K8S_VERSION_FULL}"
controlPlaneEndpoint: "${CONTROL_PLANE_IP}:6443"
networking:
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SERVICE_CIDR}"
  dnsDomain: "${DNS_DOMAIN}"
apiServer:
  extraArgs:
    - name: audit-log-path
      value: /var/log/kubernetes/audit.log
    - name: audit-log-maxage
      value: "30"
    - name: audit-log-maxbackup
      value: "10"
    - name: audit-log-maxsize
      value: "100"
    - name: event-ttl
      value: "12h"
    - name: anonymous-auth
      value: "false"
    - name: profiling
      value: "false"
    - name: enable-admission-plugins
      value: "NodeRestriction,PodSecurity"
    - name: encryption-provider-config
      value: /etc/kubernetes/encryption-config.yaml
  extraVolumes:
    - name: audit-log
      hostPath: /var/log/kubernetes
      mountPath: /var/log/kubernetes
      readOnly: false
      pathType: DirectoryOrCreate
    - name: encryption-config
      hostPath: /etc/kubernetes/encryption-config.yaml
      mountPath: /etc/kubernetes/encryption-config.yaml
      readOnly: true
      pathType: File
controllerManager:
  extraArgs:
    - name: profiling
      value: "false"
    - name: terminated-pod-gc-threshold
      value: "100"
    - name: bind-address
      value: "0.0.0.0"
scheduler:
  extraArgs:
    - name: profiling
      value: "false"
    - name: bind-address
      value: "0.0.0.0"
etcd:
  local:
    extraArgs:
      - name: listen-metrics-urls
        value: "http://0.0.0.0:2381"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
protectKernelDefaults: true
readOnlyPort: 0
eventRecordQPS: 5
rotateCertificates: true
serverTLSBootstrap: true
tlsMinVersion: "VersionTLS12"
tlsCipherSuites:
  - "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
  - "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
  - "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
  - "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "ipvs"
ipvs:
  strictARP: true
EOF

log_info "kubeadm config written to ${CONFIGS_DIR}/kubeadm-config.yaml"

# ---- Create encryption config for etcd secrets at rest -----------------------
log_info "Creating etcd encryption configuration..."
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

cat > /etc/kubernetes/encryption-config.yaml <<EOF
---
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF

chmod 600 /etc/kubernetes/encryption-config.yaml
log_info "Encryption config created (secrets + configmaps encrypted at rest)."

# ---- Create audit log directory ----------------------------------------------
mkdir -p /var/log/kubernetes
chmod 750 /var/log/kubernetes

# ---- Preflight check --------------------------------------------------------
log_info "Running kubeadm preflight checks..."
kubeadm init phase preflight --config="${CONFIGS_DIR}/kubeadm-config.yaml" || {
    log_error "Preflight checks failed. Fix the issues above and re-run."
    exit 1
}

# ---- Initialize cluster ------------------------------------------------------
log_info "Initializing Kubernetes control plane... (this may take 2-5 minutes)"

kubeadm init --config="${CONFIGS_DIR}/kubeadm-config.yaml" \
    --upload-certs \
    | tee "${CONFIGS_DIR}/kubeadm-init-output.log"

# ---- Configure kubectl for root and the calling user -------------------------
log_info "Configuring kubectl access..."

# For root
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config
chmod 600 /root/.kube/config

# For the user who invoked sudo
SUDO_USER_HOME=$(eval echo "~${SUDO_USER:-root}")
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    mkdir -p "${SUDO_USER_HOME}/.kube"
    cp /etc/kubernetes/admin.conf "${SUDO_USER_HOME}/.kube/config"
    chown "$(id -u "$SUDO_USER"):$(id -g "$SUDO_USER")" "${SUDO_USER_HOME}/.kube/config"
    chmod 600 "${SUDO_USER_HOME}/.kube/config"
    log_info "kubectl configured for user '$SUDO_USER'."
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

# ---- Extract join command for workers ----------------------------------------
log_info "Extracting worker join command..."
JOIN_CMD=$(kubeadm token create --print-join-command 2>/dev/null)
echo "$JOIN_CMD" > "${CONFIGS_DIR}/worker-join-command.sh"
chmod 600 "${CONFIGS_DIR}/worker-join-command.sh"
log_info "Join command saved to ${CONFIGS_DIR}/worker-join-command.sh"
log_warn "This file contains a secret token. Transfer it securely to the worker node."

# ---- Wait for API server -----------------------------------------------------
log_info "Waiting for API server to respond..."
for i in $(seq 1 30); do
    if kubectl get --raw /healthz &>/dev/null; then
        log_info "API server is healthy."
        break
    fi
    sleep 2
done

# ---- Verify ------------------------------------------------------------------
echo ""
log_info "=== Control Plane initialized ==="
kubectl get nodes -o wide
echo ""
kubectl cluster-info
echo ""
log_info "Next: run 05-cni-calico.sh (on control plane)"
log_info "Then: copy ${CONFIGS_DIR}/worker-join-command.sh to the worker and run 06-join-worker.sh"
