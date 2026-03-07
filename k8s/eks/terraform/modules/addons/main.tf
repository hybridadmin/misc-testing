# -----------------------------------------------------------------------------
# Add-ons Module
# Deploys AWS Load Balancer Controller, Cluster Autoscaler, and Metrics Server
# using Helm charts with IRSA (IAM Roles for Service Accounts).
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
}

# =============================================================================
# AWS Load Balancer Controller
# Manages ALB/NLB lifecycle for Kubernetes Ingress and Service resources.
# =============================================================================

# -- IRSA Role for ALB Controller --

data "aws_iam_policy_document" "lb_controller_assume" {
  count = var.enable_aws_lb_controller ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_id}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_id}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  count = var.enable_aws_lb_controller ? 1 : 0

  name               = "${var.cluster_name}-lb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume[0].json

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_policy" "lb_controller" {
  count = var.enable_aws_lb_controller ? 1 : 0

  name        = "${var.cluster_name}-lb-controller-policy"
  description = "IAM policy for AWS Load Balancer Controller"
  policy      = file("${path.module}/policies/alb-controller-policy.json")

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  count = var.enable_aws_lb_controller ? 1 : 0

  policy_arn = aws_iam_policy.lb_controller[0].arn
  role       = aws_iam_role.lb_controller[0].name
}

# -- Helm Release --

resource "helm_release" "lb_controller" {
  count = var.enable_aws_lb_controller ? 1 : 0

  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.1"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.lb_controller[0].arn
  }

  set {
    name  = "region"
    value = local.region
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  # Enable pod readiness gate injection for ALB target groups
  set {
    name  = "enablePodReadinessGateInject"
    value = "true"
  }

  depends_on = [
    aws_iam_role_policy_attachment.lb_controller,
  ]
}

# =============================================================================
# Cluster Autoscaler
# Automatically adjusts the number of nodes based on pod scheduling needs.
# =============================================================================

# -- IRSA Role for Cluster Autoscaler --

data "aws_iam_policy_document" "cluster_autoscaler_assume" {
  count = var.enable_cluster_autoscaler ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_id}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_id}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  count = var.enable_cluster_autoscaler ? 1 : 0

  name               = "${var.cluster_name}-cluster-autoscaler-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume[0].json

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_policy" "cluster_autoscaler" {
  count = var.enable_cluster_autoscaler ? 1 : 0

  name        = "${var.cluster_name}-cluster-autoscaler-policy"
  description = "IAM policy for Cluster Autoscaler"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup",
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Effect   = "Allow"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/k8s.io/cluster-autoscaler/enabled"              = "true"
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
          }
        }
      },
    ]
  })

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  count = var.enable_cluster_autoscaler ? 1 : 0

  policy_arn = aws_iam_policy.cluster_autoscaler[0].arn
  role       = aws_iam_role.cluster_autoscaler[0].name
}

# -- Helm Release --

resource "helm_release" "cluster_autoscaler" {
  count = var.enable_cluster_autoscaler ? 1 : 0

  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.35.0"
  namespace  = "kube-system"

  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "awsRegion"
    value = local.region
  }

  set {
    name  = "rbac.serviceAccount.create"
    value = "true"
  }

  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }

  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.cluster_autoscaler[0].arn
  }

  # Best practices for autoscaler
  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }

  set {
    name  = "extraArgs.skip-nodes-with-system-pods"
    value = "false"
  }

  set {
    name  = "extraArgs.expander"
    value = "least-waste"
  }

  set {
    name  = "extraArgs.scale-down-delay-after-add"
    value = "5m"
  }

  set {
    name  = "extraArgs.scale-down-unneeded-time"
    value = "5m"
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_autoscaler,
  ]
}

# =============================================================================
# Metrics Server
# Required for Horizontal Pod Autoscaler (HPA) to function.
# =============================================================================

resource "helm_release" "metrics_server" {
  count = var.enable_metrics_server ? 1 : 0

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart      = "metrics-server"
  version    = "3.12.0"
  namespace  = "kube-system"

  set {
    name  = "replicas"
    value = "2"
  }
}

# =============================================================================
# Amazon S3 CSI Driver (Mountpoint for Amazon S3)
# Mounts S3 buckets as read-only or read-write filesystems in pods.
# =============================================================================

# -- IRSA Role for S3 CSI Driver --

data "aws_iam_policy_document" "s3_csi_assume" {
  count = var.enable_s3_csi_driver ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_id}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_id}:sub"
      values   = ["system:serviceaccount:kube-system:s3-csi-driver-sa"]
    }
  }
}

resource "aws_iam_role" "s3_csi" {
  count = var.enable_s3_csi_driver ? 1 : 0

  name               = "${var.cluster_name}-s3-csi-driver-role"
  assume_role_policy = data.aws_iam_policy_document.s3_csi_assume[0].json

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_policy" "s3_csi" {
  count = var.enable_s3_csi_driver ? 1 : 0

  name        = "${var.cluster_name}-s3-csi-driver-policy"
  description = "IAM policy for Mountpoint for Amazon S3 CSI Driver"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MountpointFullBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
        ]
        Resource = "arn:aws:s3:::*"
      },
      {
        Sid    = "MountpointFullObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:DeleteObject",
        ]
        Resource = "arn:aws:s3:::*/*"
      },
    ]
  })

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "s3_csi" {
  count = var.enable_s3_csi_driver ? 1 : 0

  policy_arn = aws_iam_policy.s3_csi[0].arn
  role       = aws_iam_role.s3_csi[0].name
}

# -- Helm Release --

