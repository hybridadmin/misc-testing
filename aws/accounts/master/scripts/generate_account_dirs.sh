#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# generate_account_dirs.sh
#
# Queries AWS Organizations to discover accounts in the target OUs and
# generates the Terragrunt directory structure for each account/region
# combination, including all sub-account modules.
#
# Usage:
#   ./scripts/generate_account_dirs.sh [--dry-run]
#
# Prerequisites:
#   - AWS CLI v2 configured with credentials that can call
#     organizations:ListAccountsForParent
#   - jq installed
#
# This script reads live/env.hcl to get the target OUs and regions, then
# creates the following structure for each active account in each target OU:
#
#   live/<account_name>/<region>/region.hcl
#   live/<account_name>/account.hcl
#
# Primary-region modules (first region listed):
#   common-resources, config-recorder, config-rules,
#   cross-account-roles, security-alarms
#
# Secondary-region modules (all other regions):
#   common-resources, config-recorder
#
# The management account and audit account (identified by account ID in
# common_vars.hcl) are SKIPPED -- they have their own dedicated layouts.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LIVE_DIR="${ROOT_DIR}/live"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "[DRY RUN] No files will be created."
    echo ""
fi

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
if ! command -v aws &>/dev/null; then
    echo "Error: aws CLI not found. Install it first."
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "Error: jq not found. Install it first."
    exit 1
fi

if [[ ! -f "${LIVE_DIR}/env.hcl" ]]; then
    echo "Error: ${LIVE_DIR}/env.hcl not found"
    exit 1
fi

if [[ ! -f "${LIVE_DIR}/_envcommon/common_vars.hcl" ]]; then
    echo "Error: ${LIVE_DIR}/_envcommon/common_vars.hcl not found"
    exit 1
fi

# ---------------------------------------------------------------------------
# Parse env.hcl for target_ou_ids and target_regions
# ---------------------------------------------------------------------------
TARGET_OUS=$(grep -A 20 'target_ou_ids' "${LIVE_DIR}/env.hcl" \
    | grep -oE '"ou-[^"]+' \
    | sed 's/"//')

TARGET_REGIONS=$(grep -A 20 'target_regions' "${LIVE_DIR}/env.hcl" \
    | grep -oE '"[a-z]+-[a-z]+-[0-9]+"' \
    | sed 's/"//g')

if [[ -z "$TARGET_OUS" ]]; then
    echo "No target_ou_ids found in ${LIVE_DIR}/env.hcl"
    exit 1
fi

if [[ -z "$TARGET_REGIONS" ]]; then
    echo "No target_regions found in ${LIVE_DIR}/env.hcl"
    exit 1
fi

# First region is treated as primary (gets all modules)
PRIMARY_REGION=$(echo "$TARGET_REGIONS" | head -1)

# Parse skip account IDs from common_vars.hcl (audit + management accounts)
AUDIT_ACCOUNT_ID=$(grep 'audit_account_id' "${LIVE_DIR}/_envcommon/common_vars.hcl" \
    | grep -oE '[0-9]{12}' | head -1)
IDENTITY_ACCOUNT_ID=$(grep 'identity_account_id' "${LIVE_DIR}/_envcommon/common_vars.hcl" \
    | grep -oE '[0-9]{12}' | head -1)

SKIP_ACCOUNT_IDS="${AUDIT_ACCOUNT_ID:-} ${IDENTITY_ACCOUNT_ID:-}"

echo "Configuration:"
echo "  Target OUs:       $(echo "$TARGET_OUS" | tr '\n' ' ')"
echo "  Target Regions:   $(echo "$TARGET_REGIONS" | tr '\n' ' ')"
echo "  Primary Region:   ${PRIMARY_REGION}"
echo "  Skip Account IDs: ${SKIP_ACCOUNT_IDS}"
echo ""

# ---------------------------------------------------------------------------
# Modules to deploy per region type
# ---------------------------------------------------------------------------
PRIMARY_MODULES="common-resources config-recorder config-rules cross-account-roles security-alarms"
SECONDARY_MODULES="common-resources config-recorder"

