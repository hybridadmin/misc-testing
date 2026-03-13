# Backup Plans & Lambdas - eu-west-1 (Ireland)
# Deploys: Lambda functions, SQS queues, CodeBuild project, EventBridge rules, CloudWatch alarms

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "../../../../modules//backup_plans_lambdas"

  # Build Lambda zip before applying
  before_hook "build_lambdas" {
    commands = ["apply", "plan"]
    execute  = ["bash", "-c", "cd ${get_repo_root()}/lambdas && bash build.sh"]
  }
}

inputs = {
  project            = local.env_vars.locals.project
  environment        = local.env_vars.locals.environment
  backup_account_id  = local.env_vars.locals.backup_account_id
  backup_region      = local.env_vars.locals.backup_region

  general_notification_topic_arn  = local.env_vars.locals.general_notification_topic_arn
  critical_notification_topic_arn = local.env_vars.locals.critical_notification_topic_arn

  route53_config         = local.env_vars.locals.route53_config
  route53_backup_role_arn = "arn:aws:iam::${local.env_vars.locals.backup_account_id}:role/ADMIN-PROD-BACKUP-CrossAccountBackupRole"

  organization_arn           = local.env_vars.locals.organization_arn
  ami_encryption_kms_key_arn = local.env_vars.locals.ami_encryption_kms_key_arn

  lambda_zip_path = "${get_repo_root()}/lambdas/lambda.zip"

  tags = {
    project     = local.env_vars.locals.project
    environment = local.env_vars.locals.environment
    service     = "backups"
  }
}
