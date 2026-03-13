################################################################################
# Cross-Account DevOps Roles
#
# Ported from: stacksets/devops-cross-account-roles.yml
#
# Creates IAM roles and policies for cross-account DevOps deployments:
#   1. CFN Execution Policy - broad managed policy for CloudFormation deployments
#   2. StackSet Execution Role - used by StackSet operations
#   3. StackSet Administration Role - allows CloudFormation to assume execution role
#   4. DevOps Deployment Role - assumed by the DevOps account for CI/CD operations
################################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id     = data.aws_caller_identity.current.account_id
  current_region = data.aws_region.current.name

  # Combined list of accounts allowed for Packer operations
  packer_allowed_accounts = concat([var.devops_account_id], var.packer_account_ids)
}

################################################################################
# CloudFormation Execution Managed Policy
################################################################################

resource "aws_iam_policy" "cfn_execution" {
  name        = var.cfn_execution_policy_name
  path        = "/"
  description = "Broad execution policy for CloudFormation deployments across services"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Resource = "*"
        Action = [
          "acm:*",
          "application-autoscaling:*",
          "apigateway:*",
          "appmesh:*",
          "autoscaling:*",
          "codebuild:*",
          "codedeploy:*",
          "cloudfront:*",
          "cloudwatch:*",
          "cognito-idp:*",
          "dynamodb:*",
          "ec2:*",
          "ecr:*",
          "ecs:*",
          "eks:*",
          "elasticfilesystem:*",
          "elasticache:*",
          "elasticloadbalancing:*",
          "elastictranscoder:CreatePipeline",
          "elastictranscoder:ListPipelines",
          "events:*",
          "firehose:*",
          "globalaccelerator:*",
          "glue:*",
          "iam:AddRoleToInstanceProfile",
          "iam:AttachGroupPolicy",
          "iam:AttachRolePolicy",
          "iam:CreateGroup",
          "iam:CreateInstanceProfile",
          "iam:CreatePolicy",
          "iam:CreatePolicyVersion",
          "iam:CreateOpenIDConnectProvider",
          "iam:CreateRole",
          "iam:CreateServiceLinkedRole",
          "iam:DeleteGroup",
          "iam:DeleteGroupPolicy",
          "iam:DeleteInstanceProfile",
          "iam:DeleteOpenIDConnectProvider",
          "iam:DeletePolicy",
          "iam:DeletePolicyVersion",
          "iam:DeleteRole",
          "iam:DeleteRolePolicy",
          "iam:DetachGroupPolicy",
          "iam:DetachRolePolicy",
          "iam:GetGroup",
          "iam:GetGroupPolicy",
          "iam:GetInstanceProfile",
          "iam:GetOpenIDConnectProvider",
          "iam:GetPolicy",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:GetUser",
          "iam:ListAttachedRolePolicies",
          "iam:ListPolicyVersions",
          "iam:ListRoleTags",
          "iam:ListUserTags",
          "iam:PassRole",
          "iam:PutGroupPolicy",
          "iam:PutRolePolicy",
          "iam:RemoveClientIDFromOpenIDConnectProvider",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:TagOpenIDConnectProvider",
          "iam:TagRole",
          "iam:TagUser",
          "iam:UntagRole",
          "iam:UntagUser",
          "iam:UpdateAssumeRolePolicy",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "kafka:*",
          "kafka-cluster:*",
          "kms:*",
          "lambda:*",
          "lightsail:*",
          "logs:*",
          "rds-data:*",
          "rds:*",
          "redshift-data:*",
          "redshift:*",
          "route53:*",
          "s3:*",
          "secretsmanager:*",
          "servicediscovery:*",
          "ses:*",
          "sns:*",
          "sqs:*",
          "ssm:*",
          "states:*",
          "synthetics:*",
          "wafv2:*",
        ]
      }
    ]
  })

  tags = var.tags
}

################################################################################
# StackSet Execution Role
################################################################################

resource "aws_iam_role" "stackset_execution" {
  name = var.stackset_execution_role_name
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { AWS = local.account_id }
      }
    ]
  })

  managed_policy_arns = [aws_iam_policy.cfn_execution.arn]

  inline_policy {
    name = "manage-cloudformation-stacks"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = "cloudformation:*"
          Resource = "*"
        }
      ]
    })
  }

  tags = merge(var.tags, {
    Name = var.stackset_execution_role_name
  })
}

################################################################################
# StackSet Administration Role
################################################################################

