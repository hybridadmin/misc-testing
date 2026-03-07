# AGENTS.md

## Project Overview

Production-ready EKS infrastructure on AWS using Terraform. Three child modules
(`vpc`, `eks`, `addons`) orchestrated by a thin root module, with per-environment
configuration under `environments/`.

## Build / Validate / Deploy Commands

```bash
# Format check (required before every commit)
terraform fmt -check -recursive

# Format fix
terraform fmt -recursive

# Validate syntax (run after init)
terraform validate

# Initialize for a specific environment
terraform init -backend-config=environments/<env>/backend.tf

# Switch between environments (re-init with different backend)
terraform init -reconfigure -backend-config=environments/<env>/backend.tf

# Plan
terraform plan -var-file=environments/<env>/terraform.tfvars -out=tfplan

# Apply from saved plan only
terraform apply tfplan

# Destroy (requires explicit var-file)
terraform destroy -var-file=environments/<env>/terraform.tfvars
```

No CI pipeline, Makefile, tflint, tfsec, or checkov is configured. Validation is
manual via `terraform fmt`, `terraform validate`, and plan review.

## Project Structure

```
main.tf              # Root module — wires child modules, defines locals
variables.tf         # All root input variables with validation blocks
outputs.tf           # All root outputs
providers.tf         # AWS (with default_tags), Kubernetes, Helm providers
versions.tf          # Terraform >= 1.5.0, provider constraints, empty S3 backend stub
environments/
  <env>/
    backend.tf       # S3 backend config (bucket, key, region, DynamoDB lock)
    terraform.tfvars # Environment-specific variable values
modules/
  vpc/               # VPC, subnets, NAT GWs, route tables, flow logs
  eks/               # EKS cluster, node groups, OIDC, KMS, SGs, addons
  addons/            # Helm-based addons (ALB controller, autoscaler, CSI drivers)
    policies/        # Static JSON IAM policy files
```

Each module contains exactly: `main.tf`, `variables.tf`, `outputs.tf`.
No `providers.tf` or `versions.tf` in child modules.

## Code Style

### Formatting
- 2-space indentation (Terraform default). Run `terraform fmt` before committing.
- Align `=` signs within blocks (`type        = string`).
- Blank line between resource blocks and before `tags`/`lifecycle`/`depends_on`.

### Argument Ordering Inside Resource Blocks
1. `count` (always first if present)
2. Identity / naming (`name`, `cluster_name`, `node_group_name`)
3. Core configuration (type-specific required attributes)
4. Nested blocks (`vpc_config`, `scaling_config`, `set`, `condition`)
5. `depends_on`
6. `tags`
7. `lifecycle`

### Resource Naming (Terraform Labels)
- `this` for the singleton primary resource of its type in a module
  (`aws_vpc.this`, `aws_eks_cluster.this`, `aws_nat_gateway.this`).
- Descriptive snake_case for multiple resources of the same type
  (`aws_iam_role.cluster`, `aws_iam_role.node_group`, `aws_subnet.public`).
- SG rules use descriptive suffixes: `cluster_egress`, `node_self_ingress`.

### AWS Resource Names (Name Tags)
Pattern: `${cluster_name}-<component>-<type>` or `${var.name}-<descriptor>`.
- IAM roles: `${cluster_name}-cluster-role`, `${cluster_name}-node-group-role`
- SGs: `${cluster_name}-cluster-sg`, `${cluster_name}-node-sg`
- Log groups: `/aws/eks/${cluster_name}/cluster`, `/aws/vpc/${name}/flow-logs`
- KMS alias: `alias/eks-${cluster_name}`

### Variables
- Every variable MUST have `description` and explicit `type`.
- Use `validation` blocks for constrained value sets (e.g., `environment`, `node_capacity_type`).
- Boolean feature flags: `enable_<feature>` (e.g., `enable_cluster_autoscaler`).
- No default on required inputs (`environment`, `cluster_name`, CIDRs).
- Tags variable in every module: `variable "tags" { type = map(string), default = {} }`.

### Outputs
- Every output MUST have `description`.
- Use `sensitive = true` for secrets (e.g., `cluster_ca_certificate`).
- Conditional outputs: `value = var.enable_x ? resource.name[0].arn : null`.

### Comments
- File headers: `# ---...---` separator (77-char dashes), module name, multi-line description.
- Section headers: `# ---...---` blocks to group related resources.
- Major sections (addons module): `# ===...===` with description sentence.
- Sub-sections: `# -- IRSA Role for X --` pattern.
- Inline comments for non-obvious logic (`# Required for ALB auto-discovery`).

