variable "region" {
  description = "AWS region for this compute stack"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "cognito_user_pool_id" {
  description = "ID of the Cognito User Pool in us-east-1"
  type        = string
}

variable "cognito_client_id" {
  description = "Cognito User Pool Client ID"
  type        = string
}

variable "candidate_email" {
  description = "Candidate email for SNS payloads"
  type        = string
  sensitive   = true
}

variable "candidate_repo" {
  description = "Candidate GitHub repo URL"
  type        = string
}

variable "verification_sns_arn" {
  description = "Unleash live verification SNS topic ARN"
  type        = string
}

variable "dry_run" {
  description = "When true, skip SNS publishing (for local testing). Set to false for submission."
  type        = bool
  default     = false
}
