terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "voucher-generator"
}

variable "ADDY_API_KEY" {
  description = "Addy.io API Key for email aliases"
  type        = string
  sensitive   = true
}

# ZIP z kodem Lambda (musi być wcześniej przygotowany przez npm run package)
data "local_file" "lambda_zip" {
  filename = "../lambda-deployment.zip"
}

# IAM Role dla Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Podstawowe uprawnienia dla Lambda (CloudWatch Logs)
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_role.name
}

# API Gateway API Key
resource "aws_api_gateway_api_key" "api_key" {
  name        = "${var.project_name}-api-key"
  description = "API Key for Voucher Generator"
  enabled     = true
}

# Generate Email Alias Lambda Function
resource "aws_lambda_function" "generate_email_alias" {
  filename         = data.local_file.lambda_zip.filename
  function_name    = "${var.project_name}-generate-email-alias"
  role             = aws_iam_role.lambda_role.arn
  handler          = "dist/generate-email-alias/lambda/index.handler"
  runtime          = "nodejs18.x"
  timeout          = 30
  memory_size      = 256

  source_code_hash = filebase64sha256(data.local_file.lambda_zip.filename)

  environment {
    variables = {
      NODE_ENV = "production"
      ADDY_API_KEY = var.ADDY_API_KEY
    }
  }
}

# REST API Gateway (v1 - wspiera natywne API Keys)
resource "aws_api_gateway_rest_api" "lambda_api" {
  name        = "${var.project_name}-api"
  description = "API Gateway for Voucher Generator"
  
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# API Gateway Resource (generate-email-alias)
resource "aws_api_gateway_resource" "generate_email_alias" {
  rest_api_id = aws_api_gateway_rest_api.lambda_api.id
  parent_id   = aws_api_gateway_rest_api.lambda_api.root_resource_id
  path_part   = "generate-email-alias"
}

# API Gateway Method (POST dla generate-email-alias)
resource "aws_api_gateway_method" "generate_email_alias" {
  rest_api_id   = aws_api_gateway_rest_api.lambda_api.id
  resource_id   = aws_api_gateway_resource.generate_email_alias.id
  http_method   = "POST"
  authorization = "NONE"
  api_key_required = true
}

# Method Settings for logging
resource "aws_api_gateway_method_settings" "generate_email_alias" {
  rest_api_id = aws_api_gateway_rest_api.lambda_api.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  method_path = "${aws_api_gateway_resource.generate_email_alias.path_part}/${aws_api_gateway_method.generate_email_alias.http_method}"

  settings {
    logging_level      = "INFO"
    data_trace_enabled = true
    metrics_enabled    = true
  }
}

# API Gateway Integration (generate-email-alias)
resource "aws_api_gateway_integration" "generate_email_alias" {
  rest_api_id = aws_api_gateway_rest_api.lambda_api.id
  resource_id = aws_api_gateway_method.generate_email_alias.resource_id
  http_method = aws_api_gateway_method.generate_email_alias.http_method

  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.generate_email_alias.invoke_arn
}

# API Gateway Deployment
resource "aws_api_gateway_deployment" "lambda" {
  depends_on = [
    aws_api_gateway_integration.generate_email_alias,
  ]

  rest_api_id = aws_api_gateway_rest_api.lambda_api.id

  triggers = {
    redeploy_hash = sha1(jsonencode({
      resources = [
        aws_api_gateway_resource.generate_email_alias.id,
      ],
      methods = [
        aws_api_gateway_method.generate_email_alias.id,
      ],
      integrations = [
        aws_api_gateway_integration.generate_email_alias.id,
      ]
    }))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# CloudWatch Log Group for API Gateway
resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "API-Gateway-Execution-Logs_${aws_api_gateway_rest_api.lambda_api.id}/prod"
  retention_in_days = 7
}

# IAM Role for API Gateway CloudWatch Logging
resource "aws_iam_role" "api_gateway_cloudwatch" {
  name = "${var.project_name}-api-gateway-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
      }
    ]
  })
}

# Attach CloudWatch policy to API Gateway role
resource "aws_iam_role_policy_attachment" "api_gateway_cloudwatch" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
  role       = aws_iam_role.api_gateway_cloudwatch.name
}

# API Gateway Account (for CloudWatch logging)
resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.api_gateway_cloudwatch.arn
}

# API Gateway Stage
resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.lambda.id
  rest_api_id   = aws_api_gateway_rest_api.lambda_api.id
  stage_name    = "prod"

  depends_on = [aws_api_gateway_account.main]

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      caller         = "$context.identity.caller"
      user           = "$context.identity.user"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      error          = "$context.error.message"
      integrationError = "$context.integrationErrorMessage"
    })
  }

  variables = {
    "loggingLevel" = "INFO"
  }
}

# Lambda Permission dla API Gateway (Generate Email Alias) - wildcard dla wszystkich stage'y
resource "aws_lambda_permission" "api_gateway_generate_email_alias" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.generate_email_alias.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.lambda_api.execution_arn}/*/*/*"
}

# Usage Plan z rate limiting
resource "aws_api_gateway_usage_plan" "main" {
  name         = "${var.project_name}-usage-plan"
  description  = "Usage plan for Voucher Generator API"

  api_stages {
    api_id = aws_api_gateway_rest_api.lambda_api.id
    stage  = aws_api_gateway_stage.prod.stage_name
  }

  throttle_settings {
    rate_limit  = 100   # 100 requests per second
    burst_limit = 200   # burst up to 200 requests
  }

  quota_settings {
    limit  = 10000      # 10,000 requests per month
    period = "MONTH"
  }
}

# Połączenie API Key z Usage Plan
resource "aws_api_gateway_usage_plan_key" "main" {
  key_id        = aws_api_gateway_api_key.api_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.main.id
}

# Outputs
output "api_gateway_url" {
  description = "URL of the API Gateway"
  value       = aws_api_gateway_stage.prod.invoke_url
}

output "api_key" {
  description = "API Key for authorization (use in x-api-key header)"
  value       = aws_api_gateway_api_key.api_key.value
  sensitive   = true
}

output "generate_email_alias_function_name" {
  description = "Name of the Generate Email Alias Lambda function"
  value       = aws_lambda_function.generate_email_alias.function_name
}

output "usage_plan_id" {
  description = "Usage Plan ID"
  value       = aws_api_gateway_usage_plan.main.id
}

output "curl_example" {
  description = "Example curl command to test the API"
  value       = <<-EOT
    curl -X POST ${aws_api_gateway_stage.prod.invoke_url}/generate-email-alias \
      -H "x-api-key: ${aws_api_gateway_api_key.api_key.value}" \
      -H "Content-Type: application/json" \
      -d '{"alias": "test-alias"}'
  EOT
  sensitive   = true
}

output "cloudwatch_log_group" {
  description = "CloudWatch Log Group for API Gateway logs"
  value       = aws_cloudwatch_log_group.api_gateway.name
}
