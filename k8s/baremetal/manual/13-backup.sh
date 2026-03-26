#!/usr/bin/env bash
# =============================================================================
# 13-backup.sh - Install Velero + etcd snapshot cron
# =============================================================================
# Run on: CONTROL PLANE node only
# Run as: root (sudo -E ./13-backup.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-env.sh"

require_root
require_kubeconfig

log_step "Step 13: Backup Configuration"

# =============================================================================
# Part 1: etcd snapshots (critical for single control-plane clusters)
# =============================================================================
log_info "Configuring etcd snapshot backups..."

mkdir -p "$ETCD_BACKUP_DIR"
chmod 700 "$ETCD_BACKUP_DIR"

# ---- Create etcd backup script -----------------------------------------------
cat > /usr/local/bin/etcd-backup.sh <<'BACKUP_SCRIPT'
#!/usr/bin/env bash
# etcd snapshot backup script - called by cron
set -euo pipefail

BACKUP_DIR="__ETCD_BACKUP_DIR__"
RETENTION_DAYS="__ETCD_BACKUP_RETENTION_DAYS__"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
SNAPSHOT_FILE="${BACKUP_DIR}/etcd-snapshot-${TIMESTAMP}.db"

# Take snapshot
ETCDCTL_API=3 etcdctl snapshot save "$SNAPSHOT_FILE" \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key

# Verify snapshot
ETCDCTL_API=3 etcdctl snapshot status "$SNAPSHOT_FILE" --write-out=table

# Compress
gzip "$SNAPSHOT_FILE"

# Remove old backups
find "$BACKUP_DIR" -name "etcd-snapshot-*.db.gz" -mtime +"$RETENTION_DAYS" -delete

echo "[$(date '+%Y-%m-%d %H:%M:%S')] etcd backup complete: ${SNAPSHOT_FILE}.gz"
BACKUP_SCRIPT

# Substitute variables
sed -i "s|__ETCD_BACKUP_DIR__|${ETCD_BACKUP_DIR}|g" /usr/local/bin/etcd-backup.sh
sed -i "s|__ETCD_BACKUP_RETENTION_DAYS__|${ETCD_BACKUP_RETENTION_DAYS}|g" /usr/local/bin/etcd-backup.sh
chmod 700 /usr/local/bin/etcd-backup.sh

# ---- Install etcdctl if not present ------------------------------------------
if ! command -v etcdctl &>/dev/null; then
    log_info "Installing etcdctl..."
    ETCD_VER=$(kubectl exec -n kube-system "etcd-$(hostname)" -- etcd --version 2>/dev/null | head -1 | awk '{print $3}' || echo "3.5.16")
    ARCH=$(dpkg --print-architecture)
    if [[ "$ARCH" == "amd64" ]]; then ETCD_ARCH="amd64"; else ETCD_ARCH="arm64"; fi

    curl -fsSL "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VER}/etcd-v${ETCD_VER}-linux-${ETCD_ARCH}.tar.gz" \
        | tar xz --strip-components=1 -C /usr/local/bin/ "etcd-v${ETCD_VER}-linux-${ETCD_ARCH}/etcdctl"
    chmod +x /usr/local/bin/etcdctl
    log_info "etcdctl v${ETCD_VER} installed."
fi

# ---- Schedule cron job -------------------------------------------------------
CRON_ENTRY="0 */6 * * * /usr/local/bin/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1"

# Remove old entry if present, then add new
(crontab -l 2>/dev/null | grep -v "etcd-backup.sh" || true; echo "$CRON_ENTRY") | crontab -

log_info "etcd backup cron job scheduled: every 6 hours."
log_info "Backup directory: $ETCD_BACKUP_DIR"
log_info "Retention: ${ETCD_BACKUP_RETENTION_DAYS} days"

# ---- Run initial backup now --------------------------------------------------
log_info "Running initial etcd backup..."
/usr/local/bin/etcd-backup.sh || log_warn "Initial backup failed. Check etcd connectivity."

# ---- Logrotate for backup log ------------------------------------------------
cat > /etc/logrotate.d/etcd-backup <<EOF
/var/log/etcd-backup.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF

# =============================================================================
# Part 2: Velero (K8s resource + PV backup)
# =============================================================================
log_info "Installing Velero..."

# Velero needs a backup storage location. For on-prem without S3,
# we use a local filesystem via a node-agent (restic) setup.
# For production, configure an S3-compatible backend (MinIO, etc.)

