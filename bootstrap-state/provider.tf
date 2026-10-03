provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "terraform-session24-state-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  tags = {
    Project   = "terraform-session24"
    ManagedBy = "Terraform"
  }
}
