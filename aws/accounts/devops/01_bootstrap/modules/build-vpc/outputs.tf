output "vpc_id" {
  description = "ID of the build VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the build VPC"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_id" {
  description = "ID of the public subnet for building AMIs"
  value       = aws_subnet.public.id
}

output "public_subnet_cidr" {
  description = "CIDR block of the public subnet"
  value       = aws_subnet.public.cidr_block
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.this.id
}

output "public_route_table_id" {
  description = "ID of the public route table"
  value       = aws_route_table.public.id
}

output "s3_endpoint_id" {
  description = "ID of the S3 VPC endpoint"
  value       = aws_vpc_endpoint.s3.id
}

output "factory_role_arn" {
  description = "ARN of the EC2 factory IAM role"
  value       = aws_iam_role.factory.arn
}

output "factory_role_name" {
  description = "Name of the EC2 factory IAM role"
  value       = aws_iam_role.factory.name
}

output "factory_instance_profile_arn" {
  description = "ARN of the EC2 factory instance profile"
  value       = aws_iam_instance_profile.factory.arn
}

output "factory_instance_profile_name" {
  description = "Name of the EC2 factory instance profile"
  value       = aws_iam_instance_profile.factory.name
}