### Locals
- Declared at top of `main.tf`, after data sources, before resources.
- Used for composed names (`cluster_name = "${var.project_name}-${var.environment}"`)
  and shorthand aliases (`account_id`, `partition`, `region`).

### Data Sources
- Placed at very top of `main.tf`, before locals.
- Ambient data uses `"current"` label: `data "aws_caller_identity" "current" {}`.
- Complex data sources use descriptive names (`data "aws_iam_policy_document" "lb_controller_assume"`).

## Count and Iteration
- `count` exclusively; `for_each` is not used in this codebase.
- Feature toggles: `count = var.enable_<feature> ? 1 : 0`.
- List iteration: `count = length(var.availability_zones)`.
- Reference conditional resources via `[0]`: `aws_iam_role.ebs_csi[0].arn`.

## Lifecycle Rules
- `prevent_destroy = true` on ALL stateful/critical resources (VPC, subnets, EKS cluster,
  node group, KMS keys, IAM roles, IAM policies, OIDC provider, security groups,
  CloudWatch log groups, IGW, NAT GWs, EIPs).
- NOT on leaf resources: routes, route table associations, SG rules, IAM policy
  attachments, Helm releases, EKS addons, KMS aliases.
- `create_before_destroy = true` on security groups (combined with `prevent_destroy`).
- `ignore_changes = [scaling_config[0].desired_size]` on node groups (autoscaler manages this).
- Never create duplicate lifecycle blocks; merge into one.

## Tagging Strategy
- Provider-level `default_tags` in `providers.tf`: `Project`, `Environment`, `ManagedBy`.
- Module-level `var.tags` passed through from root `local.common_tags`.
- Resource-level `Name` tag via `merge(var.tags, { Name = "..." })`.
- Resources without meaningful Name (IAM roles, KMS keys): just `tags = var.tags`.
- Kubernetes tags on subnets (`kubernetes.io/role/elb`, `kubernetes.io/cluster/...`).
- Autoscaler tags on node groups (`k8s.io/cluster-autoscaler/enabled`).

## Security Patterns
- IAM: least-privilege. Never `"Resource": "*"` with mutating actions.
- IRSA pattern: `iam_policy_document` (assume) -> `iam_role` -> `iam_policy` ->
  `iam_role_policy_attachment` -> `helm_release` with SA annotation. All conditional via `count`.
- IRSA trust policies MUST use `StringEquals` on both `:aud` and `:sub` OIDC claims.
- SG rules as separate `aws_security_group_rule` resources (not inline). Every rule has `description`.
- Internal traffic via `source_security_group_id`, not CIDRs.
- KMS: `enable_key_rotation = true`, `deletion_window_in_days = 30`.
- EKS secrets encrypted via KMS envelope encryption.
- Nodes in private subnets only. VPC flow logs enabled.

## Helm Releases
- Pinned chart versions always (never `latest`).
- Deploy to `kube-system` namespace.
- Configuration via `set` blocks (not `values` YAML).
- Feature-flag `count`. `depends_on` IAM policy attachments.

## State Management
- S3 backend with DynamoDB locking and `encrypt = true`.
- Empty backend stub in `versions.tf`; configured via `-backend-config` at init.
- State key pattern: `eks/<environment>/terraform.tfstate`.
- Each environment has its own state file — never shared.

## Version Constraints
- Terraform: `>= 1.5.0` (minimum, not pinned).
- Providers: pessimistic `~>` constraints (`aws ~> 5.0`, `kubernetes ~> 2.23`,
  `helm ~> 2.11`, `tls ~> 4.0`).
- Every provider has explicit `source` with full registry path.

## Environment Separation
- Shared module code, per-environment `backend.tf` + `terraform.tfvars` in `environments/<env>/`.
- Differentiate environments via variable values, never via `count`/conditionals in modules.
- Key differences: prod uses ON_DEMAND / m5.large / 3 NAT GWs / private API;
  systest uses SPOT / t3.medium / 1 NAT GW / public API.

## OpenCode Skills (`.opencode/skills/`)
Five project-local skills are available for Terraform best practices guidance:
- `terraform-deletion-protection` — which resources need `prevent_destroy`
- `terraform-state-safety` — remote backend, locking, encryption
- `terraform-security` — IAM, encryption, secrets, network isolation
- `terraform-tagging` — consistent tag strategy
- `terraform-modules` — module structure, variables, outputs, naming
