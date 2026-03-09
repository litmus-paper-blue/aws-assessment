output "api_url" {
  description = "API Gateway invoke URL"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "ecs_cluster_arn" {
  value = aws_ecs_cluster.main.arn
}

output "greeter_function_name" {
  value = aws_lambda_function.greeter.function_name
}

output "dispatcher_function_name" {
  value = aws_lambda_function.dispatcher.function_name
}
