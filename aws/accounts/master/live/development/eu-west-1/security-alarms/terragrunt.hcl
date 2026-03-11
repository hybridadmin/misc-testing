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
