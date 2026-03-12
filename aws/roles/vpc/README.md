# AWS VPC Terraform Module

Deploys a production-grade AWS VPC with three-tier subnet architecture (public, private, database), NAT gateways with environment-aware redundancy, restrictive Network ACLs, VPC flow logs, gateway endpoints for cost optimization, and multi-environment deployments via Terragrunt.

---

## Architecture

```
                          Internet
                             │
                             ▼
                    ┌────────────────┐
                    │ Internet       │
                    │ Gateway        │
                    └───────┬────────┘
                            │
          ┌─────────────────┼──────────────────┐
          │                 │                   │
          ▼                 ▼                   ▼
  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐
  │ Public        │ │ Public        │ │ Public        │
  │ Subnet AZ-a   │ │ Subnet AZ-b   │ │ Subnet AZ-c   │
  │               │ │               │ │               │
  │  NAT GW (*)  │ │  NAT GW (*)  │ │  NAT GW (*)  │
  └───────┬───────┘ └───────┬───────┘ └───────┬───────┘
          │                 │                   │
          ▼                 ▼                   ▼
  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐
  │ Private       │ │ Private       │ │ Private       │   NACL: VPC + ephemeral
  │ Subnet AZ-a   │ │ Subnet AZ-b   │ │ Subnet AZ-c   │   ingress only
  │ (Apps/ECS/EKS)│ │ (Apps/ECS/EKS)│ │ (Apps/ECS/EKS)│
  └───────┬───────┘ └───────┬───────┘ └───────┬───────┘
          │                 │                   │
          ▼                 ▼                   ▼
  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐
  │ Database      │ │ Database      │ │ Database      │   NACL: Private subnet
  │ Subnet AZ-a   │ │ Subnet AZ-b   │ │ Subnet AZ-c   │   DB ports only (ingress)
  │ (RDS/Aurora/  │ │ (RDS/Aurora/  │ │ (RDS/Aurora/  │   HTTPS+DNS only (egress)
  │  ElastiCache) │ │  ElastiCache) │ │  ElastiCache) │
  └───────────────┘ └───────────────┘ └───────────────┘

  (*) NAT Gateway count:
      Dev/Staging: 1 NAT (single_nat_gateway = true)  → ~$32/month
      Production:  3 NATs (single_nat_gateway = false) → ~$96/month

  ┌─────────────────────────────────────────────────────┐
  │  Gateway VPC Endpoints (free)                       │
  │  ├── S3         → eliminates NAT charges for S3     │
  │  └── DynamoDB   → eliminates NAT charges for DDB    │
  │                                                     │
  │  Interface VPC Endpoints (optional, ~$7.20/AZ/mo)   │
  │  ├── Secrets Manager → private secret rotation      │
  │  ├── SSM             → private Systems Manager      │
  │  └── ECR             → private image pulls          │
  └─────────────────────────────────────────────────────┘
```

---

## Directory Structure

```
vpc/
├── terragrunt.hcl                                      # Root config (backend, provider, versions)
├── _envcommon/
│   └── vpc.hcl                                         # Shared module source + default inputs
├── modules/vpc/                                        # Terraform module
│   ├── versions.tf                                     # Terraform and provider constraints
│   ├── variables.tf                                    # All input variables (~35 variables)
│   ├── locals.tf                                       # Naming, tags, computed values
│   ├── main.tf                                         # VPC, subnets, IGW, NAT GWs, route tables
│   ├── nacl.tf                                         # Network ACLs per subnet tier
│   ├── flow_logs.tf                                    # VPC flow logs (CloudWatch or S3)
│   ├── endpoints.tf                                    # Gateway + interface VPC endpoints
│   └── outputs.tf                                      # 30+ outputs
├── envs/
│   ├── dev/
│   │   ├── env.hcl                                     # Dev environment variables
│   │   └── eu-west-1/vpc/terragrunt.hcl                # Leaf deployment
│   ├── staging/
│   │   ├── env.hcl                                     # Staging environment variables
│   │   └── eu-west-1/vpc/terragrunt.hcl                # Leaf deployment
│   └── prod/
│       ├── env.hcl                                     # Production environment variables
│       └── eu-west-1/vpc/terragrunt.hcl                # Leaf deployment
├── README.md
└── PROMPT.md
```

