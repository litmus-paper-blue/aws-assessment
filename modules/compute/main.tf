###############################################################################
# Compute Module - Deployed per-region
# Contains: API GW, Lambdas, DynamoDB, ECS Fargate
###############################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_region" "current" {}

locals {
  prefix = "unleash-${var.environment}-${var.region}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DynamoDB
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_dynamodb_table" "greeting_logs" {
  name         = "${local.prefix}-GreetingLogs"
  billing_mode = "PAY_PER_REQUEST" # Cost-optimized: no idle capacity charges
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  tags = {
    Component = "data"
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# IAM - Lambda Execution Role
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "lambda_exec" {
  name = "${local.prefix}-lambda-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Greeter Lambda: DynamoDB write + SNS publish (cross-account)
resource "aws_iam_role_policy" "greeter_policy" {
  name = "${local.prefix}-greeter"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
        ]
        Resource = aws_dynamodb_table.greeting_logs.arn
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = var.verification_sns_arn
      }
    ]
  })
}

# Dispatcher Lambda: ECS RunTask
resource "aws_iam_role_policy" "dispatcher_policy" {
  name = "${local.prefix}-dispatcher"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:RunTask",
        ]
        Resource = aws_ecs_task_definition.verification.arn
      },
      {
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          aws_iam_role.ecs_task_exec.arn,
          aws_iam_role.ecs_task_role.arn,
        ]
      }
    ]
  })
}

# ═══════════════════════════════════════════════════════════════════════════════
# Lambda Functions
# ═══════════════════════════════════════════════════════════════════════════════

# --- Package Lambda code ---
data "archive_file" "greeter" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/greeter"
  output_path = "${path.module}/../../.build/greeter-${var.region}.zip"
}

data "archive_file" "dispatcher" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/dispatcher"
  output_path = "${path.module}/../../.build/dispatcher-${var.region}.zip"
}

# --- Greeter Lambda ---
resource "aws_lambda_function" "greeter" {
  function_name    = "${local.prefix}-greeter"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.greeter.output_path
  source_code_hash = data.archive_file.greeter.output_base64sha256
  timeout          = 15
  memory_size      = 128

  environment {
    variables = {
      TABLE_NAME           = aws_dynamodb_table.greeting_logs.name
      VERIFICATION_SNS_ARN = var.verification_sns_arn
      CANDIDATE_EMAIL      = var.candidate_email
      CANDIDATE_REPO       = var.candidate_repo
      REGION               = var.region
      DRY_RUN              = tostring(var.dry_run)
    }
  }

  tags = {
    Component = "compute"
  }
}

# --- Dispatcher Lambda ---
resource "aws_lambda_function" "dispatcher" {
  function_name    = "${local.prefix}-dispatcher"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.dispatcher.output_path
  source_code_hash = data.archive_file.dispatcher.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      ECS_CLUSTER_ARN     = aws_ecs_cluster.main.arn
      TASK_DEFINITION_ARN = aws_ecs_task_definition.verification.arn
      SUBNET_IDS          = join(",", aws_subnet.public[*].id)
      SECURITY_GROUP_ID   = aws_security_group.ecs_tasks.id
      REGION              = var.region
    }
  }

  tags = {
    Component = "compute"
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# API Gateway (HTTP API)
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_apigatewayv2_api" "main" {
  name          = "${local.prefix}-api"
  protocol_type = "HTTP"

  tags = {
    Component = "api"
  }
}

# JWT Authorizer pointing to Cognito in us-east-1
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.main.id
  name             = "cognito-authorizer"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [var.cognito_client_id]
    issuer   = "https://cognito-idp.us-east-1.amazonaws.com/${var.cognito_user_pool_id}"
  }
}

# --- Integrations ---
resource "aws_apigatewayv2_integration" "greet" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.greeter.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "dispatch" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.dispatcher.invoke_arn
  payload_format_version = "2.0"
}

# --- Routes ---
resource "aws_apigatewayv2_route" "greet" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "GET /greet"
  target             = "integrations/${aws_apigatewayv2_integration.greet.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "dispatch" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "POST /dispatch"
  target             = "integrations/${aws_apigatewayv2_integration.dispatch.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# --- Stage ---
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      errorMessage   = "$context.error.message"
    })
  }
}

resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/apigateway/${local.prefix}-api"
  retention_in_days = 7
}

# --- Lambda Permissions for API GW ---
resource "aws_lambda_permission" "greet_apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.greeter.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

resource "aws_lambda_permission" "dispatch_apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dispatcher.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# ═══════════════════════════════════════════════════════════════════════════════
# VPC (Public subnets only - cost-optimized, no NAT Gateway)
# ═══════════════════════════════════════════════════════════════════════════════

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name      = "${local.prefix}-vpc"
    Component = "network"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.prefix}-public-${count.index}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "ecs_tasks" {
  name_prefix = "${local.prefix}-ecs-"
  vpc_id      = aws_vpc.main.id

  # Outbound: Allow all (needed for SNS API calls)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # No inbound needed - task only makes outbound API calls
  tags = {
    Name      = "${local.prefix}-ecs-sg"
    Component = "network"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# ECS Fargate (Cost-Optimized)
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_ecs_cluster" "main" {
  name = "${local.prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # Cost optimization
  }

  tags = {
    Component = "compute"
  }
}

# Task Execution Role (for ECS to pull images / write logs)
resource "aws_iam_role" "ecs_task_exec" {
  name = "${local.prefix}-ecs-task-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_exec" {
  role       = aws_iam_role.ecs_task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task Role (permissions the container has at runtime)
resource "aws_iam_role" "ecs_task_role" {
  name = "${local.prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "ecs_sns_publish" {
  name = "${local.prefix}-ecs-sns"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sns:Publish"
      Resource = var.verification_sns_arn
    }]
  })
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.prefix}-verification"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "verification" {
  family                   = "${local.prefix}-verification"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256" # Minimum - cost optimized
  memory                   = "512" # Minimum - cost optimized
  execution_role_arn       = aws_iam_role.ecs_task_exec.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([{
    name      = "verification"
    image     = "amazon/aws-cli:latest"
    essential = true

    entryPoint = ["/bin/sh", "-c"]

    command = var.dry_run ? [
      "echo '[DRY_RUN] Would publish to SNS: ${jsonencode({
        email  = var.candidate_email
        source = "ECS"
        region = var.region
        repo   = var.candidate_repo
      })}'"
      ] : [
      "echo 'Publishing to SNS: ${jsonencode({
        email  = var.candidate_email
        source = "ECS"
        region = var.region
        repo   = var.candidate_repo
        })}' && aws sns publish --topic-arn ${var.verification_sns_arn} --region us-east-1 --message '${jsonencode({
        email  = var.candidate_email
        source = "ECS"
        region = var.region
        repo   = var.candidate_repo
      })}'"
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = {
    Component = "compute"
  }
}
