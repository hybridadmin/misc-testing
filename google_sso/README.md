# AWS IAM Identity Center (SSO) with Google Workspace — Terraform/Terragrunt

This repository provides a complete Infrastructure-as-Code setup for configuring **AWS IAM Identity Center** (formerly AWS SSO) with **Google Workspace** as the external identity provider (IdP). It uses **Terraform** modules managed by **Terragrunt** to configure SSO in an AWS Organizations master account and assign group-based access across multiple AWS accounts.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Directory Structure](#directory-structure)
- [Prerequisites](#prerequisites)
- [Google Workspace Configuration (Manual Steps)](#google-workspace-configuration-manual-steps)
  - [Step 1: Enable IAM Identity Center in AWS](#step-1-enable-iam-identity-center-in-aws)
  - [Step 2: Create a SAML Application in Google Workspace](#step-2-create-a-saml-application-in-google-workspace)
  - [Step 3: Configure SAML in AWS IAM Identity Center](#step-3-configure-saml-in-aws-iam-identity-center)
  - [Step 4: Set Up SCIM Provisioning (Automatic User/Group Sync)](#step-4-set-up-scim-provisioning-automatic-usergroup-sync)
  - [Step 5: Configure Google Workspace Groups](#step-5-configure-google-workspace-groups)
- [AWS CLI Profile Setup](#aws-cli-profile-setup)
- [Deployment Guide](#deployment-guide)
  - [Step 1: Configure Account IDs and Profiles](#step-1-configure-account-ids-and-profiles)
  - [Step 2: Deploy SSO Configuration (Master Account)](#step-2-deploy-sso-configuration-master-account)
  - [Step 3: Deploy Permission Sets (Master Account)](#step-3-deploy-permission-sets-master-account)
  - [Step 4: Deploy Account Assignments (Per Account)](#step-4-deploy-account-assignments-per-account)
  - [Deploy Everything at Once](#deploy-everything-at-once)
- [Modules Reference](#modules-reference)
  - [sso-configuration](#sso-configuration)
  - [sso-permission-sets](#sso-permission-sets)
  - [sso-account-assignments](#sso-account-assignments)
- [Permission Sets Reference](#permission-sets-reference)
- [Group-to-Account Access Matrix](#group-to-account-access-matrix)
- [Adding a New AWS Account](#adding-a-new-aws-account)
- [Adding a New Permission Set](#adding-a-new-permission-set)
- [Adding a New Group](#adding-a-new-group)
- [SCIM vs Terraform-Managed Users/Groups](#scim-vs-terraform-managed-usersgroups)
- [Using SSO with the AWS CLI](#using-sso-with-the-aws-cli)
- [Troubleshooting](#troubleshooting)
- [Security Considerations](#security-considerations)
- [Cost](#cost)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        Google Workspace                                 │
│                                                                         │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐                   │
│  │ AWS-Admins  │  │AWS-Developers│  │ AWS-ReadOnly │  ... more groups  │
│  │   group     │  │    group     │  │    group     │                   │
│  └──────┬──────┘  └──────┬───────┘  └──────┬───────┘                   │
│         │                │                  │                           │
│         └────────────────┼──────────────────┘                           │
│                          │                                              │
│                    SAML 2.0 + SCIM                                      │
└──────────────────────────┼──────────────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────────────┐
│              AWS Organizations — Master Account                         │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │              IAM Identity Center (SSO)                            │  │
│  │                                                                   │  │
│  │  Identity Store          Permission Sets                          │  │
│  │  ┌─────────────┐        ┌─────────────────────┐                  │  │
│  │  │ Groups      │        │ AdministratorAccess  │                  │  │
│  │  │ Users       │        │ DeveloperAccess      │                  │  │
│  │  │ (from SCIM) │        │ ReadOnlyAccess       │                  │  │
│  │  └─────────────┘        │ DevOpsAccess         │                  │  │
│  │                          │ SecurityAudit        │                  │  │
│  │                          │ BillingAccess        │                  │  │
│  │                          │ DatabaseAdmin        │                  │  │
│  │                          └─────────────────────┘                  │  │
│  │                                                                   │  │
│  │  Account Assignments (who gets what, where)                       │  │
│  │  ┌────────────────────────────────────────────┐                   │  │
│  │  │ AWS-Admins → AdministratorAccess → Dev     │                   │  │
│  │  │ AWS-Admins → AdministratorAccess → Staging │                   │  │
│  │  │ AWS-Admins → AdministratorAccess → Prod    │                   │  │
│  │  │ AWS-Developers → DeveloperAccess → Dev     │                   │  │
│  │  │ AWS-Developers → ReadOnlyAccess  → Prod    │                   │  │
│  │  │ ...                                        │                   │  │
│  │  └────────────────────────────────────────────┘                   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│         ┌──────────┐    ┌──────────┐    ┌──────────┐                   │
│         │ Dev Acct  │    │ Staging  │    │   Prod   │                   │
│         │222222222222│    │333333333333│   │444444444444│                │
│         └──────────┘    └──────────┘    └──────────┘                   │
└──────────────────────────────────────────────────────────────────────────┘
```

**Key Concepts:**

1. **IAM Identity Center** lives in the master (management) account only
2. **Google Workspace** acts as the external IdP via SAML 2.0 for authentication
3. **SCIM** (System for Cross-domain Identity Management) automatically syncs users and groups from Google to AWS
4. **Permission Sets** define what level of access a role provides (e.g., AdministratorAccess, ReadOnly)
5. **Account Assignments** connect a group + permission set to a specific AWS account

---

## Directory Structure

```
.
├── terragrunt.hcl                          # Root Terragrunt config (remote state, provider)
├── _envcommon/                              # Shared Terragrunt includes
│   ├── sso-configuration.hcl
│   ├── sso-permission-sets.hcl
│   └── sso-account-assignments.hcl
├── modules/                                # Terraform modules
│   ├── sso-configuration/                  # Creates SSO groups/users in Identity Store
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── sso-permission-sets/                # Creates permission sets (roles)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── sso-account-assignments/            # Assigns groups to accounts with permission sets
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── environments/                           # Per-account Terragrunt configurations
    ├── master/                             # AWS Organizations master account
    │   ├── account.hcl                     # Account-level vars (account ID, profile)
    │   └── us-east-1/
    │       ├── region.hcl
    │       ├── sso-configuration/          # SSO setup (groups, users)
    │       │   └── terragrunt.hcl
    │       └── sso-permission-sets/        # Permission set definitions
    │           └── terragrunt.hcl
    ├── workload-dev/                       # Development account
    │   ├── account.hcl
    │   └── us-east-1/
    │       ├── region.hcl
    │       └── sso-account-assignments/    # Dev account group assignments
    │           └── terragrunt.hcl
    ├── workload-staging/                   # Staging account
    │   ├── account.hcl
    │   └── us-east-1/
    │       ├── region.hcl
    │       └── sso-account-assignments/
    │           └── terragrunt.hcl
    └── workload-prod/                      # Production account
        ├── account.hcl
        └── us-east-1/
            ├── region.hcl
            └── sso-account-assignments/
                └── terragrunt.hcl
```

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| **Terraform** | >= 1.5.0 | `brew install terraform` |
| **Terragrunt** | >= 0.50.0 | `brew install terragrunt` |
| **AWS CLI** | >= 2.0 | `brew install awscli` |
| **AWS Organizations** | Enabled | With all feature set enabled |
| **Google Workspace** | Super Admin | Needed to create SAML apps and configure SCIM |
| **AWS Master Account Access** | Admin | Must be able to manage IAM Identity Center |

---

## Google Workspace Configuration (Manual Steps)

These steps must be completed manually before running Terraform. They set up the trust relationship between Google Workspace and AWS.

### Step 1: Enable IAM Identity Center in AWS

1. Sign in to the **AWS Management Console** using your **master/management account**
2. Go to **IAM Identity Center** (search for "IAM Identity Center" or "SSO")
3. Click **Enable** if not already enabled
4. Choose your preferred **region** (typically `us-east-1`) — this cannot be changed later
5. Under **Settings → Identity source**, note down:
   - **IAM Identity Center ARN** (e.g., `arn:aws:sso:::instance/ssoins-abc123def456`)
   - **Identity store ID** (e.g., `d-1234567890`)
   - **SSO Start URL** (e.g., `https://d-1234567890.awsapps.com/start`)

### Step 2: Create a SAML Application in Google Workspace

1. Go to [Google Admin Console](https://admin.google.com) → **Apps** → **Web and mobile apps**
2. Click **Add app** → **Search for apps**
3. Search for **"Amazon Web Services"** and select **"Amazon Web Services (AWS IAM Identity Center)"**
   - If it does not appear, select **Add custom SAML app** instead
4. On the **Google Identity Provider details** page:
   - Click **Download Metadata** — save this XML file (you'll upload it to AWS)
   - Note the **SSO URL**, **Entity ID**, and **Certificate**
   - Click **Continue**
5. On the **Service provider details** page:
   - **ACS URL**: `https://<your-region>.signin.aws.amazon.com/platform/saml/acs/<sso-instance-id>`
   - **Entity ID**: `https://<your-region>.signin.aws.amazon.com/platform/saml/d-<identity-store-id>`
   - **Start URL** (optional): Your SSO start URL from Step 1
   - **Name ID format**: `EMAIL`
   - **Name ID**: `Basic Information > Primary email`
   - Click **Continue**
6. On the **Attribute mapping** page, add these mappings:

   | Google Directory Attribute | AWS IAM Identity Center Attribute |
   |---|---|
   | `Basic Information > Primary email` | `Subject` (Name ID) |
   | `Basic Information > First name` | `https://aws.amazon.com/SAML/Attributes/RoleSessionName` |
   | `Basic Information > Primary email` | `https://aws.amazon.com/SAML/Attributes/SessionDuration` |

   For SCIM-based provisioning (recommended), also add:

   | Google Directory Attribute | AWS Attribute |
   |---|---|
   | `Basic Information > Primary email` | `email` |
   | `Basic Information > First name` | `firstName` |
   | `Basic Information > Last name` | `lastName` |
   | `Basic Information > Primary email` | `displayName` |

7. Click **Finish**
8. On the app page, click the **down arrow** next to "User access" and set:
   - **ON for everyone** (or restrict to specific OUs/groups)
   - Click **Save**

### Step 3: Configure SAML in AWS IAM Identity Center

1. In the **AWS IAM Identity Center** console, go to **Settings**
2. Under **Identity source**, click **Actions** → **Change identity source**
3. Select **External identity provider**
4. Upload the **Google IdP metadata XML** file you downloaded in Step 2
5. Alternatively, manually enter:
   - **IdP sign-in URL**: The SSO URL from Google
   - **IdP issuer URL**: The Entity ID from Google
   - **IdP certificate**: The certificate from Google
6. Under **Provisioning**, note the:
   - **SCIM endpoint URL** (e.g., `https://scim.us-east-1.amazonaws.com/abc123.../scim/v2`)
   - **Access token** — click **Generate token** and save this securely
7. Click **Save changes**

### Step 4: Set Up SCIM Provisioning (Automatic User/Group Sync)

SCIM provisioning automatically syncs users and groups from Google Workspace to AWS IAM Identity Center. This is the recommended approach.

1. Go back to [Google Admin Console](https://admin.google.com) → **Apps** → **Web and mobile apps**
2. Click on your **Amazon Web Services (AWS IAM Identity Center)** app
3. Click **Auto-provisioning** (in the left sidebar)
4. Click **Set up auto-provisioning**
5. Enter the details from AWS:
   - **SCIM endpoint URL**: The URL from Step 3, item 6
   - **Access token**: The token from Step 3, item 6
6. Under **Provisioning scope**, select which attributes to sync:
   - **First name** ✓
   - **Last name** ✓
   - **Primary email** ✓
   - **Groups** ✓ (critical for group-based access)
7. Click **Save** and then toggle auto-provisioning **ON**
8. Click **Authorize** to allow Google to push changes to AWS

**IMPORTANT SCIM Notes:**
- SCIM sync happens approximately every 30-40 minutes automatically
- You can trigger a manual sync from the Google Admin Console
- Group membership changes propagate via SCIM
- Users are deprovisioned in AWS when removed from the Google app
- SCIM tokens expire after 1 year — set a calendar reminder to rotate them

### Step 5: Configure Google Workspace Groups

Create groups in Google Workspace that map to your AWS access patterns:

1. Go to [Google Admin Console](https://admin.google.com) → **Directory** → **Groups**
2. Create the following groups (or your own custom groups):

| Google Workspace Group | Purpose | Suggested Members |
|---|---|---|
| `aws-admins@yourdomain.com` | Full admin access to all AWS accounts | CTO, Lead DevOps, Senior Platform Engineers |
| `aws-developers@yourdomain.com` | Developer access to dev/staging, read-only in prod | All developers |
| `aws-readonly@yourdomain.com` | Read-only access across all accounts | All engineering, QA |
| `aws-securityaudit@yourdomain.com` | Security audit access | Security team |
| `aws-billing@yourdomain.com` | Billing and cost management | Finance, Engineering Managers |
| `aws-devops@yourdomain.com` | Infrastructure and CI/CD management | DevOps/Platform team |

3. Add appropriate members to each group
4. Ensure SCIM is configured to sync these groups to AWS (Step 4)
5. Wait for SCIM sync to complete (or trigger manual sync)
6. Verify groups appear in **IAM Identity Center → Groups** in the AWS console

**Naming Convention:** The groups in this Terraform config use `AWS-Admins`, `AWS-Developers`, etc. as the display names in IAM Identity Center. When SCIM syncs from Google, it uses the Google group name (e.g., `aws-admins@yourdomain.com`). You can either:
- Rename the groups in the Terragrunt config to match Google's naming, or
- Create the groups manually in IAM Identity Center with matching names

---

## AWS CLI Profile Setup

Configure named profiles for each AWS account. The Terragrunt configs reference these profiles.

Add the following to `~/.aws/config`:

```ini
# Master/management account — used for all SSO operations
[profile master-admin]
region = us-east-1
# Option A: Static credentials (for initial bootstrap only)
# aws_access_key_id = AKIA...
# aws_secret_access_key = ...
# Option B: SSO (after SSO is set up)
# sso_start_url = https://d-1234567890.awsapps.com/start
# sso_region = us-east-1
# sso_account_id = 111111111111
# sso_role_name = AdministratorAccess

# Workload accounts (for other Terraform work, not needed for SSO deployment)
[profile workload-dev-admin]
region = us-east-1
role_arn = arn:aws:iam::222222222222:role/OrganizationAccountAccessRole
source_profile = master-admin

[profile workload-staging-admin]
region = us-east-1
role_arn = arn:aws:iam::333333333333:role/OrganizationAccountAccessRole
source_profile = master-admin

[profile workload-prod-admin]
region = us-east-1
role_arn = arn:aws:iam::444444444444:role/OrganizationAccountAccessRole
source_profile = master-admin
```

---

## Deployment Guide

### Step 1: Configure Account IDs and Profiles

Update the following files with your actual AWS account IDs and CLI profile names:

| File | What to Change |
|---|---|
| `environments/master/account.hcl` | `aws_account_id`, `aws_profile` |
| `environments/workload-dev/account.hcl` | `aws_account_id`, `aws_profile` |
| `environments/workload-staging/account.hcl` | `aws_account_id`, `aws_profile` |
| `environments/workload-prod/account.hcl` | `aws_account_id`, `aws_profile` |
| `environments/workload-dev/.../sso-account-assignments/terragrunt.hcl` | `dev_account_id`, provider profile |
| `environments/workload-staging/.../sso-account-assignments/terragrunt.hcl` | `staging_account_id`, provider profile |
| `environments/workload-prod/.../sso-account-assignments/terragrunt.hcl` | `prod_account_id`, provider profile |

### Step 2: Deploy SSO Configuration (Master Account)

This creates the SSO groups in the Identity Store. If you use SCIM and groups are already synced, you can skip this or use it as a safety net.

```bash
cd environments/master/us-east-1/sso-configuration
terragrunt init
terragrunt plan
terragrunt apply
```

### Step 3: Deploy Permission Sets (Master Account)

This creates all permission sets (AdministratorAccess, DeveloperAccess, ReadOnlyAccess, etc.):

```bash
cd environments/master/us-east-1/sso-permission-sets
terragrunt init
terragrunt plan
terragrunt apply
```

### Step 4: Deploy Account Assignments (Per Account)

Deploy assignments for each target account. **All assignments are made from the master account** — the provider is configured to use the master profile.

```bash
# Dev account assignments
cd environments/workload-dev/us-east-1/sso-account-assignments
terragrunt init
terragrunt plan
terragrunt apply

# Staging account assignments
cd environments/workload-staging/us-east-1/sso-account-assignments
terragrunt init
terragrunt plan
terragrunt apply

# Production account assignments
cd environments/workload-prod/us-east-1/sso-account-assignments
terragrunt init
terragrunt plan
terragrunt apply
```

### Deploy Everything at Once

Terragrunt can deploy all modules in dependency order:

```bash
# From the repository root
terragrunt run-all plan
terragrunt run-all apply
```

**Note:** `run-all` respects the `dependency` blocks, so it will deploy in the correct order:
1. `sso-configuration` (first)
2. `sso-permission-sets` (depends on sso-configuration)
3. `sso-account-assignments` for all accounts (depends on both above)

---

## Modules Reference

### sso-configuration

**Path:** `modules/sso-configuration/`

Creates and manages the IAM Identity Center groups, users, and memberships in the Identity Store.

| Input | Type | Description |
|---|---|---|
| `sso_groups` | `list(object)` | Groups to create (name, description) |
| `sso_users` | `list(object)` | Users to create (user_name, display_name, names, email) |
| `group_memberships` | `list(object)` | Group-to-user membership mappings |
| `tags` | `map(string)` | Resource tags |

| Output | Description |
|---|---|
| `sso_instance_arn` | ARN of the IAM Identity Center instance |
| `identity_store_id` | Identity Store ID |
| `sso_groups` | Map of group name to group details |
| `sso_users` | Map of user name to user details |
| `sso_start_url` | SSO portal start URL |

### sso-permission-sets

**Path:** `modules/sso-permission-sets/`

Creates permission sets with managed policies, inline policies, customer-managed policies, and permissions boundaries.

| Input | Type | Description |
|---|---|---|
| `permission_sets` | `list(object)` | Permission set definitions (see variables.tf for full schema) |
| `tags` | `map(string)` | Resource tags |

| Output | Description |
|---|---|
| `permission_sets` | Map of permission set name to details (ARN, duration) |
| `permission_set_arns` | Flat map of name to ARN |
| `sso_instance_arn` | ARN of the IAM Identity Center instance |

### sso-account-assignments

**Path:** `modules/sso-account-assignments/`

Assigns groups or users to specific AWS accounts with a specific permission set.

| Input | Type | Description |
|---|---|---|
| `account_assignments` | `list(object)` | List of assignments (account_id, permission_set_name, principal_type, principal_name) |
| `tags` | `map(string)` | Resource tags |

| Output | Description |
|---|---|
| `account_assignments` | Map of assignment details |
| `sso_instance_arn` | ARN of the IAM Identity Center instance |
| `identity_store_id` | Identity Store ID |

---

## Permission Sets Reference

| Permission Set | Description | Session Duration | Policies |
|---|---|---|---|
| **AdministratorAccess** | Full admin access | 4 hours | `AdministratorAccess` managed policy |
| **PowerUserAccess** | Everything except IAM/Org | 8 hours | `PowerUserAccess` managed policy |
| **DeveloperAccess** | Developer services, no IAM/SSO/Org changes | 8 hours | `PowerUserAccess` + deny inline policy |
| **ReadOnlyAccess** | View-only access | 12 hours | `ReadOnlyAccess` managed policy |
| **SecurityAudit** | Security-focused read access | 8 hours | `SecurityAudit` + `ReadOnlyAccess` |
| **BillingAccess** | Cost and billing management | 8 hours | `Billing` + `AWSBillingReadOnlyAccess` |
| **DevOpsAccess** | Infrastructure/CI-CD + IAM role management | 8 hours | `PowerUserAccess` + IAM role allow + deny inline |
| **DatabaseAdmin** | Database service administration | 8 hours | `DatabaseAdministrator` |

---

## Group-to-Account Access Matrix

This is the default configuration. Customize per your organization's needs.

| Group | Dev Account | Staging Account | Prod Account |
|---|---|---|---|
| **AWS-Admins** | AdministratorAccess | AdministratorAccess | AdministratorAccess |
| **AWS-Developers** | DeveloperAccess | DeveloperAccess | ReadOnlyAccess |
| **AWS-DevOps** | DevOpsAccess | DevOpsAccess | DevOpsAccess |
| **AWS-ReadOnly** | ReadOnlyAccess | ReadOnlyAccess | ReadOnlyAccess |
| **AWS-SecurityAudit** | SecurityAudit | SecurityAudit | SecurityAudit |
| **AWS-Billing** | — | — | BillingAccess |

**Design rationale:**
- **Developers** get full developer access in dev/staging but only read-only in production (principle of least privilege)
- **Admins** get full access everywhere as a break-glass mechanism
- **DevOps** gets infrastructure management access everywhere (they manage deployments)
- **Billing** is only assigned to the production account (where costs matter most)
- **SecurityAudit** has read-only security access everywhere

---

## Adding a New AWS Account

1. **Create the account directory structure:**

```bash
mkdir -p environments/workload-newaccount/us-east-1/sso-account-assignments
```

2. **Create `account.hcl`:**

```hcl
# environments/workload-newaccount/account.hcl
locals {
  account_name   = "workload-newaccount"
  aws_account_id = "555555555555"
  aws_profile    = "workload-newaccount-admin"
}
```

3. **Create `region.hcl`:**

```hcl
# environments/workload-newaccount/us-east-1/region.hcl
locals {
  aws_region = "us-east-1"
}
```

4. **Create the assignments `terragrunt.hcl`** — copy from an existing account and modify the `account_id` and assignments list.

5. **Deploy:**

```bash
cd environments/workload-newaccount/us-east-1/sso-account-assignments
terragrunt apply
```

---

## Adding a New Permission Set

1. Edit `environments/master/us-east-1/sso-permission-sets/terragrunt.hcl`
2. Add a new entry to the `permission_sets` list:

```hcl
{
  name             = "DataScientistAccess"
  description      = "Access to SageMaker, Athena, Glue, S3 for data science workloads"
  session_duration = "PT8H"
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess",
    "arn:aws:iam::aws:policy/AmazonAthenaFullAccess",
    "arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess",
  ]
}
```

3. Deploy: `cd environments/master/us-east-1/sso-permission-sets && terragrunt apply`
4. Add assignments using this permission set in the relevant account assignment configs

---

## Adding a New Group

1. **Create the group in Google Workspace** (Admin Console → Directory → Groups)
2. **Wait for SCIM sync** (or trigger manual sync)
3. If managing groups via Terraform (not SCIM), add to `environments/master/us-east-1/sso-configuration/terragrunt.hcl`:

```hcl
{
  name        = "AWS-DataScience"
  description = "Data science team access"
}
```

4. Deploy sso-configuration: `cd environments/master/us-east-1/sso-configuration && terragrunt apply`
5. Add account assignments for the new group in the relevant account configs

---

## SCIM vs Terraform-Managed Users/Groups

You have two approaches for managing users and groups. Choose one:

### Option A: SCIM Auto-Provisioning (Recommended)

- Google Workspace automatically syncs users/groups to AWS via SCIM
- Terraform manages only **permission sets** and **account assignments**
- The `sso-configuration` module can be skipped (or used as a fallback)
- Group names in Terraform account assignments must match the SCIM-synced display names exactly
- **Pros:** Single source of truth (Google), automatic sync, less Terraform to manage
- **Cons:** 30-40 minute sync delay, dependency on SCIM token rotation

### Option B: Terraform-Managed Groups

- Groups and users are created via the `sso-configuration` module
- No SCIM — manual user management or scripted sync
- **Pros:** Full IaC control, no external dependency, instant changes
- **Cons:** Dual maintenance (Google groups for email, AWS groups for access), no automatic sync

### Hybrid Approach

- Use SCIM for user provisioning (user lifecycle management)
- Use Terraform for group creation and account assignments
- This gives you IaC control over the access model while Google manages user identity

---

## Using SSO with the AWS CLI

After SSO is configured, team members can use SSO-based profiles:

### Initial Login

```bash
aws sso login --profile dev-developer
```

This opens a browser for Google Workspace authentication.

### AWS CLI Profile Configuration

Add SSO profiles to `~/.aws/config`:

```ini
# Example: Developer access to dev account
[profile dev-developer]
sso_start_url = https://d-1234567890.awsapps.com/start
sso_region = us-east-1
sso_account_id = 222222222222
sso_role_name = DeveloperAccess
region = us-east-1
output = json

# Example: Read-only access to production
[profile prod-readonly]
sso_start_url = https://d-1234567890.awsapps.com/start
sso_region = us-east-1
sso_account_id = 444444444444
sso_role_name = ReadOnlyAccess
region = us-east-1
output = json

# Example: Admin access to production (break-glass)
[profile prod-admin]
sso_start_url = https://d-1234567890.awsapps.com/start
sso_region = us-east-1
sso_account_id = 444444444444
sso_role_name = AdministratorAccess
region = us-east-1
output = json
```

### Using Profiles

```bash
# Use a specific profile
aws s3 ls --profile dev-developer

# Set default profile for a terminal session
export AWS_PROFILE=dev-developer
aws s3 ls

# Use with Terraform
AWS_PROFILE=dev-developer terraform plan
```

### SSO Login Helper Script

Create a helper to login and configure credentials:

```bash
#!/bin/bash
# sso-login.sh - Log in to AWS SSO
PROFILE=${1:-dev-developer}
aws sso login --profile "$PROFILE"
echo "Logged in with profile: $PROFILE"
echo "Run: export AWS_PROFILE=$PROFILE"
```

---

## Troubleshooting

### SAML authentication fails

- Verify the **ACS URL** and **Entity ID** in Google Admin match your AWS region and Identity Center instance
- Check that the SAML app is **turned ON** for the user's OU in Google Admin
- Ensure the **Name ID** format is set to `EMAIL` in Google
- Check AWS CloudTrail for SAML authentication events

### SCIM sync not working

- Verify the SCIM endpoint URL and token in Google Admin → Auto-provisioning
- Check if the SCIM token has expired (tokens last 1 year)
- Ensure the groups you want to sync are assigned to the SAML app in Google
- Look at the Google Admin audit logs for SCIM push errors
- Trigger a manual sync from Google Admin

### "Permission set not found" errors

- Permission sets must be deployed BEFORE account assignments
- Ensure the permission set name in assignments exactly matches the name in the permission sets module
- Run `terragrunt run-all apply` from the root to respect dependency order

### "Group not found" errors in account assignments

- If using SCIM: wait for sync to complete, then verify group exists in IAM Identity Center → Groups
- If using Terraform-managed groups: deploy `sso-configuration` before `sso-account-assignments`
- The `principal_name` must exactly match the group's `DisplayName` in the Identity Store

### "Access denied" when making account assignments

- Account assignments must be made from the **master/management account**
- Verify the AWS provider profile in the account assignment terragrunt.hcl points to the master account
- The IAM user/role used must have `sso:*` and `identitystore:*` permissions

### Terragrunt dependency errors

- Run `terragrunt run-all init` before `run-all plan/apply`
- If mock outputs are stale, update them in the `dependency` blocks
- Use `terragrunt run-all validate` to check configurations

### Users can see the SSO portal but no accounts

- Verify that account assignments exist for the user's group(s)
- Check that the permission set is properly attached to the assignment
- Ensure the user is a member of the correct Google Workspace group
- Wait for SCIM sync if group membership was recently changed

---

## Security Considerations

1. **Principle of least privilege:** The default configuration gives developers read-only access to production. Customize based on your needs.

2. **Session durations:** Admin access has shorter sessions (4 hours) while read-only has longer (12 hours). Adjust in the permission sets.

3. **SCIM token rotation:** SCIM tokens expire after 1 year. Set a calendar reminder. Rotate via:
   - AWS Console → IAM Identity Center → Settings → Provisioning → Regenerate token
   - Update the token in Google Admin Console

4. **Break-glass access:** The `AdministratorAccess` permission set serves as break-glass. Consider:
   - Requiring MFA for admin access
   - Using AWS CloudTrail to monitor admin actions
   - Setting up alerts for admin role assumption

5. **Permission boundaries:** The permission sets module supports permissions boundaries. Use them to set maximum permissions that cannot be exceeded.

6. **Audit trail:** All SSO sign-ins are logged in AWS CloudTrail. Enable CloudTrail in all accounts for complete visibility.

7. **No long-lived credentials:** SSO eliminates the need for IAM users and long-lived access keys. Enforce this by setting an SCP that denies `iam:CreateAccessKey`.

---

## Cost

- **IAM Identity Center:** Free — no additional charge for SSO
- **AWS Organizations:** Free
- **Google Workspace:** Requires a Google Workspace subscription (Business Starter or higher)
- **Terraform state storage:** Minimal S3 + DynamoDB costs (~$1/month)

---

## License

MIT
