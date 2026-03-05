# Restore PGO Cluster from Data Volume

Restore a CrunchyData PGO v6 PostgresCluster from an existing PersistentVolume
that was previously used by another PGO cluster. This handles the common case
where the source volume has WAL files that need to be replayed during recovery.

## Prerequisites

- CrunchyData PGO operator v6.0.0+ installed in the cluster
- The PersistentVolume (PV) from the source cluster is available and not bound
  to another PVC
- You know the PV name (e.g. `pvc-e7e2cf52-f0d8-4151-aaf5-6acd1bf9186a`)
- If you have additional WAL files for point-in-time recovery, they should
  already be placed in `/pgdata/pg16_wal` on the source volume

## Background

When restoring from a data volume that belonged to a PGO-managed cluster, two
issues prevent the new cluster from starting:

1. **`pg_wal` is a symlink.** PGO clusters that used a separate WAL volume have
   `pg_wal` as a symlink pointing to the WAL volume mount. In the new cluster
   there is no separate WAL volume, so the symlink is dangling and `realpath`
   fails during startup.

2. **`/pgdata/pg16_wal` already exists.** The PGO startup script runs
   `mv /pgdata/pg16/pg_wal /pgdata/pg16_wal` to relocate WAL outside PGDATA.
   This fails if `/pgdata/pg16_wal` already exists on the source volume.

A prep Job included in the manifest fixes both issues before the
PostgresCluster is created:

- Replaces the `pg_wal` symlink with a real directory
- Merges any WAL files from `/pgdata/pg16_wal` into `/pgdata/pg16/pg_wal`
  (preserving them for recovery)
- Removes the old `/pgdata/pg16_wal` directory so the startup `mv` succeeds

## Configuration

Edit `templates/cluster_from_datavol.yaml` and update the following values:

| Field | Description |
|---|---|
| PVC `metadata.name` | Name for the restore PVC |
| PVC `metadata.namespace` | Target namespace |
| PVC `spec.volumeName` | The PV name from the source cluster |
| PVC `spec.resources.requests.storage` | Must match or exceed the PV size |
| PostgresCluster `metadata.name` | Name for the new cluster |
| PostgresCluster `metadata.namespace` | Target namespace |
| `dataSource.volumes.pgDataVolume.pvcName` | Must match the PVC name above |
| Job `metadata.namespace` | Must match the target namespace |
| Job PVC `claimName` | Must match the PVC name above |

## Deployment Steps

The manifest uses a `step: prep` label to allow a two-phase apply. The PVC
and the fix Job are applied first, and the PostgresCluster is created only
after the Job completes.

### Step 1 — Apply the PVC and run the prep Job

```bash
kubectl apply -f templates/cluster_from_datavol.yaml -l step=prep
```

### Step 2 — Wait for the Job to complete

```bash
kubectl wait --for=condition=complete job/fix-pg-wal \
  -n rapidpro-systest --timeout=120s
```

Verify the Job output:

```bash
kubectl logs job/fix-pg-wal -n rapidpro-systest
```

You should see output similar to:

```
Checking pg_wal at /pgdata/pg16/pg_wal ...
pg_wal is a symlink (dangling), removing and creating real directory
Created real pg_wal directory
Merging WAL files from /pgdata/pg16_wal into /pgdata/pg16/pg_wal ...
Merged 42 WAL files
Removed /pgdata/pg16_wal
Done.
```

### Step 3 — Apply the full manifest (creates the PostgresCluster)

```bash
kubectl apply -f templates/cluster_from_datavol.yaml
```

### Step 4 — Verify the cluster is running

```bash
# Watch the instance pod start
kubectl get pods -n rapidpro-systest -l postgres-operator.crunchydata.com/cluster=rapidpro-systest-psql2 -w

# Check the startup logs
kubectl logs <pod-name> -n rapidpro-systest -c postgres-startup

# Check PostgreSQL is accepting connections
kubectl logs <pod-name> -n rapidpro-systest -c database
```

## Troubleshooting

### Re-running the restore

If you need to re-run the process (e.g. after a failed attempt), clean up
first:

```bash
kubectl delete postgrescluster rapidpro-systest-psql2 -n rapidpro-systest
kubectl delete job fix-pg-wal -n rapidpro-systest
```

Then start again from Step 1. The PVC will be re-used since it references
a specific PV by name.

### Job fails or times out

Check the Job logs and pod events:

```bash
kubectl logs job/fix-pg-wal -n rapidpro-systest
kubectl describe job fix-pg-wal -n rapidpro-systest
```

Common causes:
- PVC is not bound (PV doesn't exist or is already bound elsewhere)
- Permission errors (the Job runs as uid/gid 26 to match the postgres user
  in Crunchy images)

### `pg_wal` errors persist after the Job

Inspect the volume directly using a temporary pod:

```bash
kubectl apply -f test.yaml
kubectl exec -it pv-test-pod -n reference-systest -- sh
ls -la /data/pg16/
ls -la /data/pg16/pg_wal
ls -la /data/pg16_wal
```