---

## Prerequisites

| Requirement           | Version   |
|-----------------------|-----------|
| Terraform             | >= 1.5.0  |
| AWS Provider          | >= 5.0    |
| Terragrunt            | >= 0.50   |

Before deploying, ensure:

1. **S3 bucket and DynamoDB table** exist for Terraform remote state (Terragrunt can auto-create these).
2. **IAM execution role** (`<project>-terraform-execution`) exists in the target account for Terragrunt's `assume_role`.
3. **CIDR ranges** are planned and do not overlap with existing VPCs or on-premises networks.
4. **S3 bucket** exists if using S3 as the flow log destination (`flow_log_destination_type = "s3"`).

---

## Quick Start

### 1. Configure environment variables

Edit the `env.hcl` file for your target environment:

```hcl
# envs/dev/env.hcl
locals {
  project    = "myproject"
  account_id = "123456789012"          # Your AWS account ID

  cidr_block         = "10.0.0.0/16"
  availability_zones = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]

  public_subnet_cidrs   = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
  private_subnet_cidrs  = ["10.0.48.0/20", "10.0.64.0/20", "10.0.80.0/20"]
  database_subnet_cidrs = ["10.0.96.0/20", "10.0.112.0/20", "10.0.128.0/20"]

  single_nat_gateway = true   # false for production HA
}
```

### 2. Deploy with Terragrunt

```bash
cd envs/dev/eu-west-1/vpc

# Preview changes
terragrunt plan

# Apply
terragrunt apply
```

### 3. Retrieve outputs

```bash
# Get the VPC ID
terragrunt output vpc_id

# Get all subnet IDs
terragrunt output private_subnet_ids
terragrunt output database_subnet_ids

# Get full network info for downstream modules
terragrunt output network_info
```

---

## Security Model

### Three-Tier Network Isolation

| Tier     | Internet Ingress | Internet Egress | VPC Ingress       | VPC Egress |
|----------|------------------|-----------------|-------------------|------------|
| Public   | HTTP/HTTPS       | All             | All from VPC      | All        |
| Private  | None             | Via NAT         | All from VPC      | All        |
| Database | **None**         | Via NAT (*)     | DB ports from private only | HTTPS, DNS, ephemeral to private |

(*) Database egress via NAT is restricted by NACL to HTTPS (443), HTTP (80), and DNS (53) -- only what is needed for OS patching, secret rotation, and AWS API calls.

### Database Subnet NACL Rules

**Ingress (what can reach the database subnets):**

| Rule | Source              | Ports           | Purpose                        |
|------|---------------------|-----------------|--------------------------------|
| 100+ | Private subnet CIDRs | 5432,3306,6379 | Application → Database traffic |
| 200  | 0.0.0.0/0          | 1024-65535      | NAT return traffic (ephemeral) |

**Egress (what the database subnets can reach):**

| Rule | Destination         | Ports      | Purpose                              |
|------|---------------------|------------|--------------------------------------|
| 100  | 0.0.0.0/0          | 443        | HTTPS for AWS APIs, secret rotation  |
| 110  | 0.0.0.0/0          | 80         | HTTP for OS package updates          |
| 120+ | Private subnet CIDRs | 1024-65535| Query response to applications       |
| 130  | VPC CIDR           | 53 (UDP)   | DNS resolution                       |
| 131  | VPC CIDR           | 53 (TCP)   | DNS resolution (large responses)     |

### Key Security Features

- **No internet gateway route** on database or private subnets -- traffic is only routable via NAT.
- **Custom NACLs** provide defense-in-depth on top of security groups (stateless layer 3/4 filtering).
- **Database NACLs** explicitly deny everything not in the allow list -- no implicit allow-all.
- **VPC Flow Logs** capture all (or rejected) traffic for security analysis and compliance.
- **DNS support** enabled for VPC endpoint resolution and private hosted zones.
- **No public IPs** on private or database subnets.

