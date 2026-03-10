# PostgreSQL RDS Terraform Module

Deploys a fully configured AWS RDS PostgreSQL instance with support for multiple engine versions, read replicas, enhanced monitoring, CloudWatch alarms, and multi-environment deployments via Terragrunt.

---

## Architecture

```
                     ┌─────────────────────────────────────────────┐
                     │                    VPC                      │
                     │                                             │
                     │   ┌──────────────┐    ┌──────────────┐     │
                     │   │  Private      │    │  Private      │    │
                     │   │  Subnet A     │    │  Subnet B     │    │
                     │   │               │    │               │    │
                     │   │  ┌─────────┐  │    │  ┌─────────┐  │   │
                     │   │  │ Primary │  │    │  │ Standby │  │   │
                     │   │  │   RDS   │◄─┼────┼─►│  (M-AZ) │  │   │
                     │   │  └─────────┘  │    │  └─────────┘  │   │
                     │   │       │       │    │               │   │
                     │   │       ▼       │    │  ┌─────────┐  │   │
                     │   │  ┌─────────┐  │    │  │  Read   │  │   │
                     │   │  │ Replica │  │    │  │ Replica │  │   │
                     │   │  └─────────┘  │    │  └─────────┘  │   │
                     │   └──────────────┘    └──────────────┘    │
                     │                                             │
                     │   Security Group (port 5432)                │
                     └─────────────────────────────────────────────┘
                                          │
              ┌───────────────────────────┼───────────────────────────┐
              ▼                           ▼                           ▼
     ┌─────────────────┐      ┌─────────────────┐       ┌─────────────────┐
     │  Secrets Manager │      │   CloudWatch     │       │  Performance    │
     │  (master pass)   │      │   Logs + Alarms  │       │  Insights       │
     └─────────────────┘      └─────────────────┘       └─────────────────┘
```

---

## Directory Structure

```
pg_rds/
├── terragrunt.hcl                                  # Root config (backend, provider, versions)
├── _envcommon/
│   └── pg_rds.hcl                                  # Shared module source and default inputs
├── modules/pg_rds/                                 # Terraform module
│   ├── versions.tf                                 # Terraform and provider constraints
│   ├── variables.tf                                # All input variables (~40 variables)
│   ├── locals.tf                                   # Naming, tags, best-practice PG parameters
│   ├── main.tf                                     # Subnet group, parameter group, RDS instance, replicas
│   ├── security.tf                                 # Security group with CIDR and SG ingress rules
│   ├── monitoring.tf                               # Enhanced Monitoring IAM role, CloudWatch alarms
│   └── outputs.tf                                  # 20+ outputs
├── environments/
│   ├── dev/
│   │   ├── env.hcl                                 # Dev environment variables
│   │   └── us-east-1/pg_rds/terragrunt.hcl         # Leaf deployment
│   ├── staging/
│   │   ├── env.hcl                                 # Staging environment variables
│   │   └── us-east-1/pg_rds/terragrunt.hcl         # Leaf deployment
│   └── prod/
│       ├── env.hcl                                 # Production environment variables
│       └── us-east-1/pg_rds/terragrunt.hcl         # Leaf deployment
└── README.md
```

---

## Prerequisites

| Requirement           | Version   |
|-----------------------|-----------|
| Terraform             | >= 1.5.0  |
| AWS Provider          | >= 5.0    |
| Terragrunt            | >= 0.50   |

Before deploying, ensure:

1. **VPC and subnets** exist (at least 2 private subnets across different AZs).
2. **S3 bucket and DynamoDB table** exist for Terraform remote state (Terragrunt can auto-create these).
3. **IAM execution role** (`<project>-terraform-execution`) exists in the target account for Terragrunt's `assume_role`.
4. **SNS topics** exist if you want CloudWatch alarm notifications.

---

## Quick Start

### 1. Configure environment variables

Edit the `env.hcl` file for your target environment. At minimum, replace the placeholder values:

```hcl
# environments/dev/env.hcl
locals {
  project    = "myproject"
  account_id = "123456789012"          # Your AWS account ID

  vpc_id     = "vpc-0abc123def456789"  # Your VPC ID
  subnet_ids = [                        # Your private subnet IDs
    "subnet-0abc123def456789a",
    "subnet-0abc123def456789b",
  ]
}
```

