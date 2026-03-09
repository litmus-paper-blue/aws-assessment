output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = module.cognito.user_pool_id
}

output "cognito_client_id" {
  description = "Cognito User Pool Client ID"
  value       = module.cognito.client_id
}

output "api_url_us_east_1" {
  description = "API Gateway URL in us-east-1"
  value       = module.compute_us_east_1.api_url
}

output "api_url_eu_west_1" {
  description = "API Gateway URL in eu-west-1"
  value       = module.compute_eu_west_1.api_url
}

output "test_email" {
  description = "Test user email"
  value       = var.test_email
  sensitive   = true
}
