#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# generate_account_dirs.sh
#
# Interactively scaffolds the Terragrunt directory structure for a new AWS
# account in this project.  It creates:
#
#   envs/<account_name>/account.hcl
#   envs/<account_name>/cross-account-roles/terragrunt.hcl
#   envs/<account_name>/kms-keys/terragrunt.hcl
#
# Usage:
#   ./scripts/generate_account_dirs.sh [--dry-run]
#
# The script prompts for the account name, AWS account ID, and region, then
# generates the directory tree and boilerplate terragrunt.hcl files.
#
# Existing files are NEVER overwritten.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENVS_DIR="${ROOT_DIR}/envs"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "[DRY RUN] No files will be created."
    echo ""
fi

# ---------------------------------------------------------------------------
# Modules deployed to standard accounts (cross-account-roles + kms-keys)
# The backup-vault module is only for the dedicated backup account.
# ---------------------------------------------------------------------------
STANDARD_MODULES="cross-account-roles kms-keys"

# ---------------------------------------------------------------------------
# Prompt for account details
# ---------------------------------------------------------------------------
read -rp "Account name (e.g. dev, staging, prod): " ACCOUNT_NAME
read -rp "AWS account ID (12 digits): " ACCOUNT_ID
read -rp "AWS region [us-east-1]: " AWS_REGION
AWS_REGION="${AWS_REGION:-us-east-1}"

# Validate account ID
if [[ ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "Error: Account ID must be exactly 12 digits."
    exit 1
fi

# Sanitize the account name for directory use
DIR_NAME=$(echo "$ACCOUNT_NAME" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[_ ]/-/g' \
    | sed 's/[^a-z0-9-]//g' \
    | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//')

if [[ -z "$DIR_NAME" ]]; then
    echo "Error: Account name produced an empty directory name."
    exit 1
fi

ACCOUNT_DIR="${ENVS_DIR}/${DIR_NAME}"

echo ""
echo "Configuration:"
echo "  Account name: ${ACCOUNT_NAME}"
echo "  Account ID:   ${ACCOUNT_ID}"
echo "  Region:       ${AWS_REGION}"
echo "  Directory:    envs/${DIR_NAME}/"
echo "  Modules:      ${STANDARD_MODULES}"
echo ""

read -rp "Include backup-vault module? (y/N): " INCLUDE_BACKUP
if [[ "$INCLUDE_BACKUP" =~ ^[Yy]$ ]]; then
    MODULES="${STANDARD_MODULES} backup-vault"
else
    MODULES="$STANDARD_MODULES"
fi

# ---------------------------------------------------------------------------
# Create account.hcl
# ---------------------------------------------------------------------------
if [[ -f "${ACCOUNT_DIR}/account.hcl" ]]; then
    echo "Exists:  envs/${DIR_NAME}/account.hcl"
else
    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$ACCOUNT_DIR"
        cat > "${ACCOUNT_DIR}/account.hcl" <<EOF
# -----------------------------------------------------------------------------
# ${ACCOUNT_NAME} account configuration
# -----------------------------------------------------------------------------

locals {
  account_name = "${DIR_NAME}"
  account_id   = "${ACCOUNT_ID}"
  aws_region   = "${AWS_REGION}"
}
EOF
    fi
    echo "Created: envs/${DIR_NAME}/account.hcl"
fi

# ---------------------------------------------------------------------------
# Create module directories and terragrunt.hcl files
# ---------------------------------------------------------------------------
for MODULE in $MODULES; do
    MODULE_DIR="${ACCOUNT_DIR}/${MODULE}"

    if [[ -d "$MODULE_DIR" ]]; then
        echo "Exists:  envs/${DIR_NAME}/${MODULE}/"
        continue
    fi

    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$MODULE_DIR"

        # Title-case the module name for the comment header
        PRETTY_NAME=$(echo "$MODULE" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')

        cat > "${MODULE_DIR}/terragrunt.hcl" <<TGEOF
# -----------------------------------------------------------------------------
# ${PRETTY_NAME} -- ${ACCOUNT_NAME}
#
# Inherits everything from the envcommon config.
# Add account-specific overrides in the \`inputs\` block below.
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path   = "\${dirname(find_in_parent_folders())}/_envcommon/${MODULE}.hcl"
  expose = true
}

# Override inputs for this account if needed:
# inputs = {}
TGEOF
    fi
    echo "Created: envs/${DIR_NAME}/${MODULE}/"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ "$DRY_RUN" == true ]]; then
    echo "This was a dry run. Re-run without --dry-run to create the directories."
else
    echo "Done. Account '${DIR_NAME}' scaffolded successfully."
    echo ""
    echo "Next steps:"
    echo "  1. Review the generated files in envs/${DIR_NAME}/"
    echo "  2. Deploy:"
    echo "     cd envs/${DIR_NAME} && terragrunt run-all plan"
    echo "     cd envs/${DIR_NAME} && terragrunt run-all apply"
fi