---

## NAT Gateway Strategy

| Environment | NAT Count | Monthly Cost* | Availability | Rationale |
|-------------|-----------|---------------|--------------|-----------|
| Dev         | 1         | ~$32          | Single AZ    | Cost savings; dev tolerates brief outages |
| Staging     | 1         | ~$32          | Single AZ    | Cost savings; staging mirrors prod architecture but not HA |
| Production  | 3         | ~$96          | All AZs      | Full HA; if one AZ fails, others continue independently |

*Costs are for NAT gateway hourly charges only ($0.045/hr). Data processing charges ($0.045/GB) are additional but are reduced by gateway VPC endpoints.

### How Single vs Multi-NAT Works

**Single NAT (`single_nat_gateway = true`):**
- 1 NAT gateway in the first AZ
- 1 shared route table for all private and database subnets
- All outbound traffic routes through the single NAT

**Multi-NAT (`single_nat_gateway = false`):**
- 1 NAT gateway per AZ (3 total)
- 1 route table per AZ for private subnets, 1 per AZ for database subnets
- Each AZ's outbound traffic stays within its own AZ

---

## Cost Optimization

### Gateway VPC Endpoints (Always Enabled)

Gateway endpoints for S3 and DynamoDB are free and route traffic over the AWS backbone instead of through NAT gateways. This eliminates the $0.045/GB NAT data processing charge for these services.

**Estimated savings:** If your workload transfers 100 GB/month to S3, gateway endpoints save ~$4.50/month in NAT charges. For heavy workloads (1 TB/month), savings are ~$45/month.

### Flow Log Optimization by Environment

| Setting              | Dev       | Staging   | Production |
|----------------------|-----------|-----------|------------|
| Traffic type         | REJECT    | ALL       | ALL        |
| Retention            | 7 days    | 14 days   | 90 days    |
| Aggregation interval | 600s      | 600s      | 60s        |

- **REJECT-only** in dev reduces CloudWatch Logs ingestion costs by capturing only denied traffic.
- **600-second aggregation** in dev/staging reduces the number of log records published.
- **60-second aggregation** in production provides near real-time visibility for incident response.

### Other Cost Considerations

- **Interface VPC endpoints** (~$7.20/month per AZ per endpoint) should only be enabled when required by security policy or to avoid NAT for high-volume services.
- **Dedicated tenancy** (`instance_tenancy = "dedicated"`) carries a significant cost premium -- only use if compliance requires it.
- **Secondary CIDRs** are free but consider whether you genuinely need them before adding address space.

---

## Environment Configuration Comparison

| Setting                        | Dev           | Staging       | Production     |
|--------------------------------|---------------|---------------|----------------|
| **VPC CIDR**                   | 10.0.0.0/16   | 10.1.0.0/16   | 10.2.0.0/16   |
| **Subnet size**                | /20 (4094 IPs)| /20 (4094 IPs)| /20 (4094 IPs) |
| **NAT gateways**               | 1 (shared)    | 1 (shared)    | 3 (per-AZ)    |
| **Flow log traffic**           | REJECT only   | ALL           | ALL            |
| **Flow log retention**         | 7 days        | 14 days       | 90 days        |
| **Flow log aggregation**       | 600s          | 600s          | 60s            |
| **Custom NACLs**               | Yes           | Yes           | Yes            |
| **S3 endpoint**                | Yes (free)    | Yes (free)    | Yes (free)     |
| **DynamoDB endpoint**          | Yes (free)    | Yes (free)    | Yes (free)     |
| **Interface endpoints**        | No            | No            | Optional       |
| **DB subnet group**            | Yes           | Yes           | Yes            |

---

## Variables Reference

### General

| Variable              | Type          | Default      | Description                                       |
|-----------------------|---------------|--------------|---------------------------------------------------|
| `project`             | `string`      | **required** | Project name (lowercase alphanumeric + hyphens)    |
| `environment`         | `string`      | **required** | Environment: dev, staging, prod, uat, qa, sandbox  |
| `service`             | `string`      | `"network"`  | Service name for resource naming                   |
| `tags`                | `map(string)` | `{}`         | Additional tags merged with defaults               |

