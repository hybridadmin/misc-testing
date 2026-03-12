# Reusable Prompt: Generate a Terraform/Terragrunt Role

Use this prompt as a template when asking an AI assistant to scaffold a new AWS
infrastructure role in this project. Replace the placeholder sections in
`[BRACKETS]` with the specifics of the resource you want to deploy.

---

## The Prompt

```
I need Terraform (with Terragrunt) to deploy [RESOURCE DESCRIPTION, e.g. "an
AWS VPC with three-tier subnet architecture", "an ElastiCache Redis cluster",
"an S3 bucket with replication"] in AWS. Follow the exact project conventions
described below. The code must be deployable across multiple environments
(dev, staging, prod).

### Role Name

Use `[ROLE_NAME]` as the role identifier (snake_case).

### Directory Layout

Create the following structure under `aws/roles/[ROLE_NAME]/`:

```
[ROLE_NAME]/
├── terragrunt.hcl                                    # Root config
├── _envcommon/
│   └── [ROLE_NAME].hcl                               # Shared module source + default inputs
├── modules/[ROLE_NAME]/                              # Terraform module
│   ├── versions.tf
│   ├── variables.tf
│   ├── locals.tf
│   ├── main.tf
│   ├── nacl.tf                                       # If network ACL resources needed
│   ├── flow_logs.tf                                  # If VPC flow log resources needed
│   ├── endpoints.tf                                  # If VPC endpoint resources needed
│   ├── security.tf                                   # If security group resources needed
│   ├── monitoring.tf                                 # If CloudWatch alarms apply
│   └── outputs.tf
├── envs/
│   ├── dev/
│   │   ├── env.hcl
│   │   └── eu-west-1/[ROLE_NAME]/terragrunt.hcl
│   ├── staging/
│   │   ├── env.hcl
│   │   └── eu-west-1/[ROLE_NAME]/terragrunt.hcl
│   └── prod/
│       ├── env.hcl
│       └── eu-west-1/[ROLE_NAME]/terragrunt.hcl
├── README.md
└── PROMPT.md
```

### Terraform Module Conventions (`modules/[ROLE_NAME]/`)

**versions.tf:**
- `required_version = ">= 1.5.0"`
- Only declare providers actually used by the module (e.g. `hashicorp/aws >= 5.0`)

**variables.tf:**
- Group variables using banner comments:
  ```hcl
  ###############################################################################
  # Section Name
  ###############################################################################
  ```
- Always start with a "General" section containing: `project` (validated
  lowercase alphanumeric + hyphens), `environment` (validated enum: dev,
  staging, prod, uat, qa, sandbox), `service` (with a sensible default), `tags`
  (map(string), default {}).
- Include a "Networking" section when VPC resources are involved.
- Every variable must have `description` and `type`. Provide `default` wherever
  a sensible default exists.
- Use `validation {}` blocks liberally: regex for string formats, `contains()`
  for enums, range checks for numbers, `alltrue()` for list elements.
- End with a "Custom Identifier" section: `identifier_override` (string,
  default "").
- Make as many resource-specific options customizable as possible. Expose every
  meaningful AWS resource argument as a variable with a best-practice default.

**locals.tf:**
- Start with data sources outside the locals block:
  ```hcl
  data "aws_caller_identity" "current" {}
  data "aws_region" "current" {}
  ```
- Define naming: `name_prefix = "${var.project}-${var.environment}-${var.service}"`,
  `identifier` with override support.
- Derive computed values from inputs (e.g. NAT count from single_nat_gateway flag,
  engine family from version string, subnet counts from lists).
- Use empty-string-to-null coercion for optional ARN/ID variables:
  `var.kms_key_id != "" ? var.kms_key_id : null`
- Define `default_tags` map (Project, Environment, Service, ManagedBy=terraform),
  then `tags = merge(local.default_tags, var.tags)`.
- Include best-practice default configuration for the resource (merged with
  user-supplied overrides using concat + contains exclusion).

**main.tf:**
- Name singleton resources `"this"`. Name collections descriptively
  (e.g. `"public"`, `"private"`, `"database"`).
- Use `lifecycle { create_before_destroy = true }` on mutable configuration objects
  (parameter groups, security groups, EIPs, etc.).
- Use `lifecycle { ignore_changes = [...] }` where timestamp or computed values
  cause perpetual diffs.
- Use `dynamic` blocks for optional features.
- Use explicit `depends_on` for ordering when implicit dependency is insufficient
  (e.g. IGW before NAT gateway).
- Tag every resource: `tags = merge(local.tags, { Name = "..." })`.
- Use `count` or `for_each` for conditionally created resources.

**nacl.tf** (when applicable):
- Create `aws_network_acl` resources per subnet tier with `subnet_ids` association.
- Use `aws_network_acl_rule` resources (NOT inline `ingress`/`egress` blocks) for
  each rule -- this allows granular management and custom rule injection.
- Apply principle of least privilege: database subnets should only allow database
  ports from application subnets, with tightly scoped egress.
- Allow custom rule injection via variables (list of rule objects).
- Use calculated rule numbers (100, 110, 120...) with room for custom rules.

**flow_logs.tf** (when applicable):
- Support both CloudWatch Logs and S3 destinations.
- Create IAM role and policy for CloudWatch destination.
- Use `destination_options` for S3 with Parquet format and Hive-compatible partitions.
- Gate all resources with `count = var.enable_flow_logs ? 1 : 0`.

**endpoints.tf** (when applicable):
- Gateway endpoints (S3, DynamoDB) are free -- always recommend enabling them.
- Attach gateway endpoints to all relevant route tables (private, database, optionally public).
- Interface endpoints should use `for_each` over a variable map.
- Create a shared security group for interface endpoints allowing HTTPS from VPC CIDR.

**security.tf** (when applicable):
- Create an `aws_security_group` with `create_before_destroy = true`.
- Use the modern `aws_vpc_security_group_ingress_rule` and
  `aws_vpc_security_group_egress_rule` resources (NOT inline rules or the
  deprecated `aws_security_group_rule`).
- Iterate CIDR blocks and security group IDs separately with `for_each = toset(...)`.
- Parameterize the port via a variable.

**monitoring.tf** (when applicable):
- Gate all alarms with `count = var.create_cloudwatch_alarms ? 1 : 0`.
- Create alarms for the key operational metrics of the resource.
- Use `treat_missing_data = "breaching"` for capacity/availability metrics and
  `"notBreaching"` for performance metrics.
- Expose each alarm threshold as a variable with a sensible default.
- Route all alarm/ok/insufficient_data actions to `var.alarm_sns_topic_arns`.
- Conditionally create IAM roles only when needed
  (`count = local.create_xxx ? 1 : 0`).

**outputs.tf:**
- Mirror the resource grouping from main.tf using banner comments.
- Output: id, arn, endpoint/address, and all operationally useful attributes.
- Include a convenience composite output (e.g. `network_info` map, `connection_info` map).
- Every output must have a `description`.
- Use `try()` for conditionally created resources: `try(resource[0].id, null)`.

### Terragrunt Conventions

**Root `terragrunt.hcl`:**
- Parse the directory path with regex to extract environment and region:
  `regex(".+/envs/(?P<env>[^/]+)/(?P<region>[^/]+)/.*", get_terragrunt_dir())`
- Load `env.hcl` via `read_terragrunt_config(find_in_parent_folders("env.hcl"))`.
- Optionally load `account.hcl` with `try()` for multi-account support.
- Configure S3 remote state with DynamoDB locking (bucket:
  `${project}-${environment}-tfstate-${account_id}`).
- Generate `provider.tf` with `assume_role` and `default_tags` (lowercase keys:
  project, environment, service, managed_by=terragrunt).
- Generate `versions.tf` with the same constraints as the module.
- Pass common inputs: `project`, `environment`, `service`.

**`_envcommon/[ROLE_NAME].hcl`:**
- Set `terraform.source = "${get_repo_root()}/aws/roles/[ROLE_NAME]/modules/[ROLE_NAME]"`.
- Read `env.hcl` and pass shared inputs. Use `try()` with sensible fallback for
  optional values.

**`envs/<env>/env.hcl`:**
- Pure `locals {}` block only -- no terraform or inputs blocks.
- Define: project, service, environment, account_id, and all environment-specific tunables.
- Use placeholder values (`"000000000000"`) for IDs that must be replaced before deployment.
- Group settings with section comments matching the module's variable sections.

**Leaf `terragrunt.hcl`:**
- Two includes: `"root"` (find_in_parent_folders) and `"envcommon"` (with
  `expose = true`).
- Load env_vars via `read_terragrunt_config(find_in_parent_folders("env.hcl"))`.
- Pass environment-specific overrides from `env_vars.locals.*` in the inputs
  block, grouped with inline comments.

### Environment Differentiation

Apply this philosophy across dev/staging/prod:

| Aspect              | Dev                             | Staging                        | Prod                            |
|---------------------|---------------------------------|--------------------------------|---------------------------------|
| **Sizing**          | Smallest viable                 | Moderate / mirrors prod arch   | Production-grade                |
| **HA/Redundancy**   | Minimal (single NAT, etc.)      | Moderate (single NAT OK)       | Full (multi-NAT, multi-AZ)     |
| **Cost**            | Aggressively optimized          | Moderately optimized           | Prioritize availability         |
| **Monitoring**      | Basic, alarms off               | Moderate, alarms on            | Aggressive, alarms on           |
| **Logging**         | REJECT-only, short retention    | ALL traffic, medium retention  | ALL traffic, long retention     |
| **Protection**      | Minimal (easy teardown)         | Moderate                       | Maximum (deletion protection)   |

### Security Best Practices

- Enable encryption at rest and in transit by default.
- Use Secrets Manager for credentials (never plaintext in state).
- Default to private networking (not publicly accessible).
- Apply principle of least privilege at every layer (NACLs, security groups, IAM).
- Database subnets must have NO internet ingress -- only application-tier access on specific ports.
- Database egress should be scoped to HTTPS/DNS for AWS API calls, patching, and secret rotation.
- Include comprehensive logging and monitoring out of the box.
- Use VPC flow logs for network traffic auditing.

### Cost Optimization Best Practices

- Use single NAT gateway in dev/staging (~$32/month vs ~$96/month for 3 NATs).
- Always enable free gateway VPC endpoints (S3, DynamoDB) to reduce NAT data charges.
- Use REJECT-only flow logs in dev to reduce CloudWatch ingestion costs.
- Use 600-second flow log aggregation in non-prod to reduce record volume.
- Interface VPC endpoints should be opt-in (~$7.20/month per AZ per endpoint).
- Avoid dedicated tenancy unless compliance requires it.

### README.md

Include a comprehensive README with these sections (in order):
1. Title and one-liner description
2. Architecture ASCII diagram showing all tiers and traffic flow
3. Directory structure with inline comments
4. Prerequisites table + checklist
5. Quick start (configure, deploy, retrieve outputs)
6. Security model documentation (NACL rules, tier isolation)
7. NAT gateway strategy table with cost analysis
8. Cost optimization section with estimated savings
9. Environment comparison table
10. Variables reference (tables grouped by section)
11. Outputs reference table
12. Best practices applied (Security, Cost, Reliability, Operations)
13. Multi-region/multi-account deployment guide
14. CIDR planning guide
15. Resources created table with counts
16. Terragrunt configuration layers diagram

### Additional Requirements

[ADD ANY RESOURCE-SPECIFIC REQUIREMENTS HERE, e.g.:
- "Support three-tier subnets: public, private, database"
- "Database subnets must block all internet ingress via NACLs"
- "NAT count should be environment-aware: 1 for dev/staging, 3 for prod"
- "Include gateway VPC endpoints for S3 and DynamoDB"
- "Support optional interface VPC endpoints"
- etc.]
```

