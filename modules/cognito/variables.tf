variable "environment" {
  type = string
}

variable "test_email" {
  type      = string
  sensitive = true
}