### VPC

| Variable                | Type           | Default     | Description                                    |
|-------------------------|----------------|-------------|------------------------------------------------|
| `cidr_block`            | `string`       | **required**| Primary IPv4 CIDR block (/16 to /28)           |
| `secondary_cidr_blocks` | `list(string)` | `[]`        | Additional CIDR blocks                         |
| `enable_dns_support`    | `bool`         | `true`      | Enable VPC DNS resolution                      |
| `enable_dns_hostnames`  | `bool`         | `true`      | Enable VPC DNS hostnames                       |
| `instance_tenancy`      | `string`       | `"default"` | Instance tenancy (default or dedicated)        |

### Availability Zones

| Variable             | Type           | Default      | Description                                   |
|----------------------|----------------|--------------|-----------------------------------------------|
| `availability_zones` | `list(string)` | **required** | Exactly 3 AZs for subnet placement            |

### Subnets

| Variable                            | Type           | Default      | Description                                    |
|-------------------------------------|----------------|--------------|------------------------------------------------|
| `public_subnet_cidrs`               | `list(string)` | **required** | 3 CIDRs for public subnets                    |
| `private_subnet_cidrs`              | `list(string)` | **required** | 3 CIDRs for private subnets                   |
| `database_subnet_cidrs`             | `list(string)` | **required** | 3 CIDRs for database subnets                  |
| `public_subnet_map_public_ip_on_launch` | `bool`     | `true`       | Auto-assign public IPs in public subnets       |
| `create_database_subnet_group`      | `bool`         | `true`       | Create RDS DB subnet group                     |
| `database_subnet_group_name`        | `string`       | `""`         | Override DB subnet group name                  |

### NAT Gateways

| Variable             | Type   | Default | Description                                              |
|----------------------|--------|---------|----------------------------------------------------------|
| `enable_nat_gateway` | `bool` | `true`  | Enable NAT gateways for private/database outbound access |
| `single_nat_gateway` | `bool` | `true`  | Use 1 NAT (dev/staging) vs 3 NATs (production)          |

### Internet Gateway

| Variable    | Type   | Default | Description                          |
|-------------|--------|---------|--------------------------------------|
| `create_igw`| `bool` | `true`  | Create internet gateway              |

### Flow Logs

| Variable                            | Type     | Default             | Description                                    |
|-------------------------------------|----------|---------------------|------------------------------------------------|
| `enable_flow_logs`                  | `bool`   | `true`              | Enable VPC flow logs                           |
| `flow_log_destination_type`         | `string` | `"cloud-watch-logs"`| Destination: cloud-watch-logs or s3            |
| `flow_log_traffic_type`             | `string` | `"ALL"`             | Traffic type: ALL, ACCEPT, REJECT              |
| `flow_log_retention_in_days`        | `number` | `30`                | CloudWatch log retention                       |
| `flow_log_max_aggregation_interval` | `number` | `600`               | Aggregation interval: 60 or 600 seconds        |
| `flow_log_cloudwatch_kms_key_id`    | `string` | `""`                | KMS key for CloudWatch log encryption          |
| `flow_log_s3_bucket_arn`            | `string` | `""`                | S3 bucket ARN (when destination is s3)         |
| `flow_log_s3_key_prefix`            | `string` | `"vpc-flow-logs"`   | S3 key prefix for log files                    |
| `flow_log_log_format`               | `string` | `""`                | Custom flow log record format                  |

### VPC Endpoints

| Variable                                | Type                | Default | Description                                      |
|-----------------------------------------|---------------------|---------|--------------------------------------------------|
| `enable_s3_endpoint`                    | `bool`              | `true`  | Create free S3 gateway endpoint                  |
| `enable_dynamodb_endpoint`              | `bool`              | `true`  | Create free DynamoDB gateway endpoint            |
| `interface_endpoints`                   | `map(object({...}))` | `{}`   | Map of interface endpoints to create             |
| `interface_endpoint_security_group_ids` | `list(string)`      | `[]`   | Additional SGs for interface endpoints           |

