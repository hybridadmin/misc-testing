output "recorder_id" {
  description = "ID of the Config Configuration Recorder"
  value       = aws_config_configuration_recorder.main.id
}

output "delivery_channel_id" {
  description = "ID of the Config Delivery Channel"
  value       = aws_config_delivery_channel.main.id
}
