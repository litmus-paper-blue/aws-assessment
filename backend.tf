terraform {
  backend "s3" {
    bucket = "unleash-live-assessment-backend-tf-state-bucket"
    key    = "terraform.tfstate"
    region = "us-east-1"
  }
}