### Network ACLs

| Variable                      | Type                | Default              | Description                                     |
|-------------------------------|---------------------|----------------------|-------------------------------------------------|
| `create_custom_nacls`         | `bool`              | `true`               | Create custom NACLs per subnet tier             |
| `database_allowed_ports`      | `list(number)`      | `[5432,3306,6379]`   | DB ports allowed from private subnets           |
| `public_nacl_ingress_rules`   | `list(object({...}))`| `[]`                | Additional public NACL ingress rules            |
| `public_nacl_egress_rules`    | `list(object({...}))`| `[]`                | Additional public NACL egress rules             |
| `private_nacl_ingress_rules`  | `list(object({...}))`| `[]`                | Additional private NACL ingress rules           |
| `private_nacl_egress_rules`   | `list(object({...}))`| `[]`                | Additional private NACL egress rules            |
| `database_nacl_ingress_rules` | `list(object({...}))`| `[]`                | Additional database NACL ingress rules          |
| `database_nacl_egress_rules`  | `list(object({...}))`| `[]`                | Additional database NACL egress rules           |

### Cost Optimization

| Variable                               | Type   | Default | Description                                |
|----------------------------------------|--------|---------|--------------------------------------------|
| `enable_network_address_usage_metrics` | `bool` | `false` | Enable IP address utilization metrics      |

### Custom Identifier

| Variable              | Type     | Default | Description                                        |
|-----------------------|----------|---------|----------------------------------------------------|
| `identifier_override` | `string` | `""`    | Override auto-generated name prefix                |

---

## Outputs Reference

### VPC

| Output                          | Description                           |
|---------------------------------|---------------------------------------|
| `vpc_id`                        | VPC ID                                |
| `vpc_arn`                       | VPC ARN                               |
| `vpc_cidr_block`                | Primary CIDR block                    |
| `vpc_secondary_cidr_blocks`     | Secondary CIDR blocks                 |
| `vpc_default_security_group_id` | Default security group ID             |
| `vpc_default_route_table_id`    | Default route table ID                |
| `vpc_default_network_acl_id`    | Default network ACL ID                |

### Subnets

| Output                     | Description                   |
|----------------------------|-------------------------------|
| `public_subnet_ids`        | Public subnet IDs             |
| `public_subnet_arns`       | Public subnet ARNs            |
| `public_subnet_cidrs`      | Public subnet CIDR blocks     |
| `private_subnet_ids`       | Private subnet IDs            |
| `private_subnet_arns`      | Private subnet ARNs           |
| `private_subnet_cidrs`     | Private subnet CIDR blocks    |
| `database_subnet_ids`      | Database subnet IDs           |
| `database_subnet_arns`     | Database subnet ARNs          |
| `database_subnet_cidrs`    | Database subnet CIDR blocks   |
| `database_subnet_group_name` | RDS DB subnet group name    |
| `database_subnet_group_arn`  | RDS DB subnet group ARN     |

### Routing & Gateways

| Output                       | Description                       |
|------------------------------|-----------------------------------|
| `internet_gateway_id`        | Internet gateway ID               |
| `internet_gateway_arn`       | Internet gateway ARN              |
| `public_route_table_ids`     | Public route table IDs            |
| `private_route_table_ids`    | Private route table IDs           |
| `database_route_table_ids`   | Database route table IDs          |
| `nat_gateway_ids`            | NAT gateway IDs                   |
| `nat_gateway_public_ips`     | NAT gateway Elastic IP addresses  |
| `nat_gateway_allocation_ids` | EIP allocation IDs                |

### Security & Monitoring

| Output                               | Description                           |
|--------------------------------------|---------------------------------------|
| `public_nacl_id`                     | Public NACL ID                        |
| `private_nacl_id`                    | Private NACL ID                       |
| `database_nacl_id`                   | Database NACL ID                      |
| `flow_log_id`                        | VPC flow log ID                       |
| `flow_log_cloudwatch_log_group_arn`  | Flow log CloudWatch log group ARN     |
| `flow_log_iam_role_arn`              | Flow log IAM role ARN                 |

