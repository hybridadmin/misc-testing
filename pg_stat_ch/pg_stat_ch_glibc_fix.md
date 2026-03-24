# pg_stat_ch GLIBC_2.36 Load Failure

## Error

```
ERROR:  could not load library "/usr/pgsql-18/lib/pg_stat_ch.so": /lib64/libc.so.6: version `GLIBC_2.36' not found (required by /usr/pgsql-18/lib/pg_stat_ch.so)
```

The `pg_stat_ch.so` extension was compiled against glibc >= 2.36, but the container's glibc is older (likely glibc 2.28 on EL8/UBI8).

## Environment

- PostgreSQL 18 container running in Kubernetes (`reference-systest-psql-pgha1-7mk9-0`)
- Container has a read-only or minimal filesystem (`microdnf update` fails with `error: Failed to create: /var/cache/yum/metadata`)
- Base image likely EL8/UBI8 (glibc 2.28)

## Diagnosis

```bash
# Check system glibc version
rpm -q glibc
ldd --version

# Check what the .so requires
objdump -p /usr/pgsql-18/lib/pg_stat_ch.so | grep GLIBC
```

## Solutions

### Option A: Rebase container image on a distro with glibc >= 2.36

RHEL 9 / UBI9 ships glibc 2.34, which is still **not sufficient** (the .so requires 2.36). Rebasing to EL9 alone will not fix this. You would need a distro that ships glibc >= 2.36, such as Fedora 36+, Debian 12 (Bookworm), or Ubuntu 22.10+. Alternatively, combine an EL9 base with Option B (rebuild from source).

### Option B: Rebuild pg_stat_ch from source in the image (Recommended)

Build the extension during the Docker image build so it links against the base image's glibc:

```bash
microdnf install -y gcc make postgresql18-devel
cd /path/to/pg_stat_ch_source
make PG_CONFIG=/usr/pgsql-18/bin/pg_config clean all
make PG_CONFIG=/usr/pgsql-18/bin/pg_config install
```

### Option C: Install the correct binary package

Ensure the `pg_stat_ch` RPM/package matches the base OS version. An EL9-built package will not work on an EL8 base. Use the EL8 variant if staying on UBI8.

## Notes

- Do **not** manually upgrade glibc inside the container -- it will break the system.
- Do **not** patch running containers in Kubernetes -- changes are lost on pod restart. All fixes must be applied at the image build level.
- The `microdnf update` failure (`/var/cache/yum/metadata`) is expected in minimal/read-only container filesystems. Creating the directory (`mkdir -p /var/cache/yum/metadata`) may work if the filesystem is writable, but this is a workaround, not a solution.
