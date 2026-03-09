variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "test_email" {
  description = "Your email address for Cognito test user and SNS payloads"
  type        = string
  sensitive   = true
}

variable "candidate_repo" {
  description = "Your GitHub repository URL"
  type        = string
  default     = "https://github.com/litmus-paper-blue/aws-assessment"
}

variable "verification_sns_arn" {
  description = "Unleash live SNS topic ARN for candidate verification"
  type        = string
  default     = "arn:aws:sns:us-east-1:637226132752:Candidate-Verification-Topic"
}

variable "dry_run" {
  description = "When true, skip SNS publishing (for local testing). Set to false for submission."
  type        = bool
  default     = false
}
