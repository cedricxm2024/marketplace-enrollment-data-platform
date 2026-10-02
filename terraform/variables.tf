# Inputs you can change without editing the rest of the code
variable "aws_region" {
  description = "AWS Region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short prefix used in resource names"
  type        = string
  default     = "mep"
}