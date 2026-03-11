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
