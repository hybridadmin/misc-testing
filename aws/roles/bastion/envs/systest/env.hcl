# -----------------------------------------------------------------------------
# envs/systest/env.hcl
#
# Environment-level variables for the systest environment.
# Deployed to a single account (the management/devops account).
# -----------------------------------------------------------------------------

locals {
  project     = "devops"
  service     = "bastion"
  environment = "systest"
  account_id  = "000000000000"

  # Networking - these should reference actual VPC outputs or be set per-env
  vpc_id            = "vpc-xxxxxxxxxxxxxxxxx"
  vpc_cidr          = "10.0.0.0/16"
  public_subnet_ids = ["subnet-xxxxxxxxxxxxxxxxx", "subnet-yyyyyyyyyyyyyyyyy"]

  # Instance
  ami_id        = "ami-xxxxxxxxxxxxxxxxx"  # Update with current AMI
  instance_type = "t3.micro"
  ssh_port      = 22

  # SSH / VPN access
  vpn_cidrs = [
    { cidr = "203.0.113.1/32", description = "VPN Server (eu-west-1)" },
    { cidr = "203.0.113.2/32", description = "VPN Server (af-south-1)" },
    { cidr = "203.0.113.3/32", description = "MOYA VPN Server (eu-west-1)" },
    { cidr = "203.0.113.4/32", description = "MOYA VPN Server (af-south-1)" },
  ]

  # Icinga monitoring
  icinga_ips = ["203.0.113.10", "203.0.113.11"]

  # Monitoring
  cpu_warning_threshold = 80
  log_retention_days    = 180

  # SNS topics [critical, general]
  sns_topic_arns = [
    "arn:aws:sns:eu-west-1:000000000000:devops-events-critical",
    "arn:aws:sns:eu-west-1:000000000000:devops-events-general",
  ]

  # S3
  project_bucket_arn      = "arn:aws:s3:::devops-systest-project-bucket"
  project_bucket_name     = "devops-systest-project-bucket"
  authorized_users_bucket = "moya-internal"

  # DNS / Route53
  hosted_zone_id = "Z00000000000000000000"
  route53_zone_ids = [
    "Z00000000000000000000",  # systest hosted zone
    "Z00000000000000000001",  # shared zone 1
    "Z00000000000000000002",  # shared zone 2
    "Z00000000000000000003",  # shared zone 3
  ]

  # Service Discovery
  service_discovery_namespace_id = "ns-xxxxxxxxxxxxxxxxx"

  # Git
  git_repo_url = "git@github.com:example-org/example-devops-infrastructure.git"
}
