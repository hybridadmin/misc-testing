###############################################################################
# Config Recorder
# AWS Config Configuration Recorder and Delivery Channel.
###############################################################################

data "aws_caller_identity" "current" {}

resource "aws_config_configuration_recorder" "main" {
  name     = "default"
  role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "default"
  s3_bucket_name = var.config_s3_bucket_name
  s3_key_prefix  = var.config_s3_key_prefix != "" ? var.config_s3_key_prefix : null
  s3_kms_key_arn = var.config_kms_key_arn

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.main]
}
