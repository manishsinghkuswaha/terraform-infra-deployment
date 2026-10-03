provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}
data "aws_availability_zones" "available" { state = "available" }
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
locals {
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
  name_prefix        = "session24-${var.environment_name}"
  common_tags = merge(var.tags, {
    Project     = "terraform-session24"
    Environment = var.environment_name
    ManagedBy   = "Terraform"
  })
}