---

## Example: Using the Prompt for a VPC

Replace the placeholders:
- `[RESOURCE DESCRIPTION]` -> "an AWS VPC with three-tier subnet architecture
  (public, private, database), NAT gateways, flow logs, and VPC endpoints"
- `[ROLE_NAME]` -> `vpc`
- `[Additional Requirements]` -> "Support 3 subnet tiers with restrictive NACLs,
  environment-aware NAT gateway count (1 for dev/staging, 3 for prod), gateway
  VPC endpoints for S3/DynamoDB, optional interface endpoints, VPC flow logs with
  CloudWatch or S3 destination, and database subnet egress restricted to HTTPS/DNS
  for secret rotation and patching"

## Example: Using the Prompt for ElastiCache Redis

Replace the placeholders:
- `[RESOURCE DESCRIPTION]` -> "an ElastiCache Redis cluster with replication"
- `[ROLE_NAME]` -> `redis_cluster`
- `[Additional Requirements]` -> "Support cluster mode enabled/disabled, automatic
  failover, configurable node types and replica counts per shard, snapshot
  support, and AUTH token via Secrets Manager"

## Example: Using the Prompt for an ECS Fargate Service

Replace the placeholders:
- `[RESOURCE DESCRIPTION]` -> "an ECS Fargate service with ALB integration"
- `[ROLE_NAME]` -> `ecs_service`
- `[Additional Requirements]` -> "Support Fargate and Fargate Spot capacity
  providers, ALB target group with health checks, auto-scaling based on CPU/memory,
  CloudWatch Container Insights, and task definition with configurable container
  definitions"
