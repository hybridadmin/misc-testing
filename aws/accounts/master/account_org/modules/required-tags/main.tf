###############################################################################
# Required Tags
# Config rule checking resources for specified tags across 30 resource types.
###############################################################################

resource "aws_config_config_rule" "required_tags" {
  name        = var.config_rule_name
  description = "Checks whether your resources have the tags that you specify."

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  scope {
    compliance_resource_types = [
      "AWS::ACM::Certificate",
      "AWS::AutoScaling::AutoScalingGroup",
      "AWS::CloudFormation::Stack",
      "AWS::CodeBuild::Project",
      "AWS::DynamoDB::Table",
      "AWS::EC2::CustomerGateway",
      "AWS::EC2::Instance",
      "AWS::EC2::InternetGateway",
      "AWS::EC2::NetworkAcl",
      "AWS::EC2::NetworkInterface",
      "AWS::EC2::RouteTable",
      "AWS::EC2::SecurityGroup",
      "AWS::EC2::Subnet",
      "AWS::EC2::Volume",
      "AWS::EC2::VPC",
      "AWS::EC2::VPNConnection",
      "AWS::EC2::VPNGateway",
      "AWS::ElasticLoadBalancing::LoadBalancer",
      "AWS::ElasticLoadBalancingV2::LoadBalancer",
      "AWS::RDS::DBInstance",
      "AWS::RDS::DBSecurityGroup",
      "AWS::RDS::DBSnapshot",
      "AWS::RDS::DBSubnetGroup",
      "AWS::RDS::EventSubscription",
      "AWS::Redshift::Cluster",
      "AWS::Redshift::ClusterParameterGroup",
      "AWS::Redshift::ClusterSecurityGroup",
      "AWS::Redshift::ClusterSnapshot",
      "AWS::Redshift::ClusterSubnetGroup",
      "AWS::S3::Bucket",
    ]
  }

  input_parameters = jsonencode({
    for k, v in local.tag_params : k => v if v != ""
  })

  tags = var.tags
}

locals {
  tag_params = merge(
    var.tag1_key != "" ? { tag1Key = var.tag1_key } : {},
    var.tag1_value != "" ? { tag1Value = var.tag1_value } : {},
    var.tag2_key != "" ? { tag2Key = var.tag2_key } : {},
    var.tag2_value != "" ? { tag2Value = var.tag2_value } : {},
    var.tag3_key != "" ? { tag3Key = var.tag3_key } : {},
    var.tag3_value != "" ? { tag3Value = var.tag3_value } : {},
    var.tag4_key != "" ? { tag4Key = var.tag4_key } : {},
    var.tag4_value != "" ? { tag4Value = var.tag4_value } : {},
    var.tag5_key != "" ? { tag5Key = var.tag5_key } : {},
    var.tag5_value != "" ? { tag5Value = var.tag5_value } : {},
    var.tag6_key != "" ? { tag6Key = var.tag6_key } : {},
    var.tag6_value != "" ? { tag6Value = var.tag6_value } : {},
  )
}
