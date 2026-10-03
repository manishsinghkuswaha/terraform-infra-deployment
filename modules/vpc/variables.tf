variable "name" {
  type = string
}
variable "vpc_cidr" {
  type = string
}
variable "availability_zones" {
  type = list(string)
  validation {
    condition     = length(var.availability_zones) == 2 && length(toset(var.availability_zones)) == 2
    error_message = "Pass two distinct AZ names."
  }
}
variable "tags" {
  type    = map(string)
  default = {}
}
