###############################################################################
# Cognito Module - User Pool + Client + Test User (us-east-1 only)
###############################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_cognito_user_pool" "main" {
  name = "unleash-live-${var.environment}"

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }

  auto_verified_attributes = ["email"]

  schema {
    name                = "email"
    attribute_data_type = "String"
    mutable             = true
    required            = true

    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = {
    Component = "authentication"
  }
}

resource "aws_cognito_user_pool_client" "main" {
  name         = "unleash-live-client-${var.environment}"
  user_pool_id = aws_cognito_user_pool.main.id

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH",
  ]

  generate_secret = false

  supported_identity_providers = ["COGNITO"]
}

# Test user — created declaratively via the Cognito API.
# The password is set via a one-time bootstrap script (scripts/create_test_user.sh)
# rather than local-exec, to keep the Terraform apply path deterministic and
# free of CLI dependencies.
resource "aws_cognito_user" "test" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = var.test_email

  attributes = {
    email          = var.test_email
    email_verified = "true"
  }

  message_action = "SUPPRESS"
}