# ---------------------------------------------------------------------------
# Helper: sanitise AWS account name for use as a directory name
# ---------------------------------------------------------------------------
sanitize_name() {
    local name="$1"
    # Lowercase, replace spaces/underscores with hyphens, strip non-alphanum
    echo "$name" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[_ ]/-/g' \
        | sed 's/[^a-z0-9-]//g' \
        | sed 's/--*/-/g' \
        | sed 's/^-//;s/-$//'
}

# ---------------------------------------------------------------------------
# Helper: compute relative path from a leaf module dir to modules/
# ---------------------------------------------------------------------------
# Structure: live/<account>/<region>/<module>/terragrunt.hcl
# Relative to modules: ../../../../modules//<module>
# But since root terragrunt.hcl is at live/terragrunt.hcl
# the module source is always relative from the leaf dir to ROOT_DIR/modules
modules_relative_path() {
    echo "../../../../modules"
}

# ---------------------------------------------------------------------------
# Create the terragrunt.hcl for a given module
# ---------------------------------------------------------------------------
create_module_terragrunt() {
    local module_name="$1"
    local module_dir="$2"

    case "$module_name" in
        common-resources)
            cat > "${module_dir}/terragrunt.hcl" <<'TGEOF'
# Auto-generated by generate_account_dirs.sh

include "root" {
  path = find_in_parent_folders()
}

locals {
  common_vars = read_terragrunt_config("${get_terragrunt_dir()}/../../../_envcommon/common_vars.hcl")
}

terraform {
  source = "../../../../modules//common-resources"
}

inputs = {
  critical_notifications_email = local.common_vars.locals.critical_notifications_email
  general_notifications_email  = local.common_vars.locals.general_notifications_email
}
TGEOF
            ;;

        config-recorder)
            cat > "${module_dir}/terragrunt.hcl" <<'TGEOF'
# Auto-generated by generate_account_dirs.sh

include "root" {
  path = find_in_parent_folders()
}

locals {
  common_vars = read_terragrunt_config("${get_terragrunt_dir()}/../../../_envcommon/common_vars.hcl")
}

terraform {
  source = "../../../../modules//config-recorder"
}

inputs = {
  config_s3_bucket_name = local.common_vars.locals.config_bucket_name
  config_kms_key_arn    = local.common_vars.locals.config_kms_key_arn
}
TGEOF
            ;;

        config-rules)
            cat > "${module_dir}/terragrunt.hcl" <<'TGEOF'
# Auto-generated by generate_account_dirs.sh

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../../modules//config-rules"
}

inputs = {
  primary_region    = "eu-west-1"
  excluded_regions  = ["af-south-1"]
  mandatory_tag_key = "description"
}
TGEOF
            ;;

        cross-account-roles)
            cat > "${module_dir}/terragrunt.hcl" <<'TGEOF'
# Auto-generated by generate_account_dirs.sh

include "root" {
  path = find_in_parent_folders()
}

locals {
  common_vars = read_terragrunt_config("${get_terragrunt_dir()}/../../../_envcommon/common_vars.hcl")
}

terraform {
  source = "../../../../modules//cross-account-roles"
}

inputs = {
  identity_account_id = local.common_vars.locals.identity_account_id
}
TGEOF
            ;;

        security-alarms)
            cat > "${module_dir}/terragrunt.hcl" <<'TGEOF'
# Auto-generated by generate_account_dirs.sh

include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../../modules//security-alarms"
}

inputs = {
  stack_name         = "security-alarms"
  security_hub_rules = true
  external_idp       = false
}
TGEOF
            ;;

        *)
            echo "    Warning: Unknown module ${module_name}, skipping terragrunt.hcl generation"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
ACCOUNT_COUNT=0
DIR_COUNT=0

