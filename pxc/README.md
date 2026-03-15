# Percona XtraDB Cluster - Certificate Verification Failure After Secret Deletion

## Error

```
[Galera] Failed to establish connection: certificate verify failed: self-signed certificate in certificate chain
```

This occurs after deleting old cert secrets and restarting the PXC cluster.

## Root Cause

Galera IST/SST SSL connections require all nodes to trust the same CA certificate. After deleting secrets:

1. The operator regenerates new secrets with a **new CA**
2. Some pods may still have the **old CA/certs** cached in their mounted volumes
3. Nodes can't verify each other because they're using certs signed by different CAs

## Fix - Rolling Restart All Nodes With Consistent Certs

### Step 1: Verify the current state of secrets

```bash
kubectl get secrets | grep -E 'ssl|tls|cert' | grep <cluster-name>
```

Check that the operator has regenerated all required secrets:

- `<cluster-name>-ssl` (Galera/replication certs)
- `<cluster-name>-ssl-internal` (internal node-to-node certs)

### Step 2: Ensure both ssl and ssl-internal secrets exist and are fresh

```bash
# Check creation timestamps - they should be recent and similar
kubectl get secret <cluster-name>-ssl -o jsonpath='{.metadata.creationTimestamp}'
kubectl get secret <cluster-name>-ssl-internal -o jsonpath='{.metadata.creationTimestamp}'
```

If either is missing, the operator should recreate it. If they have different timestamps, that's likely the problem - the CA is inconsistent.

### Step 3: Delete ALL cert secrets at once, then let the operator regenerate them together

```bash
# Scale down first to avoid split-brain
kubectl delete pxc <cluster-name>   # or scale replicas to 0

# Delete ALL TLS secrets so the operator regenerates them from the same new CA
kubectl delete secret <cluster-name>-ssl <cluster-name>-ssl-internal

# Re-apply / recreate the PXC cluster
kubectl apply -f <your-pxc-cr.yaml>
```

### Step 4: If the above doesn't work, force-delete pods and PVCs

The old certs may be baked into the persistent volumes:

```bash
# Delete the StatefulSet pods (they'll be recreated)
kubectl delete pods -l app.kubernetes.io/instance=<cluster-name>,app.kubernetes.io/component=pxc

# If pods keep failing, delete the PVCs too (DATA LOSS - only if you have backups)
# kubectl delete pvc -l app.kubernetes.io/instance=<cluster-name>,app.kubernetes.io/component=pxc
```

### Step 5: Verify certs are consistent across nodes

```bash
# Compare the CA on each pod
for pod in $(kubectl get pods -l app.kubernetes.io/component=pxc -o name); do
  echo "=== $pod ==="
  kubectl exec $pod -- openssl x509 -in /etc/mysql/ssl-internal/ca.crt -noout -fingerprint -sha256
done
```

All pods must show the **same CA fingerprint**.

## Key Takeaway

Always delete both `ssl` and `ssl-internal` secrets together, and ensure all pods are restarted **after** the operator regenerates them with the same CA. If you delete only one, or if pods restart before regeneration completes, you get a CA mismatch.

If using `cert-manager` with the operator, also ensure the `Issuer`/`Certificate` resources are cleaned up and re-issued consistently.
