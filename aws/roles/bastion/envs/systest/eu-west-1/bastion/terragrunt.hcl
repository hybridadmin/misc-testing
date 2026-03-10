# -----------------------------------------------------------------------------
# Deploys bastion into systest / eu-west-1
# -----------------------------------------------------------------------------

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

include "envcommon" {
  path   = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/bastion.hcl"
  expose = true
}

dependency "bastion_efs" {
  config_path = "../bastion-efs"

  mock_outputs = {
    efs_id = "fs-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  efs_filesystem_id = dependency.bastion_efs.outputs.efs_id
}