### 2. Deploy with Terragrunt

```bash
cd environments/dev/us-east-1/pg_rds

# Preview changes
terragrunt plan

# Apply
terragrunt apply
```

### 3. Retrieve connection info

```bash
# Get the endpoint
terragrunt output db_instance_endpoint

# Get all connection details
terragrunt output connection_info

# Get the Secrets Manager ARN for the master password
terragrunt output db_instance_master_user_secret_arn
```

---

## Supported PostgreSQL Versions

The module supports any RDS-available PostgreSQL version. The parameter group family is automatically derived from the major version number.

| `engine_version` | Derived `family` |
|-------------------|-------------------|
| `14.10`, `14.x`  | `postgres14`      |
| `15.5`, `15.x`   | `postgres15`      |
| `16.1`, `16.x`   | `postgres16`      |
| `17.x`           | `postgres17`      |

To deploy a specific version, set `engine_version` in your `env.hcl`:

```hcl
engine_version = "15.5"
```

Or override it per-region in the leaf `terragrunt.hcl`:

```hcl
inputs = {
  engine_version = "14.10"
}
```

---

## Environment Configuration Comparison

| Setting                       | Dev              | Staging          | Production        |
|-------------------------------|------------------|------------------|-------------------|
| **Instance class**            | `db.t3.micro`    | `db.t3.medium`   | `db.r6g.large`    |
| **Storage (initial/max)**     | 20 / 50 GiB      | 50 / 200 GiB     | 100 / 500 GiB     |
| **Multi-AZ**                  | Disabled         | Enabled          | Enabled           |
| **Backup retention**          | 3 days           | 7 days           | 35 days           |
| **Final snapshot on delete**  | Skipped          | Required         | Required          |
| **Deletion protection**       | Off              | On               | On                |
| **Monitoring interval**       | 60s              | 30s              | 5s                |
| **Performance Insights**      | 7 days           | 7 days           | 31 days           |
| **CloudWatch alarms**         | Off              | On               | On                |
| **Read replicas**             | None             | None             | 1                 |
| **Blue/green deployments**    | Off              | Off              | On                |
| **Apply immediately**         | Yes              | No               | No                |
| **Auto minor upgrades**       | Yes              | Yes              | No                |

---

## Module Variables Reference

### General

| Variable             | Type          | Default      | Description                                       |
|----------------------|---------------|--------------|---------------------------------------------------|
| `project`            | `string`      | **required** | Project name (lowercase alphanumeric + hyphens).   |
| `environment`        | `string`      | **required** | Environment: `dev`, `staging`, `prod`, `uat`, `qa`, `sandbox`. |
| `service`            | `string`      | `"postgres"` | Service name for resource naming.                  |
| `tags`               | `map(string)` | `{}`         | Additional tags merged with defaults.              |

### Networking

| Variable                     | Type           | Default | Description                                           |
|------------------------------|----------------|---------|-------------------------------------------------------|
| `vpc_id`                     | `string`       | **required** | VPC ID for the RDS security group.               |
| `subnet_ids`                 | `list(string)` | **required** | Private subnet IDs (minimum 2).                  |
| `allowed_cidr_blocks`        | `list(string)` | `[]`    | CIDR blocks allowed to connect.                       |
| `allowed_security_group_ids` | `list(string)` | `[]`    | Security group IDs allowed to connect.                |

### Engine

| Variable         | Type     | Default  | Description                                                      |
|------------------|----------|----------|------------------------------------------------------------------|
| `engine_version` | `string` | `"16.1"` | PostgreSQL version (e.g. `14.10`, `15.5`, `16.1`).              |
| `family`         | `string` | `""`     | Parameter group family. Auto-derived if empty.                    |

### Instance