### VPC Endpoints

| Output                                 | Description                               |
|----------------------------------------|-------------------------------------------|
| `s3_endpoint_id`                       | S3 gateway endpoint ID                    |
| `dynamodb_endpoint_id`                 | DynamoDB gateway endpoint ID              |
| `interface_endpoint_ids`               | Map of interface endpoint IDs             |
| `interface_endpoint_dns_entries`       | Map of interface endpoint DNS entries     |
| `interface_endpoint_security_group_id` | Interface endpoint security group ID      |

### Convenience

| Output         | Description                                              |
|----------------|----------------------------------------------------------|
| `network_info` | Composite map with VPC ID, subnet IDs, NAT IPs, etc.    |

---

## Best Practices Applied

### Security

- **Three-tier isolation** with dedicated NACLs preventing lateral movement between tiers.
- **Database subnets** have no internet ingress at the NACL level -- defense-in-depth beyond security groups.
- **Database egress** is tightly scoped to HTTPS, HTTP, and DNS only -- no unrestricted outbound.
- **VPC Flow Logs** enabled by default for traffic auditing and anomaly detection.
- **No public IPs** on private or database subnets.
- **DNS support** enabled for VPC endpoint resolution and private hosted zones.
- **Separate route tables** per tier prevent accidental cross-tier routing.

### Cost Optimization

- **Single NAT gateway** in dev/staging saves ~$64/month vs multi-NAT.
- **Gateway VPC endpoints** (S3 + DynamoDB) are free and eliminate NAT data processing charges.
- **REJECT-only flow logs** in dev reduce CloudWatch Logs ingestion costs.
- **600-second aggregation** in non-prod reduces flow log record volume.
- **Interface endpoints** are opt-in, only created when explicitly configured.

### Reliability

- **Multi-NAT in production** ensures outbound connectivity survives AZ failure.
- **Per-AZ route tables** in production isolate blast radius to a single AZ.
- **3 AZs** provide maximum availability for downstream services (RDS Multi-AZ, ECS, etc.).
- **EIP `create_before_destroy`** ensures NAT IP continuity during replacements.

### Operations

- **Consistent naming** (`project-environment-service-tier-az`) across all resources.
- **Comprehensive tagging** (Project, Environment, Service, ManagedBy, Tier) on every resource.
- **30+ outputs** provide all identifiers needed by downstream modules.
- **`network_info` composite output** simplifies passing VPC data to other Terragrunt dependencies.
- **RDS DB subnet group** created automatically for immediate use by database modules.

---

## Multi-Region Deployments

### Adding a new region

```bash
# Create the region directory
mkdir -p envs/prod/eu-west-1/vpc

# Copy the leaf terragrunt.hcl
cp envs/prod/eu-west-1/vpc/terragrunt.hcl \
   envs/prod/eu-west-1/vpc/terragrunt.hcl
```

Override AZs in the leaf `terragrunt.hcl`:

```hcl
inputs = {
  availability_zones    = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  public_subnet_cidrs   = ["10.3.0.0/20", "10.3.16.0/20", "10.3.32.0/20"]
  private_subnet_cidrs  = ["10.3.48.0/20", "10.3.64.0/20", "10.3.80.0/20"]
  database_subnet_cidrs = ["10.3.96.0/20", "10.3.112.0/20", "10.3.128.0/20"]
}
```

### Adding a new account

Add an `account.hcl` next to the region directory:

```
envs/prod/eu-west-1/account.hcl
```

```hcl
locals {
  account_id = "999888777666"
}
```

---

## CIDR Planning Guide

### Recommended /20 subnets within a /16 VPC

