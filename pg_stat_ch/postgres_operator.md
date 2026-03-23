# Adding pg_stat_ch to a Crunchy Data Postgres Operator Cluster

Yes, it is definitely possible to add a custom extension like `pg_stat_ch` to a Crunchy Data Postgres Operator (PGO) cluster. 

Because `pg_stat_ch` is a C-based extension that needs to be compiled against PostgreSQL, you cannot simply install it via a SQL command. The officially supported and most robust way to do this in Crunchy PGO is to **build a custom PostgreSQL container image** that includes the extension.

Here is the step-by-step process:

### 1. Create a Custom Dockerfile
You need to create a Dockerfile that uses the official Crunchy Data Postgres image as its base, installs the necessary build tools, compiles `pg_stat_ch`, installs it, and then cleans up.

```dockerfile
# Use your specific Crunchy Postgres version
FROM registry.developers.crunchydata.com/crunchydata/crunchy-postgres:ubi8-15.4-0

# Switch to root to install packages and compile
USER root

# Install build dependencies (adjust postgresqlXX-devel to match your PG version)
RUN dnf install -y gcc make git clang llvm-devel postgresql15-devel

# Clone, compile, and install the extension
RUN git clone https://github.com/ClickHouse/pg_stat_ch.git /tmp/pg_stat_ch && \
    cd /tmp/pg_stat_ch && \
    make USE_PGXS=1 && \
    make USE_PGXS=1 install

# Clean up build tools and temp files to reduce image size and improve security
RUN dnf remove -y gcc make git clang llvm-devel && \
    dnf clean all && \
    rm -rf /tmp/pg_stat_ch

# Switch back to the postgres user (Crunchy uses UID 26)
USER 26
```

### 2. Build and Push the Image
Build this image and push it to a container registry that your Kubernetes cluster can access.

```bash
docker build -t your-registry.com/your-repo/crunchy-postgres-pg_stat_ch:15.4-0 .
docker push your-registry.com/your-repo/crunchy-postgres-pg_stat_ch:15.4-0
```

### 3. Update your PostgresCluster Manifest
Modify your `PostgresCluster` Custom Resource (CR) to use your new custom image. 

Additionally, extensions like `pg_stat_ch` (similar to `pg_stat_statements`) almost always need to be loaded at startup via `shared_preload_libraries`. You configure this in the Patroni dynamic configuration block.

```yaml
apiVersion: postgres-operator.crunchydata.com/v1beta1
kind: PostgresCluster
metadata:
  name: my-cluster
spec:
  # 1. Update the image to your custom one
  image: your-registry.com/your-repo/crunchy-postgres-pg_stat_ch:15.4-0
  postgresVersion: 15
  instances:
    - name: instance1
      replicas: 2
      dataVolumeClaimSpec:
        accessModes: [ "ReadWriteOnce" ]
        resources:
          requests:
            storage: 10Gi
  patroni:
    dynamicConfiguration:
      postgresql:
        parameters:
          # 2. Add pg_stat_ch to shared_preload_libraries
          # (Make sure to keep pg_stat_statements if you are already using it)
          shared_preload_libraries: "pg_stat_statements, pg_stat_ch"
```

### 4. Create the Extension in PostgreSQL
Once the cluster has rolled out the new image and restarted with the updated `shared_preload_libraries`, you can connect to your database and enable the extension:

```sql
CREATE EXTENSION pg_stat_ch;
```

**Important Considerations:**
* **Image Updates:** Whenever Crunchy Data releases a new version of their Postgres image (e.g., for security patches), you will need to rebuild your custom image using their new image as the base.
* **Compatibility:** Ensure the PostgreSQL development headers (`postgresql15-devel` in the example) strictly match the PostgreSQL version of the base image.