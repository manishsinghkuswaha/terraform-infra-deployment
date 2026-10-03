variable "aws_region" {
  type        = string
  description = "Region for backend resources."
  default     = "ap-south-1"
}

variable "aws_profile" {
  type        = string
  description = "Local AWS CLI profile."
  default     = "default"
}
