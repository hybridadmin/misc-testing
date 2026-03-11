variable "config_rule_name" {
  description = "Name of the AWS Config rule"
  type        = string
  default     = "required-tags"
}

variable "tag1_key" {
  description = "Key of the first required tag"
  type        = string
  default     = "CostCenter"
}

variable "tag1_value" {
  description = "Optional value of the first required tag"
  type        = string
  default     = ""
}

variable "tag2_key" {
  description = "Key of the second required tag"
  type        = string
  default     = ""
}

variable "tag2_value" {
  description = "Optional value of the second required tag"
  type        = string
  default     = ""
}

variable "tag3_key" {
  description = "Key of the third required tag"
  type        = string
  default     = ""
}

variable "tag3_value" {
  description = "Optional value of the third required tag"
  type        = string
  default     = ""
}

variable "tag4_key" {
  description = "Key of the fourth required tag"
  type        = string
  default     = ""
}

variable "tag4_value" {
  description = "Optional value of the fourth required tag"
  type        = string
  default     = ""
}

variable "tag5_key" {
  description = "Key of the fifth required tag"
  type        = string
  default     = ""
}

variable "tag5_value" {
  description = "Optional value of the fifth required tag"
  type        = string
  default     = ""
}

variable "tag6_key" {
  description = "Key of the sixth required tag"
  type        = string
  default     = ""
}

variable "tag6_value" {
  description = "Optional value of the sixth required tag"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