| Variable              | Type     | Default        | Description                                      |
|-----------------------|----------|----------------|--------------------------------------------------|
| `instance_class`      | `string` | `"db.t3.micro"`| RDS instance class.                              |
| `allocated_storage`   | `number` | `20`           | Initial storage in GiB (20-65536).               |
| `max_allocated_storage`| `number`| `100`          | Max storage for autoscaling. `0` disables.       |
| `storage_type`        | `string` | `"gp3"`        | Storage type: `gp2`, `gp3`, `io1`, `io2`.       |
| `iops`                | `number` | `null`         | Provisioned IOPS (io1/io2/gp3 only).            |
| `storage_throughput`  | `number` | `null`         | Throughput in MiB/s (gp3 only).                  |
| `storage_encrypted`   | `bool`   | `true`         | Enable encryption at rest.                       |
| `kms_key_id`          | `string` | `""`           | Custom KMS key ARN for storage encryption.       |

### Database

| Variable                        | Type     | Default      | Description                                    |
|---------------------------------|----------|--------------|------------------------------------------------|
| `db_name`                       | `string` | `""`         | Default database name. Empty skips creation.   |
| `db_port`                       | `number` | `5432`       | Database port.                                 |
| `master_username`               | `string` | `"pgadmin"`  | Master username.                               |
| `manage_master_user_password`   | `bool`   | `true`       | Store password in Secrets Manager.             |
| `master_user_secret_kms_key_id` | `string` | `""`         | KMS key for the Secrets Manager secret.        |

### High Availability

| Variable            | Type                        | Default | Description                                |
|---------------------|-----------------------------|---------|--------------------------------------------|
| `multi_az`          | `bool`                      | `false` | Enable Multi-AZ standby.                   |
| `availability_zone` | `string`                    | `null`  | Preferred AZ for single-AZ deployments.    |
| `read_replicas`     | `map(object({...}))`        | `{}`    | Map of read replicas (see below).          |

#### Read replica object

```hcl
read_replicas = {
  reader1 = {
    instance_class      = "db.r6g.large"    # Optional, inherits from primary
    availability_zone   = "us-east-1b"      # Optional
    storage_encrypted   = true              # Default: true
    kms_key_id          = ""                # Default: inherits from primary
    publicly_accessible = false             # Default: false
    tags                = {}                # Default: {}
  }
}
```

### Backup & Recovery

| Variable                          | Type     | Default        | Description                                         |
|-----------------------------------|----------|----------------|-----------------------------------------------------|
| `backup_retention_period`         | `number` | `7`            | Days to retain backups (0-35).                      |
| `backup_window`                   | `string` | `"03:00-04:00"`| UTC backup window.                                  |
| `copy_tags_to_snapshot`           | `bool`   | `true`         | Copy tags to snapshots.                             |
| `delete_automated_backups`        | `bool`   | `true`         | Delete automated backups on instance deletion.      |
| `snapshot_identifier`             | `string` | `null`         | Restore from this snapshot ID.                      |
| `final_snapshot_identifier_prefix`| `string` | `"final"`      | Prefix for the final snapshot.                      |
| `skip_final_snapshot`             | `bool`   | `false`        | Skip final snapshot. Set `false` for production.    |

### Maintenance

| Variable                      | Type     | Default                  | Description                                |
|-------------------------------|----------|--------------------------|--------------------------------------------|
| `maintenance_window`          | `string` | `"Sun:05:00-Sun:06:00"`  | UTC maintenance window.                    |
| `auto_minor_version_upgrade`  | `bool`   | `true`                   | Auto-apply minor version upgrades.         |
| `allow_major_version_upgrade` | `bool`   | `false`                  | Allow major version upgrades.              |
| `apply_immediately`           | `bool`   | `false`                  | Apply changes immediately vs. next window. |

### Network & Access

| Variable              | Type     | Default                  | Description                                  |
|-----------------------|----------|--------------------------|----------------------------------------------|
| `publicly_accessible` | `bool`   | `false`                  | Expose to the internet. `false` for production.|
| `ca_cert_identifier`  | `string` | `"rds-ca-rsa2048-g1"`   | CA certificate identifier.                    |

### Monitoring & Logging