resource "helm_release" "s3_csi" {
  count = var.enable_s3_csi_driver ? 1 : 0

  name       = "aws-mountpoint-s3-csi-driver"
  repository = "https://awslabs.github.io/mountpoint-s3-csi-driver"
  chart      = "aws-mountpoint-s3-csi-driver"
  version    = "1.7.0"
  namespace  = "kube-system"

  set {
    name  = "node.serviceAccount.create"
    value = "true"
  }

  set {
    name  = "node.serviceAccount.name"
    value = "s3-csi-driver-sa"
  }

  set {
    name  = "node.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.s3_csi[0].arn
  }

  depends_on = [
    aws_iam_role_policy_attachment.s3_csi,
  ]
}

# =============================================================================
# Amazon EFS CSI Driver
# Provides ReadWriteMany persistent storage backed by Amazon EFS.
# =============================================================================

# -- IRSA Role for EFS CSI Driver --

data "aws_iam_policy_document" "efs_csi_assume" {
  count = var.enable_efs_csi_driver ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_id}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_id}:sub"
      values   = ["system:serviceaccount:kube-system:efs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "efs_csi" {
  count = var.enable_efs_csi_driver ? 1 : 0

  name               = "${var.cluster_name}-efs-csi-driver-role"
  assume_role_policy = data.aws_iam_policy_document.efs_csi_assume[0].json

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_policy" "efs_csi" {
  count = var.enable_efs_csi_driver ? 1 : 0

  name        = "${var.cluster_name}-efs-csi-driver-policy"
  description = "IAM policy for Amazon EFS CSI Driver"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:DescribeAccessPoints",
          "elasticfilesystem:DescribeFileSystems",
          "elasticfilesystem:DescribeMountTargets",
          "ec2:DescribeAvailabilityZones",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:CreateAccessPoint",
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:RequestTag/efs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:TagResource",
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:ResourceTag/efs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:DeleteAccessPoint",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/efs.csi.aws.com/cluster" = "true"
          }
        }
      },
    ]
  })

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  count = var.enable_efs_csi_driver ? 1 : 0

  policy_arn = aws_iam_policy.efs_csi[0].arn
  role       = aws_iam_role.efs_csi[0].name
}

# -- Helm Release --

resource "helm_release" "efs_csi" {
  count = var.enable_efs_csi_driver ? 1 : 0

  name       = "aws-efs-csi-driver"
  repository = "https://kubernetes-sigs.github.io/aws-efs-csi-driver"
  chart      = "aws-efs-csi-driver"
  version    = "3.0.4"
  namespace  = "kube-system"

  set {
    name  = "controller.serviceAccount.create"
    value = "true"
  }

  set {
    name  = "controller.serviceAccount.name"
    value = "efs-csi-controller-sa"
  }

  set {
    name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.efs_csi[0].arn
  }

  depends_on = [
    aws_iam_role_policy_attachment.efs_csi,
  ]
}

# =============================================================================
# AWS Secrets Store CSI Driver + AWS Provider
# Mounts AWS Secrets Manager / SSM Parameter Store entries as K8s volumes.
# Requires two Helm charts: the base driver and the AWS-specific provider.
# =============================================================================

# -- IRSA Role for Secrets Store CSI Driver --
# Note: Individual pods that consume secrets need their own IRSA roles scoped
# to their specific secrets. This role is for the provider DaemonSet itself.

data "aws_iam_policy_document" "secrets_store_assume" {
  count = var.enable_secrets_store_csi_driver ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_id}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_id}:sub"
      values   = ["system:serviceaccount:kube-system:secrets-store-csi-driver-provider-aws"]
    }
  }
}

resource "aws_iam_role" "secrets_store" {
  count = var.enable_secrets_store_csi_driver ? 1 : 0

  name               = "${var.cluster_name}-secrets-store-role"
  assume_role_policy = data.aws_iam_policy_document.secrets_store_assume[0].json

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_policy" "secrets_store" {
  count = var.enable_secrets_store_csi_driver ? 1 : 0

  name        = "${var.cluster_name}-secrets-store-policy"
  description = "IAM policy for AWS Secrets Store CSI Driver Provider"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameters",
          "ssm:GetParameter",
        ]
        Resource = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/*"
      },
    ]
  })

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "secrets_store" {
  count = var.enable_secrets_store_csi_driver ? 1 : 0

  policy_arn = aws_iam_policy.secrets_store[0].arn
  role       = aws_iam_role.secrets_store[0].name
}

# -- Helm Release: Base Secrets Store CSI Driver --

resource "helm_release" "secrets_store_csi_driver" {
  count = var.enable_secrets_store_csi_driver ? 1 : 0

  name       = "secrets-store-csi-driver"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  version    = "1.4.1"
  namespace  = "kube-system"

  # Enable syncing secrets to Kubernetes Secret objects
  set {
    name  = "syncSecret.enabled"
    value = "true"
  }

  # Enable auto-rotation of secrets
  set {
    name  = "enableSecretRotation"
    value = "true"
  }
}

# -- Helm Release: AWS Provider for Secrets Store CSI Driver --

resource "helm_release" "secrets_store_csi_driver_provider_aws" {
  count = var.enable_secrets_store_csi_driver ? 1 : 0

  name       = "secrets-store-csi-driver-provider-aws"
  repository = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart      = "secrets-store-csi-driver-provider-aws"
  version    = "0.3.6"
  namespace  = "kube-system"

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "secrets-store-csi-driver-provider-aws"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.secrets_store[0].arn
  }

  depends_on = [
    helm_release.secrets_store_csi_driver,
    aws_iam_role_policy_attachment.secrets_store,
  ]
}