resource "aws_iam_role" "stackset_admin" {
  name = var.stackset_admin_role_name
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = {
          Service = concat(
            ["cloudformation.amazonaws.com"],
            [for region in var.additional_cfn_via_services : "cloudformation.${region}.amazonaws.com"]
          )
        }
      }
    ]
  })

  inline_policy {
    name = "assume-execution-role"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = "sts:AssumeRole"
          Resource = "arn:aws:iam::*:role/${var.stackset_execution_role_name}"
        }
      ]
    })
  }

  tags = merge(var.tags, {
    Name = var.stackset_admin_role_name
  })
}

################################################################################
# DevOps Deployment Role
################################################################################

resource "aws_iam_role" "devops_deployment" {
  name = var.deployment_role_name
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { AWS = var.devops_account_id }
      }
    ]
  })

  # Policy 1: Build and copy permissions (ECR, EC2, KMS for AMI operations)
  inline_policy {
    name = "build-copy-permissions"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = concat(
        [
          # ECR and EC2 image operations
          {
            Effect = "Allow"
            Action = [
              "ecr:DescribeImages",
              "ecr:GetAuthorizationToken",
              "ecr:BatchGetImage",
              "ecr:GetDownloadUrlForLayer",
              "ecr:PutImage",
              "ecr:InitiateLayerUpload",
              "ecr:UploadLayerPart",
              "ecr:BatchCheckLayerAvailability",
              "ecr:CompleteLayerUpload",
              "ec2:DescribeImages",
              "ec2:DescribeRegions",
              "ec2:CopyImage",
              "ec2:ModifyImageAttribute",
              "ec2:ModifySnapshotAttribute",
              "ec2:CreateTags",
            ]
            Resource = "*"
          },
          # Packer build permissions (scoped to allowed accounts)
          {
            Effect = "Allow"
            Action = [
              "s3:GetObject",
              "ec2:DescribeSubnets",
              "ec2:DescribeInstances",
              "ec2:CreateSecurityGroup",
              "ec2:DescribeSecurityGroups",
              "ec2:DeleteSecurityGroup",
              "ec2:AuthorizeSecurityGroupIngress",
              "ec2:RunInstances",
              "ec2:StopInstances",
              "ec2:CreateImage",
              "ec2:TerminateInstances",
              "ec2:DescribeVolumes",
              "ec2:DeregisterImage",
              "ec2:DeleteSnapshot",
            ]
            Resource = "*"
            Condition = {
              StringEquals = {
                "aws:PrincipalAccount" = local.packer_allowed_accounts
              }
            }
          },
          # Packer key-pair management
          {
            Effect   = "Allow"
            Action   = ["ec2:CreateKeyPair", "ec2:DeleteKeyPair"]
            Resource = "arn:aws:ec2:*:${local.account_id}:key-pair/packer_*"
            Condition = {
              StringEquals = {
                "aws:PrincipalAccount" = local.packer_allowed_accounts
              }
            }
          },
          # Factory instance profile access
          {
            Effect   = "Allow"
            Action   = "iam:GetInstanceProfile"
            Resource = "arn:aws:iam::${local.account_id}:instance-profile/${var.factory_profile_prefix}-ec2factoryprofile-*"
            Condition = {
              StringEquals = {
                "aws:PrincipalAccount" = local.packer_allowed_accounts
              }
            }
          },
          # Factory role pass
          {
            Effect   = "Allow"
            Action   = "iam:PassRole"
            Resource = "arn:aws:iam::${local.account_id}:role/${var.factory_role_prefix}-ec2factoryrole-*"
            Condition = {
              StringEquals = {
                "aws:PrincipalAccount" = local.packer_allowed_accounts
              }
            }
          },
          # KMS key listing
          {
            Effect   = "Allow"
            Action   = ["kms:ListKeys", "kms:ListAliases", "kms:DescribeKey"]
            Resource = "*"
          },
        ],
        # KMS encrypt/decrypt for DevOps KMS keys (conditional on having keys)
        length(var.devops_kms_key_arns) > 0 ? [
          {
            Effect = "Allow"
            Action = [
              "kms:Decrypt",
              "kms:Encrypt",
              "kms:ReEncrypt*",
              "kms:GenerateDataKey*",
              "kms:CreateGrant",
            ]
            Resource = var.devops_kms_key_arns
          }
        ] : []
      )
    })
  }

  # Policy 2: Deployment permissions (S3, SSM, CloudFormation, CDK, frontend, etc.)
  inline_policy {
    name = "deployment-permissions"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        # Deployment and CDK asset buckets
        {
          Effect = "Allow"
          Action = "s3:*"
          Resource = concat(
            flatten([for region in var.deployment_bucket_regions : [
              "arn:aws:s3:::deployment-${local.account_id}-${region}",
              "arn:aws:s3:::deployment-${local.account_id}-${region}/*",
            ]]),
            [
              "arn:aws:s3:::cdk-${var.cdk_qualifier}-assets-${local.account_id}-*",
              "arn:aws:s3:::cdk-${var.cdk_qualifier}-assets-${local.account_id}-*/*",
            ]
          )
        },
        # Shared configuration bucket read access
        {
          Effect = "Allow"
          Action = ["s3:ListBucket", "s3:GetObject"]
          Resource = [
            "arn:aws:s3:::${var.configuration_bucket_name}",
            "arn:aws:s3:::${var.configuration_bucket_name}/*",
          ]
        },
        # SSM parameter read for UI deployment secrets
        {
          Sid      = "RequiredForUiDeploymentsToGetSecrets"
          Effect   = "Allow"
          Action   = "ssm:GetParameter"
          Resource = "arn:aws:ssm:*:${local.account_id}:parameter/*-*-*"
        },
        # SSM parameter read for monitoring IPs
        {
          Effect   = "Allow"
          Action   = "ssm:GetParameters"
          Resource = "arn:aws:ssm:*:${local.account_id}:parameter/monitoring-icinga-ips"
        },
        # CDK bootstrap version parameter
        {
          Effect   = "Allow"
          Action   = "ssm:GetParameter"
          Resource = "arn:aws:ssm:*:${local.account_id}:parameter/cdk-bootstrap/${var.cdk_qualifier}/version"
        },
        # CDK lookup role assumption
        {
          Effect   = "Allow"
          Action   = "sts:AssumeRole"
          Resource = "arn:aws:iam::${local.account_id}:role/cdk-${var.cdk_qualifier}-lookup-role-${local.account_id}-*"
        },
        # CDK CFN execution role pass
        {
          Effect   = "Allow"
          Action   = "iam:PassRole"
          Resource = "arn:aws:iam::${local.account_id}:role/cdk-${var.cdk_qualifier}-cfn-exec-role-${local.account_id}-*"
        },
        # CloudFormation stack management
        {
          Effect = "Allow"
          Action = [
            "cloudformation:ValidateTemplate",
            "cloudformation:CreateStack",
            "cloudformation:UpdateStack",
            "cloudformation:DescribeStacks",
            "cloudformation:DescribeStackEvents",
            "cloudformation:ListStackResources",
            "cloudformation:ListExports",
            "cloudformation:GetTemplate",
            "cloudformation:CreateChangeSet",
            "cloudformation:ListChangeSets",
            "cloudformation:DescribeChangeSet",
            "cloudformation:ExecuteChangeSet",
            "cloudformation:DeleteChangeSet",
          ]
          Resource = "*"
        },
        # CloudFront invalidation
        {
          Effect = "Allow"
          Action = [
            "cloudfront:CreateInvalidation",
            "cloudfront:GetInvalidation",
            "cloudfront:ListInvalidations",
          ]
          Resource = "*"
        },
        # Frontend S3 bucket access
        {
          Effect = "Allow"
          Action = ["s3:ListBucket", "s3:PutObject"]
          Resource = [
            "arn:aws:s3:::*-frontend-${local.account_id}",
            "arn:aws:s3:::*-frontend-${local.account_id}/*",
          ]
        },
        # EKS describe
        {
          Effect   = "Allow"
          Action   = "eks:DescribeCluster"
          Resource = "*"
        },
        # Lambda get (serverless framework)
        {
          Effect   = "Allow"
          Action   = "lambda:GetFunction"
          Resource = "*"
        },
        # CloudFormation list stacks
        {
          Effect   = "Allow"
          Action   = "cloudformation:ListStacks"
          Resource = "*"
        },
        # ACM certificate management
        {
          Effect = "Allow"
          Action = [
            "acm:ListCertificates",
            "acm:RequestCertificate",
            "acm:AddTagsToCertificate",
            "acm:DescribeCertificate",
          ]
          Resource = "*"
        },
        # EC2 describe addresses
        {
          Effect   = "Allow"
          Action   = "ec2:DescribeAddresses"
          Resource = "*"
        },
        # ELB operations
        {
          Effect = "Allow"
          Action = [
            "elasticloadbalancing:DescribeLoadBalancers",
            "elasticloadbalancing:AddListenerCertificates",
          ]
          Resource = "*"
        },
        # API Gateway operations
        {
          Effect = "Allow"
          Action = ["apigateway:GET", "apigateway:PUT"]
          Resource = [
            "arn:aws:apigateway:*::/restapis",
            "arn:aws:apigateway:*::/restapis/*",
            "arn:aws:apigateway:*::/domainnames",
            "arn:aws:apigateway:*::/domainnames/*",
          ]
        },
        # API Gateway tagging
        {
          Effect   = "Allow"
          Action   = "apigateway:PUT"
          Resource = "arn:aws:apigateway:*::/tags/arn%3Aaws%3Aapigateway%3A*%3A%3A%2Frestapis%2F*%2Fstages%2F*"
        },
        # Broad permissions when called via CloudFormation
        {
          Effect   = "Allow"
          Resource = "*"
          Condition = {
            StringEquals = {
              "aws:CalledViaFirst" = "cloudformation.amazonaws.com"
            }
          }
          Action = [
            "acm:*",
            "application-autoscaling:*",
            "apigateway:*",
            "appmesh:*",
            "autoscaling:*",
            "codebuild:*",
            "codedeploy:*",
            "cloudfront:*",
            "cloudwatch:*",
            "cognito-idp:*",
            "dynamodb:*",
            "ec2:*",
            "ecr:*",
            "ecs:*",
            "eks:*",
            "elasticfilesystem:*",
            "elasticache:*",
            "elasticloadbalancing:*",
            "elastictranscoder:CreatePipeline",
            "elastictranscoder:ListPipelines",
            "events:*",
            "firehose:*",
            "globalaccelerator:*",
            "glue:*",
            "iam:AddClientIDToOpenIDConnectProvider",
            "iam:AddRoleToInstanceProfile",
            "iam:AttachGroupPolicy",
            "iam:AttachRolePolicy",
            "iam:CreateGroup",
            "iam:CreateInstanceProfile",
            "iam:CreateOpenIDConnectProvider",
            "iam:CreatePolicy",
            "iam:CreatePolicyVersion",
            "iam:CreateRole",
            "iam:CreateServiceLinkedRole",
            "iam:DeleteGroup",
            "iam:DeleteGroupPolicy",
            "iam:DeleteInstanceProfile",
            "iam:DeleteOpenIDConnectProvider",
            "iam:DeletePolicy",
            "iam:DeletePolicyVersion",
            "iam:DeleteRole",
            "iam:DeleteRolePolicy",
            "iam:DetachGroupPolicy",
            "iam:DetachRolePolicy",
            "iam:GetGroup",
            "iam:GetGroupPolicy",
            "iam:GetInstanceProfile",
            "iam:GetOpenIDConnectProvider",
            "iam:GetPolicy",
            "iam:GetRole",
            "iam:GetRolePolicy",
            "iam:GetUser",
            "iam:ListAttachedRolePolicies",
            "iam:ListOpenIDConnectProviderTags",
            "iam:ListPolicyVersions",
            "iam:ListRoleTags",
            "iam:ListUserTags",
            "iam:PassRole",
            "iam:PutGroupPolicy",
            "iam:PutRolePolicy",
            "iam:RemoveClientIDFromOpenIDConnectProvider",
            "iam:RemoveRoleFromInstanceProfile",
            "iam:TagOpenIDConnectProvider",
            "iam:TagRole",
            "iam:TagUser",
            "iam:UntagRole",
            "iam:UntagUser",
            "iam:UpdateAssumeRolePolicy",
            "iam:UpdateOpenIDConnectProvider",
            "iam:UpdateOpenIDConnectProviderThumbprint",
            "kafka:*",
            "kafka-cluster:*",
            "kms:*",
            "lambda:*",
            "lightsail:*",
            "logs:*",
            "rds-data:*",
            "rds:*",
            "redshift-data:*",
            "redshift:*",
            "route53:*",
            "s3:*",
            "secretsmanager:*",
            "servicediscovery:*",
            "ses:*",
            "sns:*",
            "sqs:*",
            "ssm:*",
            "states:*",
            "synthetics:*",
            "wafv2:*",
          ]
        },
      ]
    })
  }

  tags = merge(var.tags, {
    Name = var.deployment_role_name
  })
}
