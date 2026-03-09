# KMS Keys -- Terraform Module

Reusable Terraform module that creates a KMS key for encrypting shared AMIs across an AWS Organization. Any account within the organisation can use the key to encrypt and decrypt AMIs, while key administration is restricted to the account root and a designated admin role.

Converted from the `kms-keys.yml` CloudFormation StackSet.

## Resources Created

| Resource | Purpose |
|---|---|
| `aws_kms_key.ami_encryption` | Customer-managed KMS key for AMI encryption |
| `aws_kms_alias.ami_encryption` | Human-readable alias for the key |

## Key Policy

The key policy contains four statements:

| Statement | Principal | Permissions |
|---|---|---|
| `AllowAccountRootFullAccess` | Account root (`iam::ACCOUNT:root`) | `kms:*` -- full key management |
| `AllowCrossAccountAdminKeyManagement` | Admin role (e.g. `CrossAccountAdminAccess`) | Key administration (create, describe, enable, disable, delete, tag, schedule deletion, etc.) |
| `AllowOrganisationAccountAccess` | Any principal in the organisation | Encrypt, decrypt, describe, re-encrypt, generate data keys |
| `AllowOrganisationGrantManagement` | Any principal in the organisation | Create, list, and revoke grants |

Organisation-scoped statements use `aws:PrincipalOrgID` to restrict access to accounts within the specified AWS Organization.

## Usage

```hcl
module "kms_keys" {
  source = "../../modules/kms-keys"

  organization_id = "o-pfayzcebx5"

  tags = {
    Environment = "prod"
    ManagedBy   = "terragrunt"
  }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `organization_id` | AWS Organizations ID used to scope key access to all accounts in the organisation. | `string` | n/a | **yes** |
| `alias_name` | Alias name for the KMS key (without the `alias/` prefix). | `string` | `"ami-encryption"` | no |
| `key_description` | Description of the KMS key. | `string` | `"AMI Encryption Key for Shared AMIs"` | no |
| `admin_role_name` | Name of the IAM role granted key administration permissions. | `string` | `"CrossAccountAdminAccess"` | no |
| `deletion_window_in_days` | Days before the key is permanently deleted after destruction (7-30). | `number` | `30` | no |
| `enable_key_rotation` | Whether to enable automatic annual rotation of key material. | `bool` | `true` | no |
| `tags` | A map of tags to apply to all resources. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `key_arn` | ARN of the KMS key. |
| `key_id` | ID of the KMS key. |
| `alias_arn` | ARN of the KMS key alias. |
| `alias_name` | Name of the KMS key alias. |

## Security Notes

- **Key rotation** is enabled by default. The KMS key material is automatically rotated annually.
- **Organisation-scoped access** -- encrypt/decrypt and grant permissions are restricted to principals whose `aws:PrincipalOrgID` matches the provided `organization_id`. No individual account IDs need to be maintained.
- **Admin role scoping** -- key administration is limited to the account root and the named admin role. Regular organisation members can only use the key, not manage it.
- **Deletion protection** -- the default `deletion_window_in_days` of 30 provides the maximum recovery window if the key is accidentally scheduled for deletion.