| Variable                                 | Type           | Default                    | Description                                       |
|------------------------------------------|----------------|----------------------------|---------------------------------------------------|
| `performance_insights_enabled`           | `bool`         | `true`                     | Enable Performance Insights.                      |
| `performance_insights_retention_period`  | `number`       | `7`                        | PI retention in days (7, 31, ..., 731).           |
| `performance_insights_kms_key_id`        | `string`       | `null`                     | KMS key for PI encryption.                        |
| `monitoring_interval`                    | `number`       | `60`                       | Enhanced Monitoring interval (0/1/5/10/15/30/60). |
| `monitoring_role_arn`                    | `string`       | `""`                       | Existing IAM role ARN. Auto-created if empty.     |
| `enabled_cloudwatch_logs_exports`        | `list(string)` | `["postgresql", "upgrade"]`| Log types to export.                              |
| `cloudwatch_log_group_retention_in_days` | `number`       | `30`                       | CloudWatch log retention.                         |
| `cloudwatch_log_group_kms_key_id`        | `string`       | `null`                     | KMS key for log encryption.                       |

### CloudWatch Alarms

| Variable                         | Type           | Default        | Description                                   |
|----------------------------------|----------------|----------------|-----------------------------------------------|
| `create_cloudwatch_alarms`       | `bool`         | `true`         | Create CloudWatch alarms.                     |
| `alarm_sns_topic_arns`           | `list(string)` | `[]`           | SNS topics for alarm notifications.           |
| `alarm_cpu_threshold`            | `number`       | `80`           | CPU utilization alarm threshold (%).          |
| `alarm_memory_threshold`         | `number`       | `134217728`    | Freeable memory alarm threshold (bytes, ~128 MiB). |
| `alarm_storage_threshold`        | `number`       | `2147483648`   | Free storage alarm threshold (bytes, ~2 GiB). |
| `alarm_read_latency_threshold`   | `number`       | `0.02`         | Read latency alarm threshold (seconds).       |
| `alarm_write_latency_threshold`  | `number`       | `0.05`         | Write latency alarm threshold (seconds).      |
| `alarm_connections_threshold`    | `number`       | `100`          | Database connections alarm threshold.         |

Six alarms are created when `create_cloudwatch_alarms = true`:

1. **CPU Utilization High** -- triggers when average CPU exceeds threshold for 15 minutes.
2. **Freeable Memory Low** -- triggers when available memory drops below threshold.
3. **Free Storage Low** -- triggers when remaining disk space drops below threshold.
4. **Read Latency High** -- triggers on sustained elevated read latency.
5. **Write Latency High** -- triggers on sustained elevated write latency.
6. **Database Connections High** -- triggers when connection count exceeds threshold.

### Parameter Group

| Variable                     | Type                         | Default | Description                              |
|------------------------------|------------------------------|---------|------------------------------------------|
| `parameter_group_parameters` | `list(object({name, value}))` | `[]`    | Additional PG parameters (see below).    |

### Security & Protection

| Variable                              | Type   | Default | Description                             |
|---------------------------------------|--------|---------|-----------------------------------------|
| `deletion_protection`                 | `bool` | `true`  | Prevent accidental deletion.            |
| `iam_database_authentication_enabled` | `bool` | `false` | Enable IAM database authentication.     |
| `blue_green_update_enabled`           | `bool` | `false` | Enable blue/green deployments.          |
| `identifier_override`                 | `string`| `""`   | Override auto-generated identifier.     |

---

## Best Practices Applied

### Security

- **Encryption at rest** enabled by default (`storage_encrypted = true`).
- **SSL enforcement** via the `rds.force_ssl = 1` parameter -- all client connections must use TLS.
- **Secrets Manager** manages the master password (`manage_master_user_password = true`) -- no plaintext passwords in state files.
- **Private subnets** by default (`publicly_accessible = false`).
- **Security group** with explicit ingress rules -- no default open access.

### Observability

- **pg_stat_statements** preloaded for query performance analysis.
- **Slow query logging** at 1000ms threshold (`log_min_duration_statement`).
- **DDL statement logging** tracks schema changes.
- **Connection and disconnection logging** for audit trails.
- **Checkpoint and lock-wait logging** for operational debugging.
- **Enhanced Monitoring** with auto-created IAM role.
- **Performance Insights** enabled by default.
- **CloudWatch log exports** for `postgresql` and `upgrade` logs.
- **CloudWatch alarms** covering CPU, memory, storage, latency, and connections.

### Reliability

