terraform {
  required_version = ">= 1.10.0"
}
variable "optional_copy_count" {
  type    = number
  default = 1
  validation {
    condition     = contains([0, 1], var.optional_copy_count)
    error_message = "Set optional_copy_count to 0 or 1."
  }
}
variable "students" {
  type    = map(string)
  default = { learner_a = "Anika", learner_b = "Rohan" }
}
resource "terraform_data" "optional_demo" {
  count = var.optional_copy_count
  input = "Created by count; index ${count.index}"
}
resource "terraform_data" "student_demo" {
  for_each = var.students
  input    = "${each.key} belongs to ${each.value}"
}
output "optional_value" {
  value = try(terraform_data.optional_demo[0].output, "No optional object created")
}
output "student_values" {
  value = { for key, item in terraform_data.student_demo : key => item.output }
}
output "workspace_name" { value = terraform.workspace }
