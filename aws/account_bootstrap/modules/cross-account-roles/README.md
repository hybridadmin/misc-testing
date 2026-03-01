# Cross-Account IAM Roles -- Terraform Module

Reusable Terraform module that creates cross-account IAM roles allowing a trusted (identity/management) AWS account to assume roles in a target account.

## Resources Created

| Resource | Purpose |
|---|---|
| `aws_iam_role.admin` | Full administrative access from the trusted account |
| `aws_iam_role.read_only` | Read-only access with secrets denied |
| `aws_iam_role_policy_attachment.admin_administrator_access` | Attaches `AdministratorAccess` managed policy |
| `aws_iam_role_policy_attachment.read_only_access` | Attaches `ReadOnlyAccess` managed policy |
| `aws_iam_role_policy.deny_secret_access` | Inline deny for secrets/SSM parameters |

Both roles:
- Trust a single external AWS account (configurable via `trusted_account_id`).
- Require MFA by default (configurable via `require_mfa`).

## Usage

```hcl
module "cross_account_roles" {
  source = "../../modules/cross-account-roles"

  trusted_account_id = "283837321132"

  tags = {
    Environment = "production"
    ManagedBy   = "terragrunt"
  }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `trusted_account_id` | The AWS account ID trusted to assume cross-account roles. | `string` | n/a | **yes** |
| `require_mfa` | Whether to require MFA for assuming cross-account roles. | `bool` | `true` | no |
| `admin_role_name` | Name of the cross-account admin access IAM role. | `string` | `"CrossAccountAdminAccess"` | no |
| `read_only_role_name` | Name of the cross-account read-only access IAM role. | `string` | `"CrossAccountReadAccess"` | no |
| `role_path` | IAM path for the cross-account roles. | `string` | `"/"` | no |
| `max_session_duration` | Maximum session duration in seconds (3600-43200). | `number` | `3600` | no |
| `tags` | A map of tags to apply to all resources. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `admin_role_arn` | ARN of the cross-account admin access IAM role. |
| `admin_role_name` | Name of the cross-account admin access IAM role. |
| `admin_role_id` | Unique ID of the cross-account admin access IAM role. |
| `read_only_role_arn` | ARN of the cross-account read-only access IAM role. |
| `read_only_role_name` | Name of the cross-account read-only access IAM role. |
| `read_only_role_id` | Unique ID of the cross-account read-only access IAM role. |

## Security Notes

- **MFA enforcement** is enabled by default. Only disable for machine-to-machine auth.
- The **read-only role** explicitly denies `secretsmanager:GetSecretValue`, `ssm:GetParameter`, and `ssm:GetParameters`.
- The **admin role** grants `AdministratorAccess` -- use sparingly and audit via CloudTrail.
