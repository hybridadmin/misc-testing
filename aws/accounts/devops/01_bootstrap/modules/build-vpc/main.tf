################################################################################
# Build VPC for AMI Factory
#
# Ported from: stacksets/devops-build-vpc.yml
#
# Creates a minimal VPC for building AMIs with Packer:
#   1. VPC with one public subnet
#   2. Internet Gateway + route table
#   3. S3 VPC Gateway Endpoint
#   4. EC2 Factory IAM role and instance profile
################################################################################

data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

################################################################################
# VPC
################################################################################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = var.enable_dns_support
  enable_dns_hostnames = var.enable_dns_hostnames

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-vpc"
  })
}

################################################################################
# Internet Gateway
################################################################################

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-igw"
  })
}

################################################################################
# Route Table
################################################################################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-route-table"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

################################################################################
# Public Subnet
################################################################################

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public1"
  })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

################################################################################
# VPC Endpoint for S3
################################################################################

resource "aws_vpc_endpoint" "s3" {
  vpc_id          = aws_vpc.this.id
  service_name    = "com.amazonaws.${data.aws_region.current.name}.s3"
  route_table_ids = [aws_route_table.public.id]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-s3-endpoint"
  })
}

################################################################################
# Factory IAM Role and Instance Profile
################################################################################

resource "aws_iam_role" "factory" {
  name = "${var.name_prefix}-ec2factoryrole-${data.aws_region.current.name}"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  inline_policy {
    name = "factory-instance-permissions"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = "ssm:GetParameter*"
          Resource = var.ssm_parameter_paths
        },
        {
          Effect = "Allow"
          Action = ["s3:ListBucket", "s3:GetObject"]
          Resource = [
            "arn:aws:s3:::${var.software_bucket_name}",
            "arn:aws:s3:::${var.software_bucket_name}/*",
          ]
        },
      ]
    })
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ec2factoryrole-${data.aws_region.current.name}"
  })
}

resource "aws_iam_instance_profile" "factory" {
  name = "${var.name_prefix}-ec2factoryprofile-${data.aws_region.current.name}"
  path = "/"
  role = aws_iam_role.factory.name

  tags = var.tags
}