helm_repo_add vmware-tanzu https://vmware-tanzu.github.io/helm-charts

cat > "${CONFIGS_DIR}/velero-values.yaml" <<EOF
# Velero configuration for on-premises bare-metal
# By default uses filesystem backup (node-agent/restic)
# For S3-compatible storage, update the backupStorageLocation

configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: velero-backups
      default: true
      config:
        region: "local"
        s3ForcePathStyle: "true"
        # Uncomment and set when using MinIO or S3-compatible storage:
        # s3Url: "http://minio.minio-system.svc:9000"
  volumeSnapshotLocation:
    - name: default
      provider: aws
      config:
        region: "local"
  # Use node-agent for file-level backup of PVs
  uploaderType: restic

deployNodeAgent: true

# Credentials - create a secret or use IRSA
# For MinIO / local S3:
credentials:
  useSecret: true
  secretContents:
    cloud: |
      [default]
      aws_access_key_id = minioadmin
      aws_secret_access_key = minioadmin

initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.11.0
    volumeMounts:
      - mountPath: /target
        name: plugins

resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

schedules:
  daily-backup:
    disabled: false
    schedule: "0 2 * * *"
    template:
      ttl: "720h"
      includedNamespaces:
        - "*"
      excludedNamespaces:
        - kube-system
        - kube-public
        - kube-node-lease
      storageLocation: default
      defaultVolumesToFsBackup: true
EOF

log_warn "Velero requires an S3-compatible backend (e.g., MinIO) for full functionality."
log_warn "The Helm values at ${CONFIGS_DIR}/velero-values.yaml are a template."
log_warn "Update backupStorageLocation and credentials before installing."
log_info ""
log_info "To install Velero once you have configured S3 storage:"
log_info ""
log_info "  helm upgrade --install velero vmware-tanzu/velero \\"
log_info "    --version \"${VELERO_VERSION}\" \\"
log_info "    --namespace velero \\"
log_info "    --create-namespace \\"
log_info "    --values \"${CONFIGS_DIR}/velero-values.yaml\" \\"
log_info "    --wait"
log_info ""
log_info "Alternatively, install MinIO first:"
log_info "  helm repo add minio https://charts.min.io/"
log_info "  helm install minio minio/minio --namespace minio-system --create-namespace"
log_info "  Then update velero-values.yaml with the MinIO endpoint and credentials."

# =============================================================================
# Create manual backup/restore scripts
# =============================================================================

cat > /usr/local/bin/k8s-backup-resources.sh <<'RESOURCES_SCRIPT'
#!/usr/bin/env bash
# Quick K8s resource backup (all namespaces, YAML export)
set -euo pipefail
BACKUP_DIR="/var/backups/k8s-resources/$(date '+%Y%m%d_%H%M%S')"
mkdir -p "$BACKUP_DIR"

for resource in deployments services configmaps secrets ingresses persistentvolumeclaims \
                statefulsets daemonsets cronjobs jobs networkpolicies; do
    echo "Exporting $resource..."
    kubectl get "$resource" --all-namespaces -o yaml > "${BACKUP_DIR}/${resource}.yaml" 2>/dev/null || true
done

# Backup all namespaces
kubectl get namespaces -o yaml > "${BACKUP_DIR}/namespaces.yaml"

# Backup cluster-scoped resources
for resource in clusterroles clusterrolebindings storageclasses \
                persistentvolumes ingressclasses; do
    kubectl get "$resource" -o yaml > "${BACKUP_DIR}/${resource}.yaml" 2>/dev/null || true
done

echo "K8s resource backup saved to: $BACKUP_DIR"
RESOURCES_SCRIPT
chmod 700 /usr/local/bin/k8s-backup-resources.sh

# ---- Summary -----------------------------------------------------------------
echo ""
log_info "=== Backup Configuration complete ==="
echo ""
log_info "etcd snapshots:"
log_info "  Schedule:  every 6 hours (cron)"
log_info "  Location:  ${ETCD_BACKUP_DIR}/"
log_info "  Retention: ${ETCD_BACKUP_RETENTION_DAYS} days"
log_info "  Manual:    /usr/local/bin/etcd-backup.sh"
echo ""
log_info "K8s resource export:"
log_info "  Manual:    /usr/local/bin/k8s-backup-resources.sh"
echo ""
log_info "Velero:"
log_info "  Values:    ${CONFIGS_DIR}/velero-values.yaml (configure S3 backend first)"
echo ""
log_info "Next: run 14-verify.sh"