```
VPC: 10.X.0.0/16 (65,534 usable IPs)

Public Tier:
  AZ-a: 10.X.0.0/20    (4,094 IPs)
  AZ-b: 10.X.16.0/20   (4,094 IPs)
  AZ-c: 10.X.32.0/20   (4,094 IPs)

Private Tier:
  AZ-a: 10.X.48.0/20   (4,094 IPs)
  AZ-b: 10.X.64.0/20   (4,094 IPs)
  AZ-c: 10.X.80.0/20   (4,094 IPs)

Database Tier:
  AZ-a: 10.X.96.0/20   (4,094 IPs)
  AZ-b: 10.X.112.0/20  (4,094 IPs)
  AZ-c: 10.X.128.0/20  (4,094 IPs)

Reserved: 10.X.144.0/20 - 10.X.240.0/20 (7 blocks for future use)
```

### Environment CIDR allocation

| Environment | VPC CIDR       | Second Octet |
|-------------|----------------|--------------|
| Dev         | 10.0.0.0/16    | 0            |
| Staging     | 10.1.0.0/16    | 1            |
| Production  | 10.2.0.0/16    | 2            |
| DR          | 10.3.0.0/16    | 3            |

This prevents CIDR conflicts when peering VPCs across environments.

---

## Resources Created

| Resource                                 | Count   | Description                                     |
|------------------------------------------|---------|-------------------------------------------------|
| `aws_vpc`                                | 1       | Virtual Private Cloud                           |
| `aws_vpc_ipv4_cidr_block_association`    | 0-N     | Secondary CIDR blocks                           |
| `aws_internet_gateway`                   | 0-1     | Internet gateway                                |
| `aws_subnet` (public)                    | 3       | Public subnets across 3 AZs                     |
| `aws_subnet` (private)                   | 3       | Private application subnets across 3 AZs        |
| `aws_subnet` (database)                  | 3       | Isolated database subnets across 3 AZs          |
| `aws_eip`                                | 1-3     | Elastic IPs for NAT gateways                    |
| `aws_nat_gateway`                        | 1-3     | NAT gateways (1 or 3 based on environment)      |
| `aws_route_table` (public)               | 0-1     | Public route table                              |
| `aws_route_table` (private)              | 1-3     | Private route tables (1 or per-AZ)              |
| `aws_route_table` (database)             | 1-3     | Database route tables (1 or per-AZ)             |
| `aws_route`                              | 1-7     | Routes (IGW + NAT per table)                    |
| `aws_route_table_association`            | 9       | Subnet-to-route-table associations              |
| `aws_db_subnet_group`                   | 0-1     | RDS DB subnet group                             |
| `aws_network_acl`                        | 0-3     | NACLs (public, private, database)               |
| `aws_network_acl_rule`                   | 0-20+   | NACL rules across all tiers                     |
| `aws_flow_log`                           | 0-1     | VPC flow log                                    |
| `aws_cloudwatch_log_group`               | 0-1     | Flow log CloudWatch log group                   |
| `aws_iam_role`                           | 0-1     | Flow log IAM role                               |
| `aws_iam_role_policy`                    | 0-1     | Flow log IAM policy                             |
| `aws_vpc_endpoint` (gateway)             | 0-2     | S3 + DynamoDB gateway endpoints                 |
| `aws_vpc_endpoint` (interface)           | 0-N     | Interface endpoints (optional)                  |
| `aws_security_group` (endpoints)         | 0-1     | Interface endpoint security group               |

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
│ _envcommon/vpc.hcl                                          │
│   - Module source path                                      │
│   - Shared default inputs from env.hcl                      │
├─────────────────────────────────────────────────────────────┤
│ envs/<env>/env.hcl                                          │
│   - CIDR blocks, AZs, subnet CIDRs                         │
│   - NAT gateway strategy (single vs multi)                  │
│   - Flow log configuration                                  │
│   - Endpoint and NACL settings                              │
├─────────────────────────────────────────────────────────────┤
│ envs/<env>/<region>/vpc/terragrunt.hcl                      │
│   - Includes root + envcommon                               │
│   - Per-region overrides (AZs, CIDRs for multi-region)     │
└─────────────────────────────────────────────────────────────┘
```

Values flow top-down. Lower layers override higher layers. The leaf `terragrunt.hcl` has the final say on all inputs.