for OU_ID in $TARGET_OUS; do
    echo "Querying accounts in OU: ${OU_ID}..."

    ACCOUNTS=$(aws organizations list-accounts-for-parent \
        --parent-id "$OU_ID" \
        --query "Accounts[?Status=='ACTIVE'].[Id,Name]" \
        --output text 2>/dev/null || true)

    if [[ -z "$ACCOUNTS" ]]; then
        echo "  Warning: No active accounts found in OU ${OU_ID} (or insufficient permissions)"
        continue
    fi

    while IFS=$'\t' read -r ACCOUNT_ID ACCOUNT_NAME; do
        # Skip audit and management accounts
        if echo "$SKIP_ACCOUNT_IDS" | grep -qw "$ACCOUNT_ID"; then
            echo "  Skipping ${ACCOUNT_NAME} (${ACCOUNT_ID}) -- audit/management account"
            continue
        fi

        DIR_NAME=$(sanitize_name "$ACCOUNT_NAME")
        ACCOUNT_DIR="${LIVE_DIR}/${DIR_NAME}"

        echo "  Account: ${ACCOUNT_NAME} (${ACCOUNT_ID}) -> ${DIR_NAME}/"

        # Create account.hcl if it doesn't exist
        if [[ ! -f "${ACCOUNT_DIR}/account.hcl" ]]; then
            if [[ "$DRY_RUN" == false ]]; then
                mkdir -p "$ACCOUNT_DIR"
                cat > "${ACCOUNT_DIR}/account.hcl" <<EOF
# Auto-generated by generate_account_dirs.sh
# Account: ${ACCOUNT_NAME}
# OU: ${OU_ID}

locals {
  account_name = "${DIR_NAME}"
  account_id   = "${ACCOUNT_ID}"
}
EOF
            fi
            echo "    Created: ${DIR_NAME}/account.hcl"
        else
            echo "    Exists:  ${DIR_NAME}/account.hcl"
        fi

        for REGION in $TARGET_REGIONS; do
            REGION_DIR="${ACCOUNT_DIR}/${REGION}"

            # Create region.hcl if it doesn't exist
            if [[ ! -f "${REGION_DIR}/region.hcl" ]]; then
                if [[ "$DRY_RUN" == false ]]; then
                    mkdir -p "$REGION_DIR"
                    cat > "${REGION_DIR}/region.hcl" <<EOF
locals {
  aws_region = "${REGION}"
}
EOF
                fi
                echo "    Created: ${DIR_NAME}/${REGION}/region.hcl"
            fi

            # Determine which modules to deploy in this region
            if [[ "$REGION" == "$PRIMARY_REGION" ]]; then
                MODULES="$PRIMARY_MODULES"
            else
                MODULES="$SECONDARY_MODULES"
            fi

            for MODULE in $MODULES; do
                MODULE_DIR="${REGION_DIR}/${MODULE}"

                if [[ -d "$MODULE_DIR" ]]; then
                    echo "    Exists:  ${DIR_NAME}/${REGION}/${MODULE}/"
                    continue
                fi

                if [[ "$DRY_RUN" == false ]]; then
                    mkdir -p "$MODULE_DIR"
                    create_module_terragrunt "$MODULE" "$MODULE_DIR"
                fi
                echo "    Created: ${DIR_NAME}/${REGION}/${MODULE}/"
                DIR_COUNT=$((DIR_COUNT + 1))
            done
        done

        ACCOUNT_COUNT=$((ACCOUNT_COUNT + 1))
    done <<< "$ACCOUNTS"
done

echo ""
echo "Done. Processed ${ACCOUNT_COUNT} accounts, created ${DIR_COUNT} new module directories."
echo ""
if [[ "$DRY_RUN" == true ]]; then
    echo "This was a dry run. Re-run without --dry-run to create the directories."
else
    echo "To deploy all sub-accounts:"
    echo "  cd live && terragrunt run-all plan --exclude-dir management --exclude-dir audit"
    echo ""
    echo "To deploy a single account:"
    echo "  cd live/<account-name> && terragrunt run-all plan"
fi
