###############################################################################
# Root Module - Multi-Region AWS Assessment
# Deploys: Cognito (us-east-1), Compute stack (per region via for_each)
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ─── Providers ───────────────────────────────────────────────────────────────

provider "aws" {
  region = "us-east-1"
  alias  = "us_east_1"

  default_tags {
    tags = {
      Project     = "unleash-live-assessment"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}

provider "aws" {
  region = "eu-west-1"
  alias  = "eu_west_1"

  default_tags {
    tags = {
      Project     = "unleash-live-assessment"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}

# ─── Cognito (us-east-1 only) ───────────────────────────────────────────────

module "cognito" {
  source = "./modules/cognito"

  providers = {
    aws = aws.us_east_1
  }

  environment = var.environment
  test_email  = var.test_email
}

# ─── Compute Stack: us-east-1 ───────────────────────────────────────────────

module "compute_us_east_1" {
  source = "./modules/compute"

  providers = {
    aws = aws.us_east_1
  }

  region               = "us-east-1"
  environment          = var.environment
  cognito_user_pool_id = module.cognito.user_pool_id
  cognito_client_id    = module.cognito.client_id
  candidate_email      = var.test_email
  candidate_repo       = var.candidate_repo
  verification_sns_arn = var.verification_sns_arn
  dry_run              = var.dry_run
}

# ─── Compute Stack: eu-west-1 ───────────────────────────────────────────────

module "compute_eu_west_1" {
  source = "./modules/compute"

  providers = {
    aws = aws.eu_west_1
  }

  region               = "eu-west-1"
  environment          = var.environment
  cognito_user_pool_id = module.cognito.user_pool_id
  cognito_client_id    = module.cognito.client_id
  candidate_email      = var.test_email
  candidate_repo       = var.candidate_repo
  verification_sns_arn = var.verification_sns_arn
  dry_run              = var.dry_run
}
