# -----------------------------------------------------------------------------
# _envcommon/bastion.hcl
#
# Shared Terragrunt configuration for the bastion component.
# Included by each leaf-level terragrunt.hcl for bastion deployments.
# -----------------------------------------------------------------------------

terraform {
  source = "${get_repo_root()}/aws/roles/bastion/modules/bastion"
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  # Networking
  vpc_id            = local.env_vars.locals.vpc_id
  vpc_cidr          = local.env_vars.locals.vpc_cidr
  public_subnet_ids = local.env_vars.locals.public_subnet_ids

  # Instance
  ami_id        = local.env_vars.locals.ami_id
  instance_type = local.env_vars.locals.instance_type
  ssh_port      = local.env_vars.locals.ssh_port

  # SSH / VPN access
  vpn_cidrs  = local.env_vars.locals.vpn_cidrs
  icinga_ips = local.env_vars.locals.icinga_ips

  # Monitoring
  cpu_warning_threshold = local.env_vars.locals.cpu_warning_threshold
  log_retention_days    = local.env_vars.locals.log_retention_days

  # SNS
  sns_topic_arns = local.env_vars.locals.sns_topic_arns

  # S3
  project_bucket_arn      = local.env_vars.locals.project_bucket_arn
  project_bucket_name     = local.env_vars.locals.project_bucket_name
  authorized_users_bucket = local.env_vars.locals.authorized_users_bucket

  # DNS / Route53
  hosted_zone_id   = local.env_vars.locals.hosted_zone_id
  route53_zone_ids = local.env_vars.locals.route53_zone_ids

  # Service Discovery
  service_discovery_namespace_id = local.env_vars.locals.service_discovery_namespace_id

  # Git
  git_repo_url = local.env_vars.locals.git_repo_url
}
