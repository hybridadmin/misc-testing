variable "enable_iam_pack" {
  description = "Enable IAM conformance pack"
  type        = bool
  default     = true
}

variable "enable_s3_pack" {
  description = "Enable S3 conformance pack"
  type        = bool
  default     = true
}

variable "enable_pci_pack" {
  description = "Enable PCI conformance pack"
  type        = bool
  default     = true
}

variable "enable_other_pack" {
  description = "Enable Other conformance pack"
  type        = bool
  default     = true
}

variable "iam_pack_name" {
  description = "Name for the IAM conformance pack"
  type        = string
  default     = "awsconfig-iam"
}

variable "s3_pack_name" {
  description = "Name for the S3 conformance pack"
  type        = string
  default     = "awsconfig-s3"
}

variable "pci_pack_name" {
  description = "Name for the PCI conformance pack"
  type        = string
  default     = "awsconfig-pci"
}

variable "other_pack_name" {
  description = "Name for the Other conformance pack"
  type        = string
  default     = "awsconfig-other"
}

variable "max_access_key_age" {
  description = "Maximum number of days without access key rotation"
  type        = string
  default     = "90"
}

variable "max_credential_usage_age" {
  description = "Maximum number of days a credential can be unused"
  type        = string
  default     = "90"
}

variable "delivery_s3_bucket" {
  description = "S3 bucket for conformance pack delivery"
  type        = string
  default     = ""
}
