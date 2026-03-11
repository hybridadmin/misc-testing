output "iam_pack_arn" {
  description = "ARN of the IAM conformance pack"
  value       = var.enable_iam_pack ? aws_config_conformance_pack.iam[0].arn : ""
}

output "s3_pack_arn" {
  description = "ARN of the S3 conformance pack"
  value       = var.enable_s3_pack ? aws_config_conformance_pack.s3[0].arn : ""
}

output "pci_pack_arn" {
  description = "ARN of the PCI conformance pack"
  value       = var.enable_pci_pack ? aws_config_conformance_pack.pci[0].arn : ""
}

output "other_pack_arn" {
  description = "ARN of the Other conformance pack"
  value       = var.enable_other_pack ? aws_config_conformance_pack.other[0].arn : ""
}