- **Multi-AZ** available for automatic failover.
- **Read replicas** for horizontal read scaling.
- **Blue/green deployments** for safer upgrades.
- **Storage autoscaling** prevents running out of disk.
- **Automated backups** with configurable retention (up to 35 days).
- **Final snapshot** on deletion (enabled by default).
- **Deletion protection** enabled by default.

### Operations

- **`create_before_destroy`** on parameter groups prevents downtime during parameter changes.
- **`ignore_changes`** on `final_snapshot_identifier` prevents perpetual Terraform diffs.
- **Idle transaction timeout** (5 minutes) prevents long-running idle transactions from exhausting connections.
- **CloudWatch log groups** pre-created with configurable retention and optional KMS encryption.

---

## Default PostgreSQL Parameters

The module applies these best-practice parameters automatically. Override any of them by passing the same parameter name in `parameter_group_parameters`:

| Parameter                            | Default Value       | Apply Method    | Purpose                              |
|--------------------------------------|---------------------|-----------------|--------------------------------------|
| `log_connections`                    | `1`                 | immediate       | Log all connection attempts          |
| `log_disconnections`                 | `1`                 | immediate       | Log session terminations             |
| `log_checkpoints`                    | `1`                 | immediate       | Log checkpoint activity              |
| `log_lock_waits`                     | `1`                 | immediate       | Log lock wait events                 |
| `log_min_duration_statement`         | `1000` (ms)         | immediate       | Log queries taking > 1 second        |
| `log_statement`                      | `ddl`               | immediate       | Log DDL statements                   |
| `shared_preload_libraries`           | `pg_stat_statements`| pending-reboot  | Load pg_stat_statements extension    |
| `pg_stat_statements.track`           | `all`               | immediate       | Track all statements                 |
| `idle_in_transaction_session_timeout`| `300000` (ms)       | immediate       | Kill idle-in-transaction after 5 min |
| `rds.force_ssl`                      | `1`                 | immediate       | Require SSL connections              |

### Overriding defaults

To change a default parameter or add new ones:

```hcl
parameter_group_parameters = [
  {
    name         = "log_min_duration_statement"
    value        = "500"                          # Override: log queries > 500ms
    apply_method = "immediate"
  },
  {
    name         = "work_mem"
    value        = "65536"                        # Add: 64 MiB work_mem
    apply_method = "immediate"
  },
]
```

---

## Outputs Reference

| Output                             | Description                                                  |
|------------------------------------|--------------------------------------------------------------|
| `db_instance_id`                   | RDS instance identifier                                      |
| `db_instance_arn`                  | RDS instance ARN                                             |
| `db_instance_endpoint`             | Connection endpoint (`host:port`)                            |
| `db_instance_address`              | Hostname only                                                |
| `db_instance_port`                 | Port number                                                  |
| `db_instance_name`                 | Default database name                                        |
| `db_instance_username`             | Master username                                              |
| `db_instance_resource_id`          | Resource ID (for IAM auth policies)                          |
| `db_instance_status`               | Current instance status                                      |
| `db_instance_engine_version_actual`| Running engine version                                       |
| `db_instance_availability_zone`    | Deployed AZ                                                  |
| `db_instance_master_user_secret_arn`| Secrets Manager ARN for master password                     |
| `db_subnet_group_name`             | Subnet group name                                            |
| `db_subnet_group_arn`              | Subnet group ARN                                             |
| `security_group_id`                | Security group ID                                            |
| `security_group_arn`               | Security group ARN                                           |
| `db_parameter_group_name`          | Parameter group name                                         |
| `db_parameter_group_arn`           | Parameter group ARN                                          |
| `enhanced_monitoring_role_arn`     | Enhanced Monitoring IAM role ARN                             |
| `read_replica_endpoints`           | Map of replica endpoints (`{endpoint, address, port, arn}`)  |
| `cloudwatch_log_group_arns`        | Map of log group names to ARNs                               |
| `connection_info`                  | Convenience map (`{host, port, database, username, engine, version}`) |

---

## Multi-Region / Multi-Account Deployments

### Adding a new region

Create a new directory under the environment with the region name:

```bash
mkdir -p environments/prod/eu-west-1/pg_rds
```

