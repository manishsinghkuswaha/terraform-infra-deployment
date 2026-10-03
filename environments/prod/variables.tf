variable "aws_region" {
  type    = string
  default = "ap-south-1"
}
variable "aws_profile" {
  type    = string
  default = "default"
}
variable "environment_name" {
  type = string
}
variable "vpc_cidr" {
  type = string
}
variable "workload_instance_type" {
  type = string
}
variable "monitoring_instance_type" {
  type = string
}
variable "enable_monitoring" {
  type    = bool
  default = true
}
variable "enable_sample_workload" {
  type    = bool
  default = true
}
variable "enable_status_alarm" {
  type    = bool
  default = false
}
variable "tags" {
  type    = map(string)
  default = {}
}
variable "monitoring_ingress_rules" {
  description = "Optional monitoring ingress; keep empty to use SSM forwarding only."
  type = list(object({
    description = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
  }))
  default = []
}
