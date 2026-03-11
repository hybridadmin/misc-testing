###############################################################################
# Conformance Packs
# Organization-level AWS Config Conformance Packs for IAM, S3, PCI, and Other.
###############################################################################

# ------------------------------------------------------------------------------
# IAM Conformance Pack
# ------------------------------------------------------------------------------
resource "aws_config_conformance_pack" "iam" {
  count = var.enable_iam_pack ? 1 : 0
  name  = var.iam_pack_name

  input_parameter {
    parameter_name  = "AccessKeysRotatedParameterMaxAccessKeyAge"
    parameter_value = var.max_access_key_age
  }

  input_parameter {
    parameter_name  = "IAMUserUnusedCredentialsCheckParameterMaxCredentialUsageAge"
    parameter_value = var.max_credential_usage_age
  }

  template_body = file("${path.module}/templates/iam.yaml")
}

# ------------------------------------------------------------------------------
# S3 Conformance Pack
# ------------------------------------------------------------------------------
resource "aws_config_conformance_pack" "s3" {
  count = var.enable_s3_pack ? 1 : 0
  name  = var.s3_pack_name

  template_body = file("${path.module}/templates/s3.yaml")
}

# ------------------------------------------------------------------------------
# PCI Conformance Pack
# ------------------------------------------------------------------------------
resource "aws_config_conformance_pack" "pci" {
  count = var.enable_pci_pack ? 1 : 0
  name  = var.pci_pack_name

  template_body = file("${path.module}/templates/pci.yaml")
}

# ------------------------------------------------------------------------------
# Other Conformance Pack
# ------------------------------------------------------------------------------
resource "aws_config_conformance_pack" "other" {
  count = var.enable_other_pack ? 1 : 0
  name  = var.other_pack_name

  template_body = file("${path.module}/templates/other.yaml")
}