Copy an existing leaf `terragrunt.hcl` and adjust as needed:

```bash
cp environments/prod/us-east-1/pg_rds/terragrunt.hcl \
   environments/prod/eu-west-1/pg_rds/terragrunt.hcl
```

The root `terragrunt.hcl` automatically extracts the region from the directory path.

### Adding a new account

Add an `account.hcl` file next to the region directory:

```
environments/prod/us-east-1/account.hcl
```

```hcl
locals {
  account_id = "999888777666"
}
```

This overrides the `account_id` from `env.hcl` for that specific deployment.

### Adding a new environment

1. Create the directory: `mkdir -p environments/uat`
2. Copy and customize `env.hcl` from an existing environment.
3. Create region/deployment directories as above.
4. Add the environment name to the `environment` variable validation in `variables.tf` if not already listed.

---

## Restoring from a Snapshot

To restore an RDS instance from an existing snapshot, set `snapshot_identifier` in the leaf `terragrunt.hcl`:

```hcl
inputs = {
  snapshot_identifier = "rds:myproject-prod-postgres-2025-01-15-03-00"
}
```

After the restore completes, remove `snapshot_identifier` to prevent Terraform from attempting to re-restore on subsequent applies.

---

## Upgrading PostgreSQL Versions

### Minor version upgrade

Set `auto_minor_version_upgrade = true` (default) and the upgrade applies during the next maintenance window. Or set the new `engine_version` explicitly and run `terragrunt apply`.

### Major version upgrade

1. Set `allow_major_version_upgrade = true` in inputs.
2. Set `engine_version` to the target version and update `family` if needed.
3. For production, enable `blue_green_update_enabled = true` for zero-downtime upgrades.
4. Run `terragrunt apply`.
5. After the upgrade completes, set `allow_major_version_upgrade = false` again.

---

## Resources Created

| Resource                            | Count     | Description                                    |
|-------------------------------------|-----------|------------------------------------------------|
| `aws_db_instance` (primary)        | 1         | Primary PostgreSQL RDS instance                |
| `aws_db_instance` (replicas)       | 0-N       | Read replicas (per `read_replicas` map)        |
| `aws_db_subnet_group`              | 1         | DB subnet group                                |
| `aws_db_parameter_group`           | 1         | Parameter group with best-practice defaults    |
| `aws_security_group`               | 1         | RDS security group                             |
| `aws_vpc_security_group_ingress_rule` | 0-N    | Ingress rules (CIDR + SG based)                |
| `aws_vpc_security_group_egress_rule`  | 1       | Egress rule (all outbound)                     |
| `aws_cloudwatch_log_group`         | 0-2       | Log groups for postgresql and upgrade logs     |
| `aws_iam_role`                     | 0-1       | Enhanced Monitoring IAM role (if needed)       |
| `aws_iam_role_policy_attachment`   | 0-1       | Monitoring role policy attachment               |
| `aws_cloudwatch_metric_alarm`      | 0-6       | CloudWatch alarms (if enabled)                 |

---

## Terragrunt Configuration Layers

```
┌─────────────────────────────────────────────────────────────┐
│ Root terragrunt.hcl                                         │
│   - S3 remote state with DynamoDB locking                   │
│   - AWS provider with assume_role                           │
│   - Provider version constraints                            │
│   - Common inputs (project, environment, service)           │
├─────────────────────────────────────────────────────────────┤
│ _envcommon/pg_rds.hcl                                       │
│   - Module source path                                      │
│   - Shared default inputs from env.hcl                      │
├─────────────────────────────────────────────────────────────┤
│ environments/<env>/env.hcl                                  │
│   - Account ID, VPC, subnets                                │
│   - Instance sizing, HA, backup settings                    │
│   - Monitoring and alarm configuration                      │
├─────────────────────────────────────────────────────────────┤
│ environments/<env>/<region>/pg_rds/terragrunt.hcl           │
│   - Includes root + envcommon                               │
│   - Per-deployment overrides (db_name, blue/green, etc.)    │
└─────────────────────────────────────────────────────────────┘
```

Values flow top-down. Lower layers override higher layers. The leaf `terragrunt.hcl` has the final say on all inputs.
