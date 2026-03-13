#!/usr/bin/env bash
#
# generate_account_dirs.sh
#
# Scaffolds a new account directory under envs/ with account.hcl
# and module-specific terragrunt.hcl files.
#
# Usage:
#   ./scripts/generate_account_dirs.sh [--dry-run]
#
# The script will prompt for:
#   - Account name (used as directory name)
#   - 12-digit AWS account ID
#   - AWS region
#   - Which modules to include
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENVS_DIR="${BASE_DIR}/envs"
ENVCOMMON_DIR="${BASE_DIR}/_envcommon"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "[DRY RUN] No files will be created."
  echo ""
fi

# Discover available modules from _envcommon
AVAILABLE_MODULES=()
for f in "${ENVCOMMON_DIR}"/*.hcl; do
  mod=$(basename "$f" .hcl)
  AVAILABLE_MODULES+=("$mod")
done

echo "=== DevOps Bootstrap Account Scaffolding ==="
echo ""

# Prompt for account name
read -rp "Account name (e.g., dev, staging, prod): " ACCOUNT_NAME
ACCOUNT_NAME=$(echo "$ACCOUNT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')

if [[ -z "$ACCOUNT_NAME" ]]; then
  echo "ERROR: Account name cannot be empty."
  exit 1
fi

if [[ -d "${ENVS_DIR}/${ACCOUNT_NAME}" ]]; then
  echo "WARNING: Directory '${ENVS_DIR}/${ACCOUNT_NAME}' already exists."
  read -rp "Continue anyway? [y/N]: " CONTINUE
  if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Prompt for account ID
while true; do
  read -rp "AWS Account ID (12 digits): " ACCOUNT_ID
  if [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    break
  fi
  echo "ERROR: Account ID must be exactly 12 digits."
done

# Prompt for region
read -rp "AWS Region [eu-west-1]: " AWS_REGION
AWS_REGION="${AWS_REGION:-eu-west-1}"

# Prompt for modules
echo ""
echo "Available modules:"
for i in "${!AVAILABLE_MODULES[@]}"; do
  echo "  $((i + 1)). ${AVAILABLE_MODULES[$i]}"
done
echo "  A. All modules"
echo ""
read -rp "Select modules (comma-separated numbers, or 'A' for all): " MODULE_SELECTION

SELECTED_MODULES=()
if [[ "$MODULE_SELECTION" =~ ^[Aa]$ ]]; then
  SELECTED_MODULES=("${AVAILABLE_MODULES[@]}")
else
  IFS=',' read -ra SELECTIONS <<< "$MODULE_SELECTION"
  for sel in "${SELECTIONS[@]}"; do
    sel=$(echo "$sel" | tr -d ' ')
    idx=$((sel - 1))
    if [[ $idx -ge 0 && $idx -lt ${#AVAILABLE_MODULES[@]} ]]; then
      SELECTED_MODULES+=("${AVAILABLE_MODULES[$idx]}")
    else
      echo "WARNING: Ignoring invalid selection '$sel'"
    fi
  done
fi

if [[ ${#SELECTED_MODULES[@]} -eq 0 ]]; then
  echo "ERROR: No modules selected."
  exit 1
fi

# Summary
echo ""
echo "=== Summary ==="
echo "  Account Name: ${ACCOUNT_NAME}"
echo "  Account ID:   ${ACCOUNT_ID}"
echo "  Region:       ${AWS_REGION}"
echo "  Modules:      ${SELECTED_MODULES[*]}"
echo "  Target Dir:   ${ENVS_DIR}/${ACCOUNT_NAME}/"
echo ""

if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY RUN] Would create the following:"
  echo "  ${ENVS_DIR}/${ACCOUNT_NAME}/account.hcl"
  for mod in "${SELECTED_MODULES[@]}"; do
    echo "  ${ENVS_DIR}/${ACCOUNT_NAME}/${mod}/terragrunt.hcl"
  done
  exit 0
fi

read -rp "Proceed? [y/N]: " PROCEED
if [[ ! "$PROCEED" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# Create account.hcl
ACCOUNT_DIR="${ENVS_DIR}/${ACCOUNT_NAME}"
mkdir -p "$ACCOUNT_DIR"

ACCOUNT_HCL="${ACCOUNT_DIR}/account.hcl"
if [[ ! -f "$ACCOUNT_HCL" ]]; then
  cat > "$ACCOUNT_HCL" <<EOF
locals {
  account_name = "${ACCOUNT_NAME}"
  account_id   = "${ACCOUNT_ID}"
  aws_region   = "${AWS_REGION}"
}
EOF
  echo "Created: ${ACCOUNT_HCL}"
else
  echo "Skipped (exists): ${ACCOUNT_HCL}"
fi

# Create module terragrunt.hcl files
for mod in "${SELECTED_MODULES[@]}"; do
  MOD_DIR="${ACCOUNT_DIR}/${mod}"
  MOD_HCL="${MOD_DIR}/terragrunt.hcl"

  mkdir -p "$MOD_DIR"

  if [[ ! -f "$MOD_HCL" ]]; then
    cat > "$MOD_HCL" <<EOF
include "root" {
  path = find_in_parent_folders()
}

include "envcommon" {
  path   = "\${dirname(find_in_parent_folders())}/_envcommon/${mod}.hcl"
  expose = true
}

# Override inputs for this account if needed:
# inputs = {}
EOF
    echo "Created: ${MOD_HCL}"
  else
    echo "Skipped (exists): ${MOD_HCL}"
  fi
done

echo ""
echo "Done! Account '${ACCOUNT_NAME}' scaffolded successfully."
echo ""
echo "Next steps:"
echo "  1. Review and update ${ACCOUNT_HCL} with the correct account ID"
echo "  2. Add any per-account overrides in the module terragrunt.hcl files"
echo "  3. Deploy with: cd ${ACCOUNT_DIR} && terragrunt run-all plan"
