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
  default     = "pdf-compressor"
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
resource "aws_api_gateway_api_key" "pdf_compressor_key" {
  name        = "${var.project_name}-api-key"
  description = "API Key for PDF Compressor"
  enabled     = true
}

# PDF Compressor Lambda Function
resource "aws_lambda_function" "pdf_compressor" {
  filename         = data.local_file.lambda_zip.filename
  function_name    = var.project_name
  role            = aws_iam_role.lambda_role.arn
  handler         = "src/features/pdf-compressor/lambda/index.handler"
  runtime         = "nodejs18.x"
  timeout         = 30
  memory_size     = 512

  source_code_hash = filebase64sha256(data.local_file.lambda_zip.filename)

  environment {
    variables = {
      NODE_ENV = "production"
    }
  }
}

# Email Aliases Lambda Function
resource "aws_lambda_function" "email_aliases" {
  filename         = data.local_file.lambda_zip.filename
  function_name    = "${var.project_name}-email-aliases"
  role            = aws_iam_role.lambda_role.arn
  handler         = "src/features/email-aliases/lambda/index.handler"
  runtime         = "nodejs18.x"
  timeout         = 30
  memory_size     = 256

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
  description = "API Gateway for PDF Compressor"
  
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# API Gateway Resource (proxy)
resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.lambda_api.id
  parent_id   = aws_api_gateway_rest_api.lambda_api.root_resource_id
  path_part   = "{proxy+}"
}

# API Gateway Resource (email-aliases)
resource "aws_api_gateway_resource" "email_aliases" {
  rest_api_id = aws_api_gateway_rest_api.lambda_api.id
  parent_id   = aws_api_gateway_rest_api.lambda_api.root_resource_id
  path_part   = "email-aliases"
}

# API Gateway Method (ANY dla root)
resource "aws_api_gateway_method" "proxy_root" {
  rest_api_id   = aws_api_gateway_rest_api.lambda_api.id
  resource_id   = aws_api_gateway_rest_api.lambda_api.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
  api_key_required = true
}

# API Gateway Method (ANY dla proxy)
resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.lambda_api.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"
  api_key_required = true
}

# API Gateway Method (POST dla email-aliases)
resource "aws_api_gateway_method" "email_aliases" {
  rest_api_id   = aws_api_gateway_rest_api.lambda_api.id
  resource_id   = aws_api_gateway_resource.email_aliases.id
  http_method   = "POST"
  authorization = "NONE"
  api_key_required = true
}

# API Gateway Integration (root)
resource "aws_api_gateway_integration" "lambda_root" {
  rest_api_id = aws_api_gateway_rest_api.lambda_api.id
  resource_id = aws_api_gateway_method.proxy_root.resource_id
  http_method = aws_api_gateway_method.proxy_root.http_method

  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.pdf_compressor.invoke_arn
}

# API Gateway Integration (proxy)
resource "aws_api_gateway_integration" "lambda" {
  rest_api_id = aws_api_gateway_rest_api.lambda_api.id
  resource_id = aws_api_gateway_method.proxy.resource_id
  http_method = aws_api_gateway_method.proxy.http_method

  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.pdf_compressor.invoke_arn
}

# API Gateway Integration (email-aliases)
resource "aws_api_gateway_integration" "email_aliases" {
  rest_api_id = aws_api_gateway_rest_api.lambda_api.id
  resource_id = aws_api_gateway_method.email_aliases.resource_id
  http_method = aws_api_gateway_method.email_aliases.http_method

  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.email_aliases.invoke_arn
}

# API Gateway Deployment
resource "aws_api_gateway_deployment" "lambda" {
  depends_on = [
    aws_api_gateway_integration.lambda,
    aws_api_gateway_integration.lambda_root,
    aws_api_gateway_integration.email_aliases,
  ]

  rest_api_id = aws_api_gateway_rest_api.lambda_api.id

  lifecycle {
    create_before_destroy = true
  }
}

# API Gateway Stage
resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.lambda.id
  rest_api_id   = aws_api_gateway_rest_api.lambda_api.id
  stage_name    = "prod"
}

# Lambda Permission dla API Gateway (PDF Compressor)
resource "aws_lambda_permission" "api_gateway_pdf" {
  statement_id  = "AllowExecutionFromAPIGatewayPDF"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pdf_compressor.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.lambda_api.execution_arn}/*/*"
}

# Lambda Permission dla API Gateway (Email Aliases)
resource "aws_lambda_permission" "api_gateway_aliases" {
  statement_id  = "AllowExecutionFromAPIGatewayAliases"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.email_aliases.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.lambda_api.execution_arn}/*/*"
}

# Usage Plan z rate limiting
resource "aws_api_gateway_usage_plan" "main" {
  name         = "${var.project_name}-usage-plan"
  description  = "Usage plan for PDF Compressor API"

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
  key_id        = aws_api_gateway_api_key.pdf_compressor_key.id
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
  value       = aws_api_gateway_api_key.pdf_compressor_key.value
  sensitive   = true
}

output "lambda_function_name" {
  description = "Name of the PDF Compressor Lambda function"
  value       = aws_lambda_function.pdf_compressor.function_name
}

output "email_aliases_function_name" {
  description = "Name of the Email Aliases Lambda function"
  value       = aws_lambda_function.email_aliases.function_name
}

output "usage_plan_id" {
  description = "Usage Plan ID"
  value       = aws_api_gateway_usage_plan.main.id
}
